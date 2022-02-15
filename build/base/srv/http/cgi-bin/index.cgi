#!/bin/sh
echo -en "Content-Type: text/html\r\n\r\n<!DOCTYPE html>\n<html lang='en'>\n"

if [ ! -d "..${REQUEST_URI#${SCRIPT_NAME}}" ]; then
cat << EOH
  <head>
	<meta http-equiv='Refresh' content='0.2; url=../error/404.html'>
  </head>
EOH
else
cat << EOH
  <head>
	<meta charset="utf-8">
	<title>VDR Images Server (${REQUEST_URI})</title>
	<link rel="icon" type="image/svg+xml" href="../favicon.svg" sizes="any">
	<meta name="viewport" content="width=device-width, initial-scale=1.0, minimum-scale=1.0">
	<link rel="stylesheet" href="https://fonts.googleapis.com/css?family=Roboto:regular,bold,italic,thin,light,bolditalic,black,medium&amp;lang=en">
	<link rel="stylesheet" href="https://fonts.googleapis.com/icon?family=Material+Icons">
	<link rel="stylesheet" href="https://code.getmdl.io/1.3.0/material.teal-red.min.css">
	<style>
		#git-link{position:fixed;display:block;right:0;bottom:0;margin-right:40px;margin-bottom:40px;z-index:900}
		#filelist .mdl-list__item{padding:0 !important;min-height:30px !important}
		.ribbon{width:100%;height:40vh;background-color:#3F51B5;flex-shrink:0}
		.main{margin-top:-35vh;flex-shrink:0;padding-bottom:100px}
		.header .mdl-layout__header-row{padding-left:40px}
		.container{max-width:1600px;width:calc(100% - 16px);margin:0 auto;min-height:600px}
		.content{border-radius:2px;padding:80px 56px;margin-bottom:80px}
		.layout.is-small-screen .content{padding:40px 28px}
		.content h3{margin-top:48px}
		.footer{padding-left:40px;position:absolute;bottom:0px;width:100%}
		.footer .mdl-mini-footer--link-list a{font-size:13px}
		.list-item {width: 300px}
	</style>
  </head>
  <body>
	<div class="layout mdl-layout mdl-layout--fixed-header mdl-js-layout mdl-color--grey-100">
		<header class="header mdl-layout__header mdl-layout__header--scroll mdl-color--grey-100 mdl-color-text--grey-800">
			<div class="mdl-layout__header-row">
				<span class="mdl-layout-title">VDR Images Server</span>
			</div>
		</header>
		<div class="ribbon"></div>
		<main class="main mdl-layout__content">
			<div class="container mdl-grid">
				<div class="mdl-cell mdl-cell--2-col mdl-cell--hide-tablet mdl-cell--hide-phone"></div>
				<div class="content mdl-color--white mdl-shadow--4dp content mdl-color-text--grey-800 mdl-cell mdl-cell--8-col">
					<span class="material-icons">list</span>
					<h3>Contents of the directory (${REQUEST_URI})</h3>
					<ul id="filelist" class="mdl-list">
EOH

#create list
ls -a --group-directories-first "..${REQUEST_URI#${SCRIPT_NAME}}" | grep -E -v "^.$" | grep -v "cgi-bin\|css\|error" |while read line
do
cat << EOH
						<li class="mdl-list__item">
							<span class="mdl-list__item-primary-content">
								<a href="$line" class="mdl-list__item-primary-content">$line</a>
							</span>
						</li>
EOH
done

cat << EOF
					</ul>
				</div>
			</div>
			<footer class="footer mdl-mini-footer">
				<div class="mdl-mini-footer--left-section">
					<ul class="mdl-mini-footer--link-list">
						<li><a href="https://github.com/pipelka/roboTV">Help</a></li>
						<li><a href="https://policies.google.com/">Privacy and Terms</a></li>
						<li><a href="https://getmdl.io/">Material Design Lite</a></li>
					</ul>
				</div>
			</footer>
		</main>
	</div>
	<a href="https://github.com/lapicidae/vdr-server/" target="_blank" id="git-link" class="mdl-button mdl-js-button mdl-button--raised mdl-js-ripple-effect mdl-color--accent mdl-color-text--accent-contrast">GitHub (vdr-server)</a>
	<script src="https://code.getmdl.io/1.3.0/material.min.js"></script>
  </body>
EOF
fi

echo "</html>"