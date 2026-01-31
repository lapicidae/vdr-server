#!/bin/sh
#
# VDR streamdev CGI Proxy
#
# Proxies M3U playlists, MPEG-TS streams, and HLS.
# Supports multi-client channel sharing via stable session reference counting.

set -eu


###############################################################################
# Configuration
###############################################################################

CGI_DIR="$(cd -P -- "$(dirname -- "$0")" && pwd -P)"
readonly CGI_DIR

readonly VDR_HOST='127.0.0.1'
readonly STREAMDEV_PORT='3000'
readonly RESPONSE_DELAY='1'     # Settle time for streamdev response (in seconds)

readonly DEBUG="${DEBUG:-0}"

# HLS Specific Configuration
readonly HLS_SEG_TIME=2
readonly HLS_LIST_SIZE=6
readonly HLS_INIT_TIME=2
readonly HLS_TIMEOUT=10
readonly HLS_SEGMENT_TYPE='fmp4'  # Set to 'fmp4' or 'mpegts'
readonly HLS_AUDIO_CODEC='aac'
readonly HLS_AUDIO_CHANNELS=2
readonly HLS_AUDIO_BITRATE='192k'
readonly HLS_CORE_FLAGS='delete_segments+temp_file+discont_start'
readonly HLS_ROOT="${CGI_DIR}/../hls"

# Global variables
FIFO_PATH="/tmp/streamdev-proxy-$$.fifo"
PARENT_PROC='unknown'
STREAM_BG_PID=''


###############################################################################
# Utility Functions
###############################################################################

#######################################
# Log messages to syslog for debugging.
# Arguments:
#   1: Message string
#######################################
log_debug() {
	if [ "${DEBUG}" -eq 1 ]; then
		logger -t "${PARENT_PROC}: [$$] ${0##*/}" "$1"
	fi
}

#######################################
# Extract a query parameter value from QUERY_STRING.
# Arguments:
#   1: The parameter name to extract
# Outputs:
#   The value of the parameter.
#######################################
get_query_param() {
	printf '%s' "${QUERY_STRING:-}" | sed -n "s/.*$1=\([^&]*\).*/\1/p"
}

#######################################
# Monitor HLS activity for a specific channel.
# Arguments:
#   1: PID of the FFmpeg process
#   2: Absolute path to the channel directory
#######################################
run_hls_watchdog() {
	ffmpeg_pid="$1"
	chan_dir="$2"

	while true; do
		sleep 2

		if ! kill -0 "${ffmpeg_pid}" 2>/dev/null; then
			log_debug "Watchdog: FFmpeg process died for ${chan_dir##*/}"
			break
		fi

		active_clients=0
		now=$(date +%s)

		for ref in "${chan_dir}"/client_*.ref; do
			[ -e "${ref}" ] || continue
			mtime=$(stat -c %Y "${ref}")
			if [ "$((now - mtime))" -lt "${HLS_TIMEOUT}" ]; then
				active_clients=$((active_clients + 1))
			else
				rm -f "${ref}"
			fi
		done

		if [ "${active_clients}" -eq 0 ]; then
			log_debug "Watchdog: No clients for ${chan_dir##*/}. Terminating FFmpeg."
			kill -TERM "${ffmpeg_pid}" 2>/dev/null || :
			break
		fi
	done

	rm -rf "${chan_dir:?}"
}

#######################################
# Clean up background processes and files.
#######################################
cleanup() {
	exit_code=$?
	trap '' EXIT HUP INT TERM ABRT PIPE

	if [ -n "${STREAM_BG_PID}" ]; then
		kill "${STREAM_BG_PID}" 2>/dev/null || :
	fi

	[ -p "${FIFO_PATH}" ] && rm -f "${FIFO_PATH}"
	exit "${exit_code}"
}


###############################################################################
# Main Logic
###############################################################################

trap cleanup EXIT INT TERM

if [ "${DEBUG}" -eq 1 ]; then
	PARENT_PROC=$(ps -p "$PPID" -o comm= 2>/dev/null || printf 'unknown')
fi

target_path=$(get_query_param "path")
mode=$(get_query_param "mode")
level=$(get_query_param "level")

if [ -z "${target_path}" ]; then
	printf "Status: 400 Bad Request\r\n\r\n"
	exit 1
fi

# --- HLS ROUTING ---
if [ "${mode}" = "hls" ]; then
	if [ ! -d "${HLS_ROOT}" ]; then
		mkdir -p "${HLS_ROOT}"
		log_debug "Created HLS_ROOT (${HLS_ROOT})"
	fi

	# Ensures that the audio codec parameter (AC) is set to 'copy' if missing.
	case "${target_path}" in
		*";AC="*)
			# Case 1: Already contains AC parameter, do nothing to target_path.
			;;
		*";"*)
			# Case 2: Contains other parameters, append ";AC=copy" to the prefix.
			target_path="${target_path%%/*};AC=copy/${target_path#*/}"
			;;
		*)
			# Case 3: No parameters, replace the "EXT" prefix with "EXT;AC=copy".
			target_path="EXT;AC=copy/${target_path#*/}"
			;;
	esac

	# Generate a flat ID by replacing delimiters with underscores.
	channel_id=$(printf '%s' "${target_path}" | tr '/;=' '___')
	channel_dir="${HLS_ROOT}/${channel_id}"
	mkdir -p "${channel_dir}"

	# [LOCKED START] Prevent race conditions if multiple clients start same channel.
	exec 9>"${channel_dir}/ffmpeg.lock"
	if command -v flock >/dev/null 2>&1; then
		flock -x 9
	else
		log_debug "Warning: flock not found. Race condition protection disabled."
	fi

	session_src="${REMOTE_ADDR:-anon}${HTTP_USER_AGENT:-none}"
	client_session_id=$(printf '%s' "${session_src}" | tr -cd '[:alnum:]')
	touch "${channel_dir}/client_${client_session_id}.ref"

	chan_pid_file="${channel_dir}/ffmpeg.pid"
	curr_pid=$(cat "${chan_pid_file}" 2>/dev/null || :)

	if [ -z "${curr_pid}" ] || ! kill -0 "${curr_pid}" 2>/dev/null; then
		# Clean up all HLS artifacts for a fresh start. 
		rm -f "${channel_dir}"/seg_* "${channel_dir}/init.mp4" \
			  "${channel_dir}/stream.m3u8" "${channel_dir}/master.m3u8" "${channel_dir}/index.m3u8"

		log_debug "HLS: Starting FFmpeg instance for channel ${channel_id}..."

		if [ "${HLS_SEGMENT_TYPE}" = "fmp4" ]; then
			# Logic for fragmented MP4 segments
			setsid ffmpeg -y \
				-loglevel fatal -nostats \
				-fflags +genpts+igndts+nobuffer \
				-flags +low_delay \
				-i "http://${VDR_HOST}:${STREAMDEV_PORT}/${target_path}" \
				-c:v copy \
    			-c:a "${HLS_AUDIO_CODEC}" -ac "${HLS_AUDIO_CHANNELS}" -b:a "${HLS_AUDIO_BITRATE}" \
				-bsf:v "dump_extra=freq=keyframe" \
				-sn -ignore_unknown \
				-avoid_negative_ts make_zero \
				-f hls \
				-hls_time "${HLS_SEG_TIME}" \
				-hls_list_size "${HLS_LIST_SIZE}" \
				-hls_init_time "${HLS_INIT_TIME}" \
				-hls_segment_type fmp4 \
				-master_pl_name "master.m3u8" \
				-hls_flags "${HLS_CORE_FLAGS}+independent_segments" \
				-hls_segment_filename "${channel_dir}/seg_%05d.m4s" \
				"${channel_dir}/stream.m3u8" >/dev/null 2>&1 &
		else
			# Logic for MPEG-TS segments
			setsid ffmpeg -y \
				-loglevel fatal -nostats \
				-i "http://${VDR_HOST}:${STREAMDEV_PORT}/${target_path}" \
				-c:v copy \
    			-c:a "${HLS_AUDIO_CODEC}" -ac "${HLS_AUDIO_CHANNELS}" -b:a "${HLS_AUDIO_BITRATE}" \
				-bsf:v "dump_extra=freq=keyframe" \
				-f hls \
				-hls_time "${HLS_SEG_TIME}" \
				-hls_list_size "${HLS_LIST_SIZE}" \
				-hls_flags "${HLS_CORE_FLAGS}+omit_endlist+periodic_rekey" \
				-hls_segment_type mpegts \
				-master_pl_name "master.m3u8" \
				-mpegts_flags +initial_discontinuity+resend_headers \
				-hls_segment_filename "${channel_dir}/seg_%05d.ts" \
				"${channel_dir}/stream.m3u8" >/dev/null 2>&1 &
		fi

		new_pid=$!
		printf '%s\n' "${new_pid}" > "${chan_pid_file}"
		( set -m; run_hls_watchdog "${new_pid}" "${channel_dir}" & ) >/dev/null 2>&1
		
		# Wait for the playlist to become available (robust detection).
		hls_retry=20
		while [ ! -f "${channel_dir}/master.m3u8" ] && [ "${hls_retry}" -gt 0 ]; do
			sleep 0.5
			hls_retry=$((hls_retry - 1))
		done
	fi

	# Lock is implicitly released on exit, but manual release for clarity.
	if command -v flock >/dev/null 2>&1; then flock -u 9; fi

	# --- Serve Master Playlist ---
	if [ "${level}" != "media" ]; then
		if [ -f "${channel_dir}/master.m3u8" ]; then
			printf "Content-Type: application/vnd.apple.mpegurl\r\n"
			printf "Access-Control-Allow-Origin: *\r\n"
			printf "Cache-Control: no-cache, no-store, must-revalidate\r\n\r\n"

			# Redirect 'stream.m3u8' back to this CGI to handle path rewriting.
			sed "s|stream.m3u8|streamdev_proxy.cgi?path=${target_path}\&mode=hls\&level=media|g" \
				"${channel_dir}/master.m3u8"
		else
			printf "Status: 504 Gateway Timeout\r\n\r\n"
		fi
		exit 0
	fi

	# --- Serve Media Playlist (Variant Stream) ---
	if [ -f "${channel_dir}/stream.m3u8" ]; then
		printf "Content-Type: application/vnd.apple.mpegurl\r\n"
		printf "Access-Control-Allow-Origin: *\r\n"
		printf "Cache-Control: no-cache, no-store, must-revalidate\r\n\r\n"

		# Rewrite segment and init file paths to the static HLS directory.
		# The init.mp4 replacement is harmless for mpegts as it won't be found.
		# The segment replacement is extension-agnostic.
		sed -e "s|init.mp4|/hls/${channel_id}/init.mp4|g" \
			-e "s|^seg_|/hls/${channel_id}/seg_|" \
			-e '/#EXTM3U/a#EXT-X-ALLOW-CACHE:NO' \
			"${channel_dir}/stream.m3u8"
	else
		printf "Status: 504 Gateway Timeout\r\n\r\n"
	fi
	exit 0
fi

# --- MPEG-TS / M3U ROUTING ---

is_m3u=0
case "${target_path}" in
	*channels.m3u) is_m3u=1 ;;
esac

if [ "${is_m3u}" -eq 1 ]; then
	printf "Content-Type: text/plain\r\n"
else
	printf "Content-Type: video/mp2t\r\n"
fi

printf "Access-Control-Allow-Origin: *\r\n"
printf "Cache-Control: no-cache, no-store, must-revalidate\r\n"
printf "Pragma: no-cache\r\n"
printf "Expires: 0\r\n\r\n"

if [ "${is_m3u}" -eq 1 ]; then
	log_debug "Mode: Playlist (M3U)"
	{
		printf "GET /%s HTTP/1.0\r\n" "${target_path}"
		printf "Host: %s\r\n\r\n" "${VDR_HOST}"
		sleep "${RESPONSE_DELAY}"
	} | exec nc -w 10 "${VDR_HOST}" "${STREAMDEV_PORT}" | sed '1,/^\r$/d'
else
	log_debug "Mode: Stream (MPEG-TS) for ${target_path}"
	[ -p "${FIFO_PATH}" ] || mkfifo "${FIFO_PATH}"

	(
		printf "GET /%s HTTP/1.0\r\n" "${target_path}"
		printf "Host: %s\r\n" "${VDR_HOST}"
		printf "Connection: keep-alive\r\n\r\n"
		exec tail -f /dev/null
	) > "${FIFO_PATH}" &

	STREAM_BG_PID=$!
	# Run nc in the background and wait for it. This ensures signals are trapped
	# correctly, allowing cleanup to run if the connection is dropped.
	nc "${VDR_HOST}" "${STREAMDEV_PORT}" < "${FIFO_PATH}" &
	wait "$!"
fi


# vim: ts=4 sw=4 noet:
# kate: space-indent off; indent-width 4; mixed-indent off;
