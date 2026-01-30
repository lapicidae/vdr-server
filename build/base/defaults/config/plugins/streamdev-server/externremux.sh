#!/bin/bash
#
# Real-time FFmpeg remux/transcode helper for VDR streamdev-server.
#
# This script is called by the VDR streamdev-server plugin to remux or 
# transcode live TV streams on the fly. It supports smart codec detection, 
# scaling, deinterlacing, and hardware acceleration (VAAPI, NVENC, QSV).
#
# Installation:
#   Install as VDRCONFDIR/plugins/streamdev-server/externremux.sh
#
# Usage:
#   http://<server>:<port>/ext;<quality>[;<param>=<value>...]
#   Example: http://vdr.server:3000/ext;h264smart;HWACCEL=vaapi;DEINTERLACE=true/
#
# Supported URL Parameters:
#   QUALITY         Preset profile (e.g., h264smart, 1080p, lte).
#   PROG            Remuxer program ('ffmpeg' or 'cat').
#   VC / AC         Video/Audio codec overrides.
#   VBR / ABR       Video/Audio bitrate in kbps.
#   WIDTH / HEIGHT  Target resolution (Height='' preserves aspect ratio).
#   HWACCEL         Hardware acceleration ('none', 'vaapi', 'nvenc', 'qsv').
#   DEINTERLACE     Enable deinterlacing ('true' or 'false').
#   DEBUG           Debug level (0-3).
#
# How to test manually (Terminal):
#   h264 input:
#     REMUX_VTYPE=27 REMUX_PARAM_DEBUG=2 ./externremux.sh < /path/to/test_video.ts > /dev/null
#   hevc input:
#     REMUX_VTYPE=36 REMUX_PARAM_DEBUG=2 ./externremux.sh < /path/to/test_video.ts > /dev/null
#
# Dependencies: ffmpeg, mktemp, mkfifo, fuser (psmisc), logger
#

set -o pipefail


###############################################################################
# Configuration
###############################################################################

# --- General Configuration ---
# Options: 1080p, 720p, 540p, copy, h264smart, hevcsmart, 5g, lte, mobilesafe
QUALITY='h264smart'
# Hardware acceleration: none, vaapi, nvenc, qsv (qsv is currently untested)
HWACCEL='none'
# Automatic deinterlacing via hardware filters if frames are marked as interlaced.
DEINTERLACE=false
# Program used for logging (disabled if empty).
LOGGER='logger'
# Default remux program (cat, ffmpeg).
PROG='ffmpeg'
# Use mono if audio bitrate (ABR) is lower than this value.
ABR_MONO=64
# Debug level: 0=off, 1=basic, 2=verbose, 3=ffmpeg debug.
DEBUG=0

# --- FFmpeg Configuration ---
FFMPEG='ffmpeg'
# Default codecs
FFMPEG_VC='libx264'
FFMPEG_AC='aac'
# Preset for x264 (ultrafast, superfast, veryfast, faster, fast, medium, slow)
FFMPEG_PRESET='ultrafast'
# Video quality (CRF): 0–51; lower is better (default: 23)
FFMPEG_CRF=23
# Fix GOP for faster seeking and stream stability
FFMPEG_GOP=25
# How many microseconds are analyzed to probe the input
FFMPEG_ANALYZEDURATION='1.2M'
# The size of the data to analyze to get stream information in bytes
FFMPEG_PROBESIZE='2.5M'
# Maximum number of queued packets
FFMPEG_THREAD_QUEUE_SIZE='65536'
# Default Log level (recommended: fatal; default: error)
FFMPEG_LOGLEVEL='fatal'

# --- Advanced CRF Configuration ---
# Max bitrate to prevent network congestion (default: 8000k)
# FFMPEG_MAX_BITRATE="8000k"
# VBV buffer size; usually 2x max bitrate for stability (default: 16000k)
# FFMPEG_BUF_SIZE="16000k"

# --- Advanced Deinterlace Configuration ---
# Software (CPU) filter
# FFMPEG_DI_SW="bwdif=mode=0:deint=1"
# NVIDIA (CUDA) filter
# FFMPEG_DI_NV="yadif_cuda=mode=0:deint=1"
# VA-API (Intel/AMD) filter
# FFMPEG_DI_VA="deinterlace_vaapi"
# QSV (Intel) filter
# FFMPEG_DI_QS="deinterlace=2"

# --- Internals ---
# used by cleanup
readonly CLEANUP_SLEEP_SECONDS=0.5
# Generated at runtime to avoid collisions.
FIFO=''
# HTTP response headers (used by start_reply) - Global by design.
HEADER=()


###############################################################################
# Utility Functions
###############################################################################

#######################################
# Central logging function
# Globals:
#   DEBUG
# Arguments:
#   Type (INFO, WARNING, ERROR, DEBUG1, DEBUG2, DEBUG3)
#   Message
#######################################
log() {
	local -u type="$1"
	shift
	local msg="$*"

	case "${type}" in
		INFO)
			printf 'INFO: %s\n' "${msg}" >&2
			;;
		WARNING)
			printf 'WARNING: %s\n' "${msg}" >&2
			;;
		ERROR)
			printf 'ERROR: %s\n' "${msg}" >&2
			;;
		DEBUG[1-3])
			local lvl="${type#DEBUG}"
			if (( DEBUG >= lvl )); then
				printf 'DEBUG[%s]: %s\n' "${lvl}" "${msg}" >&2
			fi
			;;
		*)
			printf 'LOG: %s\n' "${msg}" >&2
			;;
	esac
}
export -f log

#######################################
# Print error message and exit
# Globals:
#   SERVER_PROTOCOL
# Arguments:
#   Error message
#######################################
error() {
	local msg="$*"
	if [[ "${SERVER_PROTOCOL}" == "HTTP" ]]; then
		printf 'Content-type: text/plain\r\n\r\n%s\n' "${msg}"
	fi
	log ERROR "${msg}"
	exit 1
}

#######################################
# Cleanup background jobs and FIFO
# Prevents zombie processes by explicitly killing all children of this shell
# Globals:
#   FIFO
#######################################
cleanup() {
	# Disable trap to avoid recursion during cleanup
	trap '' EXIT HUP INT TERM ABRT PIPE

	log DEBUG1 "Cleaning up processes and temporary files..."

	# Collect PIDs of all background jobs
	local -a job_pids
  	mapfile -t job_pids < <(jobs -pr)

	if (( ${#job_pids[@]} > 0 )); then
		# Send termination signal to all background jobs
		kill -TERM "${job_pids[@]}" 2>/dev/null
		
		# CRITICAL: Wait for processes to exit to prevent zombies (defunct)
		# Use a short timeout/check to ensure we don't hang if a child is stuck
		wait "${job_pids[@]}" 2>/dev/null
	fi

	# Allow a brief moment for file system operations
	sleep "${CLEANUP_SLEEP_SECONDS}"

	if [[ -n "${FIFO}" ]]; then
		# -k (kill) ensures no stray process blocks the removal
		fuser -k "${FIFO}" 2>/dev/null || true
		rm -f "${FIFO}"
	fi
}

#######################################
# Check whether value is numeric
# Arguments:
#   Value
# Returns:
#   0 if numeric
#######################################
is_numeric() {
	[[ "$1" =~ ^[0-9]+$ ]]
}

#######################################
# Round dimension to even number for FFmpeg
# Arguments:
#   Dimension or -1
# Outputs:
#   FFmpeg expression
#######################################
round_even() {
	local value="$1"
	if [[ "${value}" == "-1" ]]; then
		printf '%s\n' "-1"
	else
		printf 'trunc(%s/2)*2\n' "${value}"
	fi
}

#######################################
# Check whether FFmpeg supports encoder
# Arguments:
#   Encoder name
#######################################
ffmpeg_has_encoder() {
	local target="$1"
	while read -r _ encoder _; do
		if [[ "$encoder" == "$target" ]]; then
			return 0
		fi
	done < <("${FFMPEG}" -hide_banner -encoders 2>/dev/null)
	return 1
}


###############################################################################
# HTTP / FIFO Handling
###############################################################################

#######################################
# Send HTTP headers and initialize FIFO.
# Globals:
#   SERVER_PROTOCOL
#   REQUEST_METHOD
#   REMOTE_ADDR
#   CONTENT_TYPE
#   HEADER
#   FIFO
#######################################
start_reply() {
	if [[ "${SERVER_PROTOCOL}" == "HTTP" ]]; then
		printf 'Content-type: %s\r\n' "${CONTENT_TYPE}"
		for header in "${HEADER[@]}"; do
			printf '%s\r\n' "${header}"
		done
		printf '\r\n'

		if [[ "${REQUEST_METHOD}" == "HEAD" ]]; then
			exit 0
		fi
	fi

	FIFO="$(mktemp -u /tmp/externremux.XXXXXX.fifo)"
	mkfifo "${FIFO}" || error "Failed to create FIFO"

	# Pipe stderr of cat to a loop to catch "Broken pipe" errors silently.
	# This runs in background and is tracked by 'jobs'.
	cat "${FIFO}" <&- 2> >(while read -r line; do
		if [[ "${line}" == *"Broken pipe"* ]] || [[ "${line}" == *"write error"* ]]; then
			log INFO "Stream closed (${REMOTE_ADDR:-client} disconnected)"
		else
			log ERROR "cat: ${line}"
		fi
	done) &
}


###############################################################################
# Remux Implementations
###############################################################################

#######################################
# Pass-through remux using cat.
# Reads from stdin and writes to FIFO.
# Globals:
#   DEBUG
#   FIFO
#######################################
remux_cat() {
	start_reply
	exec 3<&0

	if (( DEBUG == 0 )); then
		cat <&3 >"${FIFO}" 2>/dev/null &
	else
		cat <&3 >"${FIFO}" &
	fi
}

#######################################
# Perform live remux/transcoding using FFmpeg
# Globals:
#   FFMPEG, FFMPEG_AC, FFMPEG_VC, FFMPEG_PRESET
#   FFMPEG_LOGLEVEL, FFMPEG_ANALYZEDURATION
#   FFMPEG_PROBESIZE, FFMPEG_THREAD_QUEUE_SIZE
#   FFMPEG_DI_NV, FFMPEG_DI_VA, FFMPEG_DI_QS
#   FFMPEG_DI_SW, HWACCEL, DEBUG, FIFO, WIDTH
#   HEIGHT, VBR, ABR, ABR_MONO, DEINTERLACE
#   REMUX_PARAM_*, REMUX_VTYPE
#######################################
remux_ffmpeg() {
	local ac="${AC}"
	local ff_loglevel
	local gop="${FFMPEG_GOP:-25}"
	local hw_mode='none'   # none|vaapi|nvenc|qsv
	local hwaccel="${HWACCEL}"
	local hwdec=''
	local hwdev=''
	local hwenc_active=false
	local vc="${VC}"
	local vc_mode='fixed'
	local vf_string=''

	local -a a_opts=()
	local -a filter_opts=()
	local -a v_opts=()

	# ---------------------------------------------------------------------------
	# Video codec decision
	# ---------------------------------------------------------------------------
	case "${vc}" in
		auto-h264)
			vc_mode='auto-h264'
			if [[ "${REMUX_VTYPE}" == '27' && -z "${WIDTH}" \
				&& ! "${DEINTERLACE}" =~ ^(true|1)$ ]]; then
				vc='copy'
			else
				vc='libx264'
			fi
			;;
		auto-hevc)
			vc_mode='auto-hevc'
			if [[ "${REMUX_VTYPE}" == '36' && -z "${WIDTH}" \
				&& ! "${DEINTERLACE}" =~ ^(true|1)$ ]]; then
				vc='copy'
			else
				vc='libx265'
			fi
			;;
	esac

	if [[ "${vc}" == 'copy' && "${hwaccel}" != 'none' ]]; then
		log DEBUG1 'Hardware acceleration disabled (vc=copy).'
		hwaccel='none'
	fi

	# Determine FFmpeg log level.
	if [[ -n "${REMUX_PARAM_FFMPEG_LOGLEVEL}" ]]; then
		ff_loglevel="${REMUX_PARAM_FFMPEG_LOGLEVEL}"
	else
		case "${DEBUG}" in
			0) ff_loglevel="${FFMPEG_LOGLEVEL:-error}" ;;
			1) ff_loglevel='warning' ;;
			2) ff_loglevel='info'    ;;
			*) ff_loglevel='debug'   ;;
		esac
	fi

	local -a input_params=(
		'-loglevel' "${ff_loglevel}"
		'-nostats'
		'-fflags' '+genpts+igndts+discardcorrupt'
		'-analyzeduration' "${FFMPEG_ANALYZEDURATION}"
		'-probesize' "${FFMPEG_PROBESIZE}"
		'-thread_queue_size' "${FFMPEG_THREAD_QUEUE_SIZE}"
	)

	# ---------------------------------------------------------------------------
	# Hardware acceleration setup
	# ---------------------------------------------------------------------------
	if [[ "${hwaccel}" != 'none' && "${vc}" != 'copy' ]]; then
		case "${hwaccel}:${vc}" in
			vaapi:libx264)
				vc='h264_vaapi'
				hwenc_active=true
				hwdec='vaapi'
				hwdev='/dev/dri/renderD128'
				hw_mode='vaapi'
				input_params+=(
					'-init_hw_device' "vaapi=myva:${hwdev}"
					'-filter_hw_device' 'myva'
				)
				;;
			vaapi:libx265)
				vc='hevc_vaapi'
				hwenc_active=true
				hwdec='vaapi'
				hwdev='/dev/dri/renderD128'
				hw_mode='vaapi'
				input_params+=(
					'-init_hw_device' "vaapi=myva:${hwdev}"
					'-filter_hw_device' 'myva'
				)
				;;
			nvenc:libx264)
				vc='h264_nvenc'
				hwenc_active=true
				hwdec='cuda'
				hw_mode='nvenc'
				;;
			nvenc:libx265)
				vc='hevc_nvenc'
				hwenc_active=true
				hwdec='cuda'
				hw_mode='nvenc'
				;;
			qsv:libx264)
				vc='h264_qsv'
				hwenc_active=true
				hwdec='qsv'
				hw_mode='qsv'
				;;
			qsv:libx265)
				vc='hevc_qsv'
				hwenc_active=true
				hwdec='qsv'
				hw_mode='qsv'
				;;
			*)
				log WARNING "Unsupported HWACCEL=${HWACCEL}, falling back to software."
				hwaccel='none'
				hwdec=''
				hw_mode='none'
				;;
		esac

		if [[ "${hwaccel}" != 'none' ]] && ! ffmpeg_has_encoder "${vc}"; then
			log WARNING "Encoder ${vc} not found, falling back to software."
			hwaccel='none'
			hw_mode='none'
			hwdec=''
			hwdev=''
			hwenc_active=false
		fi

		[[ -n "${hwdec}" ]] && input_params+=('-hwaccel' "${hwdec}")
		[[ -n "${hwdev}" && "${hwaccel}" != 'vaapi' ]] && input_params+=('-hwaccel_device' "${hwdev}")
	fi

	log DEBUG1 "Video decision (${vc_mode}): input VTYPE=${REMUX_VTYPE} -> vc=${vc}"

	# ---------------------------------------------------------------------------
	# Video options
	# ---------------------------------------------------------------------------
	if [[ "${vc}" == 'copy' ]]; then
		v_opts+=('-c:v' 'copy' '-flags:v' '+global_header')
		[[ "${REMUX_VTYPE}" == '27' ]] && v_opts+=('-bsf:v' 'h264_mp4toannexb')
		[[ "${REMUX_VTYPE}" == '36' ]] && v_opts+=('-bsf:v' 'hevc_mp4toannexb')
	else
		v_opts+=('-c:v' "${vc}")

		# Ensure a fixed GOP for stable streaming and fast seeking.
		# Disabling sc_threshold ensures keyframes are strictly interval-based.
		v_opts+=('-g' "${gop}" '-sc_threshold' '0')

		if [[ "${hw_mode}" == 'nvenc' ]]; then
			local nv_preset
			case "${FFMPEG_PRESET}" in
				ultrafast) nv_preset='p1' ;;
				superfast) nv_preset='p2' ;;
				veryfast)  nv_preset='p3' ;;
				faster)    nv_preset='p4' ;;
				fast)      nv_preset='p5' ;;
				medium)    nv_preset='p6' ;;
				slow)      nv_preset='p7' ;;
				*)         nv_preset='p4' ;;
			esac
			v_opts+=(
				'-preset' "${nv_preset}"
				'-tune' 'll'
				'-forced-idr' '1'
				'-delay' '0'
			)
		elif [[ "${hw_mode}" == 'qsv' ]]; then
			# Force IDR frames at every GOP start
			v_opts+=('-forced_idr' '1')
		else
			v_opts+=('-preset' "${FFMPEG_PRESET}" '-tune' 'zerolatency')
		fi

		if [[ -n "${VBR}" ]]; then
			v_opts+=(
				'-b:v' "${VBR}k"
				'-maxrate' "${VBR}k"
				'-bufsize' "$((VBR * 2))k"
			)
		else
			# Smart Bitrate: CRF for quality, with a safety cap for streaming.
			local max_bitrate="${FFMPEG_MAX_BITRATE:-8000k}"
			local buf_size="${FFMPEG_BUF_SIZE:-16000k}"
			local crf="${FFMPEG_CRF:-23}"

			if [[ "${hw_mode}" == 'nvenc' ]]; then
				v_opts+=('-rc' 'vbr' '-cq' "${crf}" '-maxrate' "${max_bitrate}" '-bufsize' "${buf_size}")
			elif [[ "${hw_mode}" == 'vaapi' ]]; then
				v_opts+=('-rc' 'vbr' '-global_quality' "${crf}" '-maxrate' "${max_bitrate}" '-bufsize' "${buf_size}")
			else
				v_opts+=('-crf' "${crf}" '-maxrate' "${max_bitrate}" '-bufsize' "${buf_size}")
			fi
		fi
	fi

	# ---------------------------------------------------------------------------
	# Audio options
	# ---------------------------------------------------------------------------
	if [[ "${ac}" == 'copy' ]]; then
		a_opts+=('-c:a' 'copy')
	else
		a_opts+=('-acodec' "${ac}" '-b:a' "${ABR}k")
		if is_numeric "${ABR}" && (( ABR > 0 && ABR < ABR_MONO )); then
			a_opts+=('-ac' '1')
		else
			a_opts+=('-ac' '2')
		fi
	fi

	# ---------------------------------------------------------------------------
	# Filters (deinterlacing & scaling)
	# ---------------------------------------------------------------------------
	if [[ "${vc}" != 'copy' ]]; then
		local w="${WIDTH:--1}"
		local h="${HEIGHT:--1}"

		log DEBUG2 "Filter Config: Width=${w}, Height=${h}, Deinterlace=${DEINTERLACE}"

		if [[ "${hw_mode}" == 'nvenc' ]]; then
			filter_opts+=('hwupload_cuda')
			[[ "${DEINTERLACE}" =~ ^(true|1)$ ]] && filter_opts+=("${FFMPEG_DI_NV:-bwdif_cuda=mode=0:deint=1}")
			w="$(round_even "${w}")"
			h="$(round_even "${h}")"
			[[ "${w}" != '-1' || "${h}" != '-1' ]] && filter_opts+=("scale_cuda=${w}:${h}")

		elif [[ "${hw_mode}" == 'vaapi' ]]; then
			filter_opts+=('format=nv12' 'hwupload')
			[[ "${DEINTERLACE}" =~ ^(true|1)$ ]] && filter_opts+=("${FFMPEG_DI_VA:-deinterlace_vaapi}")
			w="$(round_even "${w}")"
			h="$(round_even "${h}")"
			[[ "${w}" != '-1' || "${h}" != '-1' ]] && filter_opts+=("scale_vaapi=${w}:${h}")

		elif [[ "${hw_mode}" == 'qsv' ]]; then
			input_params+=(
				'-init_hw_device' 'qsv=hw'
				'-filter_hw_device' 'hw'
			)
			local qsv_deint=''
			[[ "${DEINTERLACE}" =~ ^(true|1)$ ]] && qsv_deint="${FFMPEG_DI_QS:-deinterlace=1}"

			local qw="${w}"
			local qh="${h}"
			[[ "${qw}" == '-1' ]] && qw='iw'
			[[ "${qh}" == '-1' ]] && qh='ih'

			filter_opts+=(
				"vpp_qsv=${qsv_deint:+${qsv_deint}:}w=${qw}:h=${qh}"
			)

		else
			[[ "${DEINTERLACE}" =~ ^(true|1)$ ]] && filter_opts+=("${FFMPEG_DI_SW:-yadif=0:-1:1}")
			if [[ "${w}" != '-1' || "${h}" != '-1' ]]; then
				local sw="${w}"
				local sh="${h}"
				[[ "${sw}" == '-1' ]] && sw='-2'
				[[ "${sh}" == '-1' ]] && sh='-2'
				filter_opts+=("scale=${sw}:${sh}")
			fi
		fi
	fi

	if (( ${#filter_opts[@]} > 0 )); then
		vf_string=$(IFS=,; printf '%s' "${filter_opts[*]}")
	fi

	# ---------------------------------------------------------------------------
	# Execute FFmpeg
	# ---------------------------------------------------------------------------
	start_reply
	exec 3<&0

	# Construct final argument array for logging and execution.
	local -a ff_args=(
		"${input_params[@]}"
		'-i' '-'
		"${v_opts[@]}"
		"${a_opts[@]}"
	)
	[[ -n "${vf_string}" ]] && ff_args+=('-vf' "${vf_string}")
	ff_args+=('-f' 'mpegts' '-y' "${FIFO}")

	if (( DEBUG >= 1 )); then
		[[ "${hwenc_active}" == 'true' ]] && log DEBUG1 "HW acceleration active: ${hwaccel}"
		log DEBUG1 "FFmpeg command: ${FFMPEG} ${ff_args[*]}"
	fi

	# Start FFmpeg in background.
	# Redirect stdout to /dev/null as data is written to FIFO.
	# Process stderr through a while-loop to prefix FFmpeg log messages
	# for better visibility in the system log.
	"${FFMPEG}" "${ff_args[@]}" <&3 >/dev/null 2> >(while read -r line; do
		printf 'FFmpeg: %s\n' "${line}" >&2
	done) &

	readonly FFMPEG_PID=$!
	log DEBUG1 "FFmpeg started with PID ${FFMPEG_PID}"
}


###############################################################################
# Main Execution
###############################################################################

# Check dependencies
if [[ "${PROG}" != "cat" ]] && ! command -v "${FFMPEG}" >/dev/null 2>&1; then
	error "Executable '${FFMPEG}' not found. Please install ffmpeg."
fi

DEBUG="${REMUX_PARAM_DEBUG:-$DEBUG}"

if [[ -n "${LOGGER}" ]]; then
	exec 2> >("${LOGGER}" -t "vdr: [$$] ${0##*/}")
fi

trap cleanup EXIT HUP INT TERM ABRT PIPE

readonly info_client="${REMOTE_ADDR:+ to ${REMOTE_ADDR}}"
readonly info_server="${SERVER_NAME:+ via ${SERVER_NAME}}${SERVER_PORT:+:${SERVER_PORT}}"
readonly info_proto=" [${SERVER_PROTOCOL:-HTTP}${SERVER_SOFTWARE:+ / ${SERVER_SOFTWARE}}]"

if (( DEBUG >= 1 )); then
	log INFO "Starting externremux (pid=$$)${info_client}${info_server}${info_proto}"
else
	log INFO "Starting externremux (pid=$$)${info_client}${info_proto}"
fi

log DEBUG1 "--- Incoming parameters ---"
while IFS= read -r param; do log DEBUG1 "${param}"; done < <(env | grep '^REMUX_PARAM_')
log DEBUG1 "-------------------------------"

[[ "${REMUX_VPID:-0}" -le 1 ]] && CONTENT_TYPE='audio/mpeg' || CONTENT_TYPE='video/mp2t'

QUALITY="${REMUX_PARAM_QUALITY:-$QUALITY}"
log DEBUG1 "Quality Profile: ${QUALITY}"
QUALITY="${QUALITY,,}"

VC="${FFMPEG_VC}"
AC="${FFMPEG_AC}"


###############################################################################
# Profile Logic & Parameter Mapping
###############################################################################

# The following variables define the stream's characteristics:
#
# --- Core Parameters ---
# VBR: Video bitrate (kbps). If empty, switches to Smart-Bitrate (CRF/CQ).
# ABR: Audio bitrate (kbps).
# WIDTH/HEIGHT: Target resolution. Empty or -1 keeps original/aspect ratio.
#
# --- Internal Logic Switches (REMUX_PARAM_*) ---
# VC (Video Codec): 
#   - copy, libx264, libx265, h264_nvenc, hevc_vaapi, etc.
#   - auto-h264 / auto-hevc: Smart detection (copies if source matches).
# AC (Audio Codec):
#   - copy, aac, mp2, libfdk_aac, etc.

case "${QUALITY}" in
	# --- SMART PROFILES ---
	h264smart)  VBR='';   ABR=192; WIDTH='';    VC='auto-h264'; AC='aac'  ;;
	hevcsmart)  VBR='';   ABR=192; WIDTH='';    VC='auto-hevc'; AC='aac'  ;;

	# --- FIXED RESOLUTIONS ---
	1080p)      VBR=8000; ABR=192; WIDTH=1920;  ;;
	720p)       VBR=4500; ABR=128; WIDTH=1280;  ;;
	540p)       VBR=2000; ABR=96;  WIDTH=960;   ;;

	# --- SPECIAL MODES ---
	copy)       VBR='';   ABR='';  WIDTH='';    VC='copy';      AC='copy' ;;
	live|web)   VBR='';   ABR=192; WIDTH='';    VC='copy';      AC='aac'  ;;

	# --- MOBILE ---
	5g)         VBR=8000; ABR=160; WIDTH=1920;  ;;
	lte)        VBR=3500; ABR=128; WIDTH=1280;  ;;
	mobilesafe) VBR=1500; ABR=96;  WIDTH=960;   ;;

	# --- LEGACY ---
	dsl1000)    VBR=96;   ABR=16;  WIDTH=160;   ;;
	dsl2000)    VBR=128;  ABR=16;  WIDTH=160;   ;;
	dsl3000)    VBR=256;  ABR=16;  WIDTH=320;   ;;
	dsl6000)    VBR=378;  ABR=32;  WIDTH=320;   ;;
	dsl16000)   VBR=512;  ABR=32;  WIDTH=480;   ;;
	wlan11)     VBR=768;  ABR=64;  WIDTH=640;   ;;
	wlan54)     VBR=2048; ABR=128; WIDTH='';    ;;
	lan10)      VBR=4096; ABR='';  WIDTH='';    ;;

	*)          error "Unknown quality '${QUALITY}'" ;;
esac

# Parameter Overrides
ABR="${REMUX_PARAM_ABR:-$ABR}"
AC="${REMUX_PARAM_AC:-$AC}"
DEINTERLACE="${REMUX_PARAM_DEINTERLACE:-$DEINTERLACE}"
HEIGHT="${REMUX_PARAM_HEIGHT:-$HEIGHT}"
HWACCEL="${REMUX_PARAM_HWACCEL:-$HWACCEL}"
PROG="${REMUX_PARAM_PROG:-$PROG}"
VBR="${REMUX_PARAM_VBR:-$VBR}"
VC="${REMUX_PARAM_VC:-$VC}"
WIDTH="${REMUX_PARAM_WIDTH:-$WIDTH}"

# Parameter normalisation
AC="${AC,,}"
DEINTERLACE="${DEINTERLACE,,}"
HWACCEL="${HWACCEL,,}"
PROG="${PROG,,}"
VC="${VC,,}"

# Advanced URL Filter Overrides
FFMPEG_DI_NV="${REMUX_PARAM_DI_NV:-$FFMPEG_DI_NV}"
FFMPEG_DI_QS="${REMUX_PARAM_DI_QS:-$FFMPEG_DI_QS}"
FFMPEG_DI_SW="${REMUX_PARAM_DI_SW:-$FFMPEG_DI_SW}"


###############################################################################
# Execution and Process Management
###############################################################################

case "${PROG}" in
	cat)              remux_cat ;;
	ffmpeg|mencoder)  remux_ffmpeg ;;
	*)                error "Unknown remuxer program '${PROG}'" ;;
esac

# Check if a background process was started.
if [[ -n "${FFMPEG_PID}" ]]; then
	# Wait for the specific PID.
	# We explicitly capture the exit status to handle it.
	wait "${FFMPEG_PID}"
	readonly EXIT_STATUS=$?

	if (( EXIT_STATUS == 0 || EXIT_STATUS == 130 || EXIT_STATUS == 143 )); then
		# Normal termination (0) or Interrupted (130 = SIGINT, 143 = SIGTERM).
		log INFO "FFmpeg process ${FFMPEG_PID} terminated normally (status ${EXIT_STATUS})."
	else
		# Real errors.
		log ERROR "FFmpeg process ${FFMPEG_PID} failed with exit status ${EXIT_STATUS}."
		cleanup
		exit "${EXIT_STATUS}"
	fi
else
	# Fallback for remux_cat which does not set FFMPEG_PID.
	wait
fi

exit 0


# vim: ts=4 sw=4 noet:
# kate: space-indent off; indent-width 4; mixed-indent off;
