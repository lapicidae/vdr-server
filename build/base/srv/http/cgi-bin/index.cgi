#!/bin/sh
#
# Generate a UIkit-based directory listing with Lightbox support.

# Set the target directory relative to the script location.
TARGET_DIR="..${REQUEST_URI#"${SCRIPT_NAME}"}"

# Blacklisted directories
BLACKLIST="css error font hls img js"

for item in $BLACKLIST; do
	case "$TARGET_DIR" in
		*"$item"*)
			printf "Status: 403 Forbidden\r\n"
			printf "Content-Type: text/html\r\n\r\n"
			printf '<!DOCTYPE html>\n<html>\n\t<head>\n\t\t<meta http-equiv="Refresh" content="0.2; url=/error/403.html">\n\t</head>\n</html>\n'
			exit 0
			;;
	esac
done

# Check if the requested directory exists.
if [ ! -d "$TARGET_DIR" ]; then
	printf "Status: 404 Not Found\r\n"
	printf "Content-Type: text/html\r\n\r\n"
	printf '<!DOCTYPE html>\n<html>\n\t<head>\n\t\t<meta http-equiv="Refresh" content="0.2; url=/error/404.html">\n\t</head>\n</html>\n'
	exit 0
fi

# Remove leading and trailing slashes
TITLE="${REQUEST_URI#/}"
TITLE="${TITLE%/}"

printf "Content-Type: text/html\r\n\r\n"

cat << EOH
<!DOCTYPE html>
<html lang="en">
	<head>
		<title>${TITLE} | vdr-server @ docker</title>
		<meta charset="UTF-8">
		<meta name="viewport" content="width=device-width, initial-scale=1">
		<link rel="icon" type="image/svg+xml" href="/img/favicon.svg" sizes="any">
		<link rel="shortcut icon" href="/favicon.ico" />
		<link rel="apple-touch-icon" sizes="180x180" href="/img/apple-touch-icon.png">
		<link rel="manifest" href="/site.webmanifest">
		<link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/uikit@latest/dist/css/uikit.min.css">
		<script src="https://cdn.jsdelivr.net/npm/uikit@latest/dist/js/uikit.min.js"></script>
		<script src="https://cdn.jsdelivr.net/npm/uikit@latest/dist/js/uikit-icons.min.js"></script>
		<script src="/js/uikit-extension.js"></script>
		<script src="/js/additions.js"></script>
	</head>
	<body class="uk-background-muted">
		<!-- Navigation & Off-Canvas -->
		<header id="navigation-include" class="uk-position-top uk-height-max-small"></header>
		<div class="uk-flex uk-flex-center uk-flex-middle" uk-height-placeholder="#navigation-include">
			<div id="placeholder-spinner" uk-spinner="ratio: 1.5"></div>
		</div>
		<!-- Content -->
		<main class="uk-section uk-section-muted" data-uk-height-viewport="expand: true">
			<div class="uk-container">
				<div class="uk-card uk-card-default uk-card-body uk-box-shadow-medium uk-border-rounded">
					<h3 class="uk-card-title">
						<span uk-icon="icon: folder; ratio: 1.5" class="uk-margin-small-right"></span>
						Index of ${REQUEST_URI}
					</h3>
					<ul class="uk-list uk-list-divider uk-list-large" uk-lightbox="toggle: .lb-link; animation: slide">
EOH

# Count slashes
SLASH_COUNT=$(printf '%s' "$REQUEST_URI" | tr -dc '/' | wc -c)

# Show "Parent Directory" only if we are deeper than 2 slashes
if [ "$SLASH_COUNT" -gt 2 ]; then
	cat << EOH
						<li>
							<a href=".." class="uk-link-text uk-text-bold">
								<span uk-icon="reply" class="uk-margin-small-right"></span>Parent Directory
							</a>
						</li>
EOH
fi

# Process Directories
find "$TARGET_DIR" -maxdepth 1 -mindepth 1 -type d \
	\( -name 'cgi-bin' -o -name 'css' -o -name 'error' -o -name 'js' \) -prune -o \
	-type d -printf '%f\n' | sort -bfiV | while read -r line; do
	[ -z "$line" ] && continue
	cat << EOD
						<li>
							<a href="${line}/" class="uk-link-toggle">
								<span uk-icon="folder" class="uk-margin-small-right"></span>
								<span class="uk-link-heading">${line}/</span>
							</a>
						</li>
EOD
done

# Process Files
find -L "$TARGET_DIR" -maxdepth 1 -mindepth 1 -type f -printf '%f\n' | sort -bfiV | while read -r line; do
	[ -z "$line" ] && continue
	
	ext="${line##*.}"
	filename="${line%.*}"
	case "$ext" in
		jpg|jpeg|png|gif|svg|webp|bmp|JPG|JPEG|PNG|SVG)
			cat << EOF
						<li>
							<div class="uk-inline">
								<a href="$line" class="uk-link-toggle lb-link" data-alt="${filename} Logo" data-caption="${filename}">
									<span uk-icon="image" class="uk-margin-small-right"></span>
									<span class="uk-link-heading">$line</span>
								</a>
								<div class="uk-hidden-touch uk-background-secondary" uk-dropdown="mode: hover; pos: right-center; delay-show: 300; delay-hide: 125; offset: 15">
									<img src="$line" class="uk-width-small" alt="Preview">
								</div>
							</div>
						</li>
EOF
			;;
		*)
			cat << EOF
						<li>
							<a href="$line" class="uk-link-toggle" target="_blank">
								<span uk-icon="file" class="uk-margin-small-right"></span>
								<span class="uk-link-heading">$line</span>
							</a>
						</li>
EOF
			;;
	esac
done

cat << EOT
					</ul>
				</div>
			</div>
		</main>
		<!-- Totop -->
		<div id="back-to-top" class="uk-position-fixed uk-position-bottom-right uk-position-large uk-light uk-position-z-index-highest" hidden>
			<a href="#" class="uk-icon-link uk-border-circle uk-background-primary uk-box-shadow-hover-medium uk-flex-inline uk-flex-center uk-flex-middle" uk-icon="icon: chevron-up; ratio: 2.2" uk-scroll></a>
		</div>
		<!-- Footer -->
		<footer id="footer-include"></footer>
	</body>
</html>
EOT


# vim: ts=4 sw=4 noet:
# kate: space-indent off; indent-width 4; mixed-indent off;
