/**
 * VDR-Server Docker Web Interface
 * High-level application logic for streaming, UI interactions, and host management.
 * @requires UIkit 3.x (https://getuikit.com/)
 * @requires mpegts.js (required for streaming)
 */

/** @const {string} 
 * @description Path to the streamdev CGI proxy 
 */
const PROXY_PATH = '/cgi-bin/streamdev_proxy.cgi';

/** @type {boolean} 
 * @description Global toggle for console debug logging
 */
const DEBUG_MODE = false;

/**
 * Centralized debug logger.
 * @param {string} message - The message to log.
 * @param {string} [level='log'] - Console method to use (log, debug, info).
 */
const debugLog = (message, level = 'log') => {
	if (!DEBUG_MODE) return;
	console[level](message);
};

/** * @type {boolean} 
 * @description If true, prefers native WebKit HLS over Hls.js when available.
 */
const FORCE_NATIVE_HLS = false;

/** @const {Object<string, string>} 
 * @description CDNs for dynamic player library loading 
 */
const LIBS = {
	MPEGTS: 'https://cdn.jsdelivr.net/npm/mpegts.js@latest/dist/mpegts.min.js',
	HLS: 'https://cdn.jsdelivr.net/npm/hls.js@latest/dist/hls.min.js'
};

/**
 * @typedef {'idle'|'stopping'|'loading'|'playing'|'error'} PlayerStateValue
 *
 * @enum {PlayerStateValue}
 * @description Explicit player states for robust and predictable transitions.
 */
const PlayerState = Object.freeze({ 
	IDLE: 'idle', 
	STOPPING: 'stopping', 
	LOADING: 'loading', 
	PLAYING: 'playing', 
	ERROR: 'error' 
});

/** @type {Object<string, string>} 
 * @description Centralized UI text strings for consistency and easy maintenance 
 */
const UI_TEXT = Object.freeze({
	DEFAULT_TITLE: 'Live TV Player',
	STOPPED: 'Playback stopped.',
	CONNECTING: 'Connecting to ',
	PLAYING: 'Playing: ',
	RELOADING: 'Reloading playlist...',
	LOADING: 'Loading playlist...',
	READY: ' channels loaded and ready.',
	BUSY: 'Server busy. Retrying in ',
	CHOOSE_CHANNEL: '-- Choose Channel --',
	STREAMING_STATS: 'Streaming: ',
	PAUSED: 'Paused: ',
	ATTEMPT: 'Attempt',
	NOT_FOUND: 'not found in new playlist.',
	ERR_INVALID_URL: 'Invalid stream URL.',
	ERR_UNAVAILABLE: 'Stream currently unavailable.',
	ERR_STARTUP: 'Startup error.',
	ERR_AUTOPLAY: 'Autoplay blocked. Please click play.',
	ERR_LOAD: 'Load Error: ',
	ERR_EMPTY: 'Server returned empty data.',
	ERR_FULLSCREEN: 'Fullscreen error: ',
	DEINTERLACE_UNAVAILABLE: 'Not available with this quality',
	MUTED: 'Muted'
});

	/**
	 * Allowed state transitions for the player state machine.
	 * @const {Record<PlayerStateValue, PlayerStateValue[]>}
	 */
	const VALID_PLAYER_STATE_TRANSITIONS = Object.freeze({
		[PlayerState.IDLE]: [PlayerState.LOADING],
		[PlayerState.LOADING]: [PlayerState.PLAYING, PlayerState.ERROR, PlayerState.IDLE, PlayerState.STOPPING, PlayerState.LOADING],
		[PlayerState.PLAYING]: [PlayerState.STOPPING, PlayerState.ERROR, PlayerState.LOADING],
		[PlayerState.ERROR]: [PlayerState.LOADING, PlayerState.IDLE, PlayerState.STOPPING],
		[PlayerState.STOPPING]: [PlayerState.IDLE, PlayerState.ERROR, PlayerState.LOADING]
	});

	/** @const {Set<string>} */
	const IGNORE_PLAYER_ERRORS_WHILE = new Set([PlayerState.STOPPING, PlayerState.LOADING]);

	/**
	* Main application entry point on DOM content loaded.
	*/
	document.addEventListener("DOMContentLoaded", async () => {

	// --- 2. DOM Element References ---

	// Elements
	/** @type {HTMLSelectElement|null} */
	const channelSelect = document.getElementById('channelSelect');
	/** @type {HTMLSelectElement|null} */
	const streamTypeSelect = document.getElementById('streamTypeSelect');
	/** @type {HTMLSelectElement|null} */
	const qualitySelect = document.getElementById('qualitySelect');
	/** @type {HTMLInputElement|null} */
	const deinterlaceCheck = document.getElementById('deinterlaceCheck');
	/** @type {HTMLElement|null} */
	const deinterlaceContainer = document.getElementById('deinterlaceContainer');
	/** @type {HTMLElement|null} */
	const statusInfo = document.getElementById('statusInfo');
	/** @type {HTMLElement|null} */
	const stationName = document.getElementById('station-name');
	/** @type {HTMLVideoElement|null} */
	const videoElement = document.getElementById('videoElement');
	/** @type {HTMLImageElement|null} */
	const currentChannelLogo = document.getElementById('currentChannelLogo');
	/** @type {HTMLImageElement|null} */
	const playerPlaceholderLogo = document.getElementById('playerPlaceholderLogo');
	/** @type {HTMLButtonElement|null} */
	const ctrlPlayPause = document.getElementById('ctrlPlayPause');
	/** @type {HTMLButtonElement|null} */
	const ctrlMute = document.getElementById('ctrlMute');
	/** @type {HTMLInputElement|null} */
	const ctrlVolume = document.getElementById('ctrlVolume');
	/** @type {HTMLElement|null} */
	const volumeDisplay = document.getElementById('volumeDisplay');
	/** @type {HTMLButtonElement|null} */
	const stopBtn = document.getElementById('stopBtn');

	// --- 3. Runtime State ---

	/** @type {mpegts.Player|null} 
	 * @description mpegts.js player instance 
	 */
	let player = null;
	/** @type {'mpegts'|'hls'} 
	 * @description Currently active player engine 
	 */
	let currentEngine = 'mpegts';
	/** @type {string} 
	 * @description Current operational state of the player 
	 */
	let playerState = PlayerState.IDLE;
	/** @type {number} 
	 * @description Current retry attempt for stream errors 
	 */
	let retryCount = 0;
	/** @const {number} 
	 * @description Maximum allowed retries before giving up 
	 */
	const MAX_RETRIES = 3;
	/** @type {number} 
	 * @description Timestamp of the last UI status update for throttling 
	 */
	let lastStatusUpdate = 0;
	/** @const {Map<string, string|null>} 
	 * @description Cache for found/not-found logos 
	 */
	const logoCache = new Map();
	/** @type {AbortController|null} 
	 * @description Controller to cancel pending playlist fetches 
	 */
	let playlistAbortController = null;
	/** @type {Symbol|null} 
	 * @description Token to prevent race conditions during retries 
	 */
	let currentRetryToken = null;
	/** @type {Symbol|null} 
	 * @description Token to prevent race conditions during playlist reloads 
	 */
	let currentPlaylistToken = null;
	/** @type {string|null} 
	 * @description Cache to prevent redundant tooltip attribute updates 
	 */
	let lastTooltipText = null;
	/** @type {Object|null} 
	 * @description Cached UIkit tooltip instance for the volume slider 
	 */
	let volumeTooltip = null;
	/** @type {string[]} 
	 * @description Cached static UIkit tooltip options without the title 
	 */
	let cachedTooltipBase = null;
	/** @type {Symbol|null} 
	 * @description Token to track the most recent play request and prevent races 
	 */
	let currentPlayToken = null;
	/** @type {number|null} 
	 * @description Cached speed value to prevent redundant UI updates 
	 */
	let lastSpeedValue = null;

	// --- 5. UI Helpers ---

	/**
	 * Detects the browser engine and its primary version.
	 * @returns {string} Formatted string with engine name and major version.
	 */
	const getBrowserDetails = () => {
		const ua = navigator.userAgent;
		/** @const {Array<{key: string, name: string, not?: string}>} */
		const parsers = [
			{ key: 'Edg/', name: 'Chromium (Edge)' },
			{ key: 'Chrome/', name: 'Chromium (Chrome)' },
			{ key: 'Firefox/', name: 'Gecko (Firefox)' },
			{ key: 'Safari/', name: 'WebKit (Safari)', not: 'Chrome/' }
		];

		for (const p of parsers) {
			if (ua.includes(p.key) && (!p.not || !ua.includes(p.not))) {
				const match = ua.match(new RegExp(`${p.key.replace('/', '\\/')}(\\d+)`));
				return `${p.name} ${match ? match[1] : ''}`;
			}
		}
		return 'Unknown Engine';
	};

	/**
	 * Prevents tooltips from showing on touch interactions to improve mobile UX.
	 * @listens UIkit:beforeshow
 	 */
	UIkit.util.on(document, 'beforeshow', '.uk-tooltip', (e) => {
		// UIkit's util.isTouch is not globally exported easily, 
		// so we check the source event that triggered the show.
		if ('ontouchstart' in window || navigator.maxTouchPoints > 0) {
			e.preventDefault();
		}
	});

	/**
	 * Updates the internal player state with transition validation.
	 * @param {string} next - The target PlayerState.
	 * @returns {void}
	 */
	const setPlayerState = (next) => {
		if (playerState === next) return;

		if (!VALID_PLAYER_STATE_TRANSITIONS[playerState]?.includes(next)) {
			debugLog(`[STATE] Invalid transition ignored: ${playerState} -> ${next}`, 'warn');
			// Always unlock UI on rejected transitions to prevent freezing
			toggleConfigUI(false);
			return;
		}
		playerState = next;
		debugLog(`[STATE] ${next}`, 'debug');
	};

	/**
	 * Determines if the current state justifies suppressing player errors.
	 * @returns {boolean}
	 */
	const shouldIgnoreError = () => IGNORE_PLAYER_ERRORS_WHILE.has(playerState);

	/**
	 * Checks if the player is currently in a state transition controlled by code.
	 * Used to suppress noisy browser errors (like AbortError) during playlist switching.
	 * @returns {boolean}
	 */
	const isInternalTransition = () => playerState === PlayerState.LOADING || playerState === PlayerState.STOPPING;

	/**
	 * Toggles the disabled state of main configuration UI elements.
	 * Prevents user interaction during asynchronous loading phases.
	 * @param {boolean} disabled - Whether the elements should be disabled.
	 */
	const toggleConfigUI = (disabled) => {
		if (channelSelect) channelSelect.disabled = disabled;
		if (streamTypeSelect) streamTypeSelect.disabled = disabled;
		if (qualitySelect) qualitySelect.disabled = disabled;
		if (deinterlaceCheck) deinterlaceCheck.disabled = disabled;
	};

	/**
	 * Dynamically loads a script if it is not already present.
	 * @param {string} url - The URL of the script.
	 * @param {string} globalCheck - The global variable to check (e.g., 'Hls').
	 * @returns {Promise<void>}
	 */
	const loadLibrary = (url, globalCheck) => {
		if (window[globalCheck]) return Promise.resolve();
		debugLog(`[LIB] Loading: ${url}`);
		return new Promise((resolve, reject) => {
			const script = document.createElement('script');
			script.src = url;
			script.onload = () => { 
 				debugLog(`[LIB] Loaded: ${globalCheck}`); 
				// If mpegts was loaded, sync its internal logger with our DEBUG_MODE
				if (globalCheck === 'mpegts' && window.mpegts) {
					mpegts.LoggingControl.enableAll = DEBUG_MODE;
					mpegts.LoggingControl.enableDebug = DEBUG_MODE;
					mpegts.LoggingControl.enableLog = DEBUG_MODE;
					mpegts.LoggingControl.enableInfo = DEBUG_MODE;
					mpegts.LoggingControl.enableWarn = DEBUG_MODE;
					mpegts.LoggingControl.enableError = true; // Always show errors
				}
 				resolve();
			};
			script.onerror = () => reject(new Error(`Failed to load ${url}`));
			document.head.appendChild(script);
		});
	};

	// --- 4. Content Loading Modules ---

	/**
	 * Safely updates element text if the element exists.
	 * @param {HTMLElement|null} el - The target element.
	 * @param {string} text - The text to set.
	 */
	const safeText = (el, text) => { if (el && el.textContent !== text) el.textContent = text; };

	// --- 5. Volume Management ---

	/**
	 * Batches all volume UI updates into a single animation frame.
	 * Synchronizes slider, display text, mute icon, and tooltips.
	 * @returns {void}
	 */
	function syncVolumeUI() {
		if (!ctrlVolume) return;

		const value = parseFloat(ctrlVolume.value);
		const isMuted = value === 0 || (videoElement && videoElement.muted);
		const percent = isMuted ? UI_TEXT.MUTED : Math.round(value * 100) + '%';

		// Batch all DOM-related updates into the next animation frame for maximum performance
		requestAnimationFrame(() => {
			updateVolumeDisplay(percent, isMuted);

			// Visual feedback using toggle for efficiency
			ctrlMute.classList.toggle('uk-text-warning', isMuted);
			ctrlVolume.classList.toggle('uk-text-muted', isMuted);
			volumeDisplay.classList.toggle('uk-text-emphasis', isMuted);
			volumeDisplay.classList.toggle('uk-text-warning', isMuted);

			// Lazy-initialize or retrieve the tooltip instance
			if (!volumeTooltip && ctrlVolume) {
				volumeTooltip = UIkit.tooltip(ctrlVolume);
			}
			const tooltip = volumeTooltip;
			const isVisible = tooltip?.tooltip && tooltip.tooltip.classList.contains('uk-active');

			if (isVisible) {
				updateTooltip(percent, tooltip);
			} else {
				updateTooltipAttribute(percent);
			}
		});
	}

	/**
	 * Updates the textual volume percentage and the mute icon.
	 * @param {string} percent - The formatted percentage string.
	 * @param {boolean} isMuted - Whether the audio is currently muted.
	 */
	function updateVolumeDisplay(percent, isMuted) {
		safeText(volumeDisplay, percent);
		if (ctrlMute) ctrlMute.setAttribute('uk-icon', isMuted ? 'mute' : 'volume');
	}

	/**
	 * Updates the uk-tooltip attribute string only if it has changed.
	 * @param {string} percent - The formatted percentage string.
	 */
	function updateTooltipAttribute(percent) {
		if (!ctrlVolume.hasAttribute('uk-tooltip') || percent === lastTooltipText) return;
		lastTooltipText = percent;

		if (cachedTooltipBase === null) {
			const currentAttr = ctrlVolume.getAttribute('uk-tooltip') || '';
			cachedTooltipBase = currentAttr.split(';')
				.map(p => p.trim())
				.filter(p => p && !p.startsWith('title:'));
		}
		
		const parts = [`title: ${percent}`, ...cachedTooltipBase];
		const updatedAttr = parts.join('; ');

		ctrlVolume.setAttribute('uk-tooltip', updatedAttr);
	}

	/**
	 * Updates the live UIkit tooltip DOM instance and internal state.
	 * @param {string} percent - The formatted percentage string.
	 * @param {Object} tooltip - The UIkit tooltip instance.
	 */
	function updateTooltip(percent, tooltip) {
		if (!tooltip?.tooltip) return;

		updateTooltipAttribute(percent);
		
		tooltip.title = percent; 
		const inner = tooltip.tooltip.querySelector('.uk-tooltip-inner');
		if (inner) inner.textContent = percent;

		tooltip.update();
	}

	// --- 6. Status & Logo Management ---

	/**
	 * Transitions the application to the playing state.
	 * @param {string} name - The station name.
	 */
	function markAsPlaying(name) {
		// Only transition to PLAYING if we are currently in LOADING state.
		// This prevents logic errors if a stream starts while stopping.
		if (playerState !== PlayerState.LOADING) return;
		
		setPlayerState(PlayerState.PLAYING);
		retryCount = 0;
		toggleConfigUI(false); // Unlock UI once streaming is stable
		updateStatus(`${UI_TEXT.PLAYING}${name}`, 'success', true, true);
	}

	/** @const {Object<string, string>} Mapping for alert types to CSS classes */
	const STATUS_CLASSES = {
		'info': 'uk-alert-primary',
		'success': 'uk-alert-success',
		'warning': 'uk-alert-warning',
		'error': 'uk-alert-danger'
	};

	/**
	 * Displays a status message in the UI with throttling and log levels.
	 * @param {string} message - Message text.
	 * @param {string} [type='info'] - The alert type.
	 * @param {boolean} [logToConsole=true] - Log to browser console.
	 * @param {boolean} [force=false] - Bypass throttling.
	 */
	function updateStatus(message, type = 'info', logToConsole = true, force = false) {
		if (!statusInfo) return;

		const now = Date.now();
		if (!force && now - lastStatusUpdate < 800 && type === 'info') return;
		lastStatusUpdate = now;

		if (logToConsole) {
			if (type === 'error') console.error(`[STATUS] ${message}`);
			else if (type === 'warning') console.warn(`[STATUS] ${message}`);
			else debugLog(`[STATUS] ${message}`);
		}

		statusInfo.textContent = message;
		statusInfo.classList.remove(...Object.values(STATUS_CLASSES));
		statusInfo.classList.add(STATUS_CLASSES[type] || STATUS_CLASSES['info']);
	}

	/**
	 * Updates the status UI with the current streaming bitrate.
	 * Handles rolling average calculation, string formatting, and CSS class switching.
	 * @param {string} name - The station name.
	 * @param {number} currentBitrateMbit - The latest measured bitrate in Mbit/s.
	 * @param {number[]} historyBuffer - Reference to the engine's bitrate history array.
	 * @param {number} [maxHistory=4] - Maximum number of samples to keep for smoothing.
	 */
	function updateBitrateUI(name, currentBitrateMbit, historyBuffer, maxHistory = 4) {
		if (playerState !== PlayerState.PLAYING || !statusInfo) return;

		// 1. Smooth the data
		historyBuffer.push(currentBitrateMbit);
		if (historyBuffer.length > maxHistory) historyBuffer.shift();
		
		const avgBitrate = historyBuffer.reduce((a, b) => a + b, 0) / historyBuffer.length;
		
		// 2. Prepare UI elements
		const prefix = (typeof UI_TEXT !== 'undefined' && UI_TEXT.PLAYING) ? UI_TEXT.PLAYING : "Playing: ";
		const statusText = `${prefix}${name} (${avgBitrate.toFixed(2)} Mbit/s)`;

		// 3. Batch DOM updates
		requestAnimationFrame(() => {
			// Ensure the bar is blue (primary) for technical info, not green (success)
			statusInfo.classList.replace('uk-alert-success', 'uk-alert-primary');
			
			// Update text only if it actually changed to save paint cycles
			if (statusInfo.innerText !== statusText) {
				statusInfo.innerText = statusText;
			}
			
			// debugLog(`[STATS] ${avgBitrate.toFixed(2)} Mbit/s`);
		});
	}

	// --- 7. Player Lifecycle ---

	/**
	 * Performs complete cleanup of the mpegts player and resets UI.
	 * @param {Object} [options={}] - Options.
	 * @param {boolean} [options.silent=false] - Whether to suppress the status update.
	 * @param {string} [options.nextState=PlayerState.IDLE] - The state to transition to after destruction.
	 */
	function destroyPlayer({ silent = false, nextState = PlayerState.IDLE } = {}) {
		if (playerState !== PlayerState.STOPPING) {
			setPlayerState(PlayerState.STOPPING);
		}

		if (player) {
			try {
				debugLog(`[CLEANUP] Destroying ${currentEngine} instance...`);
				if (currentEngine === 'hls') {
					// HLS.js cleanup
					player.destroy();
				} else {
					// mpegts.js cleanup (Existing logic)
					player.pause();
					player.unload();
					player.detachMediaElement();
					player.destroy();
				}
			} catch (e) {
				console.warn("Player cleanup warning:", e);
			}
			player = null;
		}

		if (videoElement) {
			videoElement.pause();
			videoElement.removeAttribute('src');
			videoElement.load();
		}

		// Reset retry logic on every intentional destruction
		retryCount = 0;
		lastTooltipText = null;
		cachedTooltipBase = null;

		if (volumeTooltip?.tooltip) {
			volumeTooltip.hide();
		}
		volumeTooltip = null;

		// Reset Play/Pause button icon to 'play'
		if (ctrlPlayPause) ctrlPlayPause.setAttribute('uk-icon', 'play');

		toggleConfigUI(false); // Ensure UI is usable after stopping
		if (nextState !== PlayerState.STOPPING) {
			setPlayerState(nextState);
		}
		safeText(stationName, UI_TEXT.DEFAULT_TITLE);

		if (currentChannelLogo) {
			currentChannelLogo.classList.add('uk-invisible');
			currentChannelLogo.src = '/img/favicon.svg';
		}

		if (playerPlaceholderLogo) {
			playerPlaceholderLogo.src = '/img/favicon.svg';
			playerPlaceholderLogo.style.opacity = "0.1";
		}

		if (!silent) updateStatus(UI_TEXT.STOPPED, 'info', true, true);
	}

	/**
	 * Updates channel logos with priority lookup and caching.
	 * @async
	 * @param {string} name - Station name.
	 */
	async function updateLogo(name) {
		if (!name || name === UI_TEXT.DEFAULT_TITLE) return;

		/**
		 * Attempts to resolve a logo path.
		 * @param {string} rawName - The raw station name to format.
		 * @returns {Promise<string|null>} The resolved path or null.
		 */
		const resolvePath = async (rawName) => {
			const filename = rawName.trim().toLowerCase() + '.png';
			const logoPath = `channellogos/${encodeURIComponent(filename)}`;

			if (logoCache.has(logoPath)) return logoCache.get(logoPath);

			return new Promise((resolve) => {
				const testImg = new Image();
				testImg.onload = () => {
					logoCache.set(logoPath, logoPath);
					resolve(logoPath);
				};
				testImg.onerror = () => {
					logoCache.set(logoPath, null);
					resolve(null);
				};
				testImg.src = logoPath;
			});
		};

		// Priority: Clean Name -> Original Name -> Name without HD suffix
		const candidates = [
			name.replace(/^\d+\s+/, ''),
			name,
			name.replace(/^\d+\s+/, '').replace(/\s+hd\d*$/i, '')
		];

		let path = null;
		for (const candidate of candidates) {
			path = await resolvePath(candidate);
			if (path) break;
		}

		if (path && currentChannelLogo && playerPlaceholderLogo) {
			currentChannelLogo.src = path;
			currentChannelLogo.classList.remove('uk-invisible');
			playerPlaceholderLogo.src = path;
			playerPlaceholderLogo.style.opacity = "0.3";
		}
	}

	/**
	 * Toggles the fullscreen state of the video element.
	 * Supports standard and essential WebKit prefixes for mobile compatibility.
	 */
	function toggleFullscreen() {
		if (!videoElement || (playerState !== PlayerState.PLAYING && playerState !== PlayerState.LOADING)) return;

		debugLog(`[UI] Attempting Fullscreen on: ${getBrowserDetails()}`);

		const requestFn = videoElement.requestFullscreen || 
						  videoElement.webkitRequestFullscreen || 
						  videoElement.webkitEnterFullscreen;

		if (requestFn) {
			// Bind the function to videoElement to ensure correct 'this' context
			requestFn.call(videoElement)?.catch(() => {});
		}
	}

	/**
	 * Updates the deinterlace checkbox state.
	 * Uses a data-attribute for logic instead of the native disabled property.
	 */
	function updateDeinterlaceState() {
		if (!qualitySelect || !deinterlaceCheck || !deinterlaceContainer) return;

		const selectedOption = qualitySelect.options[qualitySelect.selectedIndex];
		const isForbidden = selectedOption.hasAttribute('data-disable-deinterlace');
		const label = deinterlaceContainer.querySelector('label[for="deinterlaceCheck"]');

		if (isForbidden) {
			// UI-State
			deinterlaceCheck.classList.add('uk-disabled');
			if (label) label.classList.add('uk-disabled', 'uk-text-muted');
			
			// Logical-State
			deinterlaceCheck.dataset.active = "false";
			
			UIkit.tooltip(deinterlaceContainer, {title: UI_TEXT.DEINTERLACE_UNAVAILABLE, delay: '300'});
			deinterlaceContainer.style.setProperty('cursor', 'not-allowed', 'important');
		} else {
			deinterlaceCheck.classList.remove('uk-disabled');
			if (label) label.classList.remove('uk-disabled', 'uk-text-muted');

			// Logical-State
			deinterlaceCheck.dataset.active = "true";

			const tooltip = UIkit.tooltip(deinterlaceContainer);
			if (tooltip) tooltip.$destroy();
			deinterlaceContainer.style.cursor = '';
		}
	}

	/**
	 * Parses raw M3U data and updates the channel dropdown.
	 * @param {string} content - Raw M3U string.
	 * @throws {Error} If no valid channels are found.
	 */
	function parseM3U(content) {
		if (!channelSelect) return;
		const lines = content.replace(/\r/g, "").split('\n').filter(l => l.trim() !== "");
		const previousText = channelSelect.options[channelSelect.selectedIndex]?.text;

		channelSelect.innerHTML = `<option value="">${UI_TEXT.CHOOSE_CHANNEL}</option>`;
		let count = 0;
		let currentName = null;

		lines.forEach(line => {
			const cleanLine = line.trim();
			if (cleanLine.startsWith('#EXTINF:')) {
				currentName = cleanLine.split(',').slice(1).join(',') || "Unknown Station";
			} else if (/^https?:\/\//i.test(cleanLine)) {
				const stationTitle = currentName || "Unknown Station";
				try {
					const url = new URL(cleanLine);
					const vdrPath = url.pathname.substring(1) + url.search;
					const option = new Option(stationTitle, `${PROXY_PATH}?path=${vdrPath}`);
					channelSelect.add(option);
					count++;
				} catch (e) {
					console.warn("Invalid URL in M3U:", cleanLine);
				}
				currentName = null; // Reset to prevent name-carryover to next URL
			}
		});

		if (count === 0) throw new Error("Playlist empty.");
		if (previousText) {
			const optToRestore = Array.from(channelSelect.options).find(o => o.text === previousText);
			if (optToRestore) channelSelect.value = optToRestore.value;
		}
		updateStatus(`${count}${UI_TEXT.READY}`, 'success', true, true);
	}

	/**
	 * Fetches the M3U playlist from the server.
	 * @async
	 * @param {number} [attempt=1] - Retry attempt.
	 * @param {string|null} [forcedActiveStation=null] - Station to restart after load.
	 * @param {boolean} [isInitial=false] - Initial page load flag.
	 */
	async function loadPlaylist(attempt = 1, forcedActiveStation = null, isInitial = false) {
		if (!channelSelect) return;

		// Cancel pending requests only on first attempt
		if (attempt === 1 && playlistAbortController) {
			playlistAbortController.abort();
		}
		if (attempt === 1) {
			playlistAbortController = new AbortController();
			currentPlaylistToken = Symbol();
		}
		const token = currentPlaylistToken;

		// Capture the station name only on the first attempt, then carry it through
		const activeStation = forcedActiveStation || 
							  ((player && stationName && stationName.textContent !== UI_TEXT.DEFAULT_TITLE)
							  ? stationName.textContent : null);

		// Lock UI to prevent concurrent configuration changes
		toggleConfigUI(true);

		if (activeStation && attempt === 1) {
			updateStatus(`Updating settings for ${activeStation}...`, 'info', true, true);
			destroyPlayer({ silent: true }); 
			setPlayerState(PlayerState.LOADING);
			await new Promise(r => setTimeout(r, 800));
		} else if (!activeStation && attempt === 1) {
			const msg = isInitial ? UI_TEXT.LOADING : UI_TEXT.RELOADING;
			updateStatus(msg, 'info', true, true);
		}

		let qualityPath = "EXT";
		if (qualitySelect?.value !== "DEFAULT") qualityPath += `;QUALITY=${qualitySelect.value}`;

		try {
			// Only request deinterlaced streams if checked AND quality allows it
			const isDeinterlaceValid = deinterlaceCheck?.checked && deinterlaceCheck.dataset.active !== "false";
			if (isDeinterlaceValid) qualityPath += ";DEINTERLACE=true";

			saveSettings(); // Persist current UI selection

			const response = await fetch(`${PROXY_PATH}?path=${qualityPath}/channels.m3u`, {
				cache: "no-store",
				signal: playlistAbortController.signal
			});

			if (!response.ok) throw new Error(`HTTP ${response.status}`);

			const data = await response.text();

			// Token check BEFORE parsing to prevent redundant DOM operations
			if (token !== currentPlaylistToken) {
				return;
			}

			if (!data.trim()) {
				if (attempt < 3) {
					console.warn(`Empty playlist, retry ${attempt}...`);
					await new Promise(r => setTimeout(r, 1000));
					return loadPlaylist(attempt + 1, activeStation);
				}
				throw new Error(UI_TEXT.ERR_EMPTY);
			}

			parseM3U(data);
			toggleConfigUI(false); // Unlock UI after successful parsing

			if (activeStation) {
				setTimeout(() => {
					// Token check: Ensure we only restart the station if no 
					// newer playlist request has been started in the meantime.
					if (token !== currentPlaylistToken) return;

					const options = Array.from(channelSelect.options);
					const opt = options.find(o => o.text === activeStation);
					
					if (opt) {
						retryCount = 0;
						play(opt.value, opt.text);
					} else if (playerState === PlayerState.LOADING) {
						setPlayerState(PlayerState.IDLE);
					} else {
						console.warn(`${activeStation} ${UI_TEXT.NOT_FOUND}`);
						setPlayerState(PlayerState.IDLE);
					}
				}, 1200);
			}
		} catch (err) {
			if (err.name === 'AbortError') return;
			
			if (attempt < 3 && err instanceof TypeError) {
				console.warn(`Fetch flood protection active. Retry ${attempt}...`);
				await new Promise(r => setTimeout(r, 1000 * attempt));
				return loadPlaylist(attempt + 1, activeStation);
			}

			setPlayerState(PlayerState.IDLE);
			toggleConfigUI(false); // Ensure UI is unlocked even on error
			updateStatus(UI_TEXT.ERR_LOAD + err.message, 'warning', true, true);
		}
	}

	// ---------------------------------------------------------------------
	// Player Lifecycle
	// ---------------------------------------------------------------------

	/**
	 * Initializes and starts the mpegts.js player for a specific channel.
	 *
	 * @param {string} url - Proxy URL of the stream.
	 * @param {string} name - Display name of the station.
	 */
	async function play(url, name) {
	if (!url || !videoElement || playerState === PlayerState.STOPPING) return;

	const mode = streamTypeSelect?.value || 'ts';
	debugLog(`[PLAY] Requested mode: ${mode.toUpperCase()} for ${name}`);

	// Cleanup ANY existing bitrate timers (MPEGTS or HLS) immediately
	if (window.bitrateTimer) {
		clearInterval(window.bitrateTimer);
		window.bitrateTimer = null;
	}

	try {
		if (mode === 'hls') {
			await loadLibrary(LIBS.HLS, 'Hls');
			currentEngine = 'hls';
		} else {
			await loadLibrary(LIBS.MPEGTS, 'mpegts');
			currentEngine = 'mpegts';
		}
	} catch (e) {
		updateStatus("Library load failed", 'error');
		return;
	}

	const playToken = Symbol('playIntent');
	currentPlayToken = playToken;
	retryCount = 0;
	lastSpeedValue = null;

	const streamUrl = url.startsWith('http') ? url : window.location.origin + url;
	const finalUrl = mode === 'hls' ? `${streamUrl}&mode=hls` : streamUrl;
	
	debugLog(`[PLAY] URL: ${finalUrl}`);

	if (playerState !== PlayerState.LOADING) {
		destroyPlayer({ silent: true, nextState: PlayerState.LOADING });
	}

	safeText(stationName, name);
	updateLogo(name);
	updateStatus(`${UI_TEXT.CONNECTING}${name}...`, 'info', true, true);
	toggleConfigUI(true);

	if (currentPlayToken !== playToken) {
		toggleConfigUI(false); 
		return;
	}

	// --- HLS Engine ---
	if (currentEngine === 'hls') {
		const browserInfo = getBrowserDetails();
		debugLog(`[HLS] Logic check for engine: ${browserInfo}`);

		const canNative = videoElement.canPlayType('application/vnd.apple.mpegurl');

		// Prefer native if forced OR if Hls.js is not supported
		if (canNative && (FORCE_NATIVE_HLS || !Hls.isSupported())) {
			debugLog(`[HLS] Engine: ${browserInfo} -> Using Native WebKit HLS (Forced: ${FORCE_NATIVE_HLS})`);

			videoElement.src = finalUrl;

			videoElement.addEventListener('canplay', () => {
				if (currentPlayToken === playToken) {
					markAsPlaying(name);
					videoElement.play().catch(e => debugLog(`[HLS] Native play failed: ${e.message}`, 'error'));
				}
			}, { once: true });

			// Simple shim for the player object to allow clean destruction
			player = { destroy: () => { 
				videoElement.pause(); 
				videoElement.removeAttribute('src'); 
				videoElement.load(); 
			}};
		} 
		else if (Hls.isSupported()) {
			// Standard path for Desktop (Chrome, Firefox, Safari Default)
			debugLog(`[HLS] Engine: ${browserInfo} -> Using Hls.js (MSE)`);
			const hls = new Hls({ debug: false, enableWorker: true, lowLatencyMode: true });
			player = hls;
			hls.loadSource(finalUrl);
			hls.attachMedia(videoElement);

			const bitrateHistory = [];

			/** @description Monitor HLS content bitrate via fragments */
			hls.on(Hls.Events.FRAG_BUFFERED, (event, data) => {
				if (currentPlayToken !== playToken || playerState !== PlayerState.PLAYING) return;
				const frag = data.frag;
				const bytes = frag.stats.total || frag.stats.loaded;
				const duration = frag.duration;
				if (duration > 0 && bytes > 0) {
					const mbit = (bytes * 8) / duration / 1000000;
					updateBitrateUI(name, mbit, bitrateHistory);
				}
			});

			hls.on(Hls.Events.MEDIA_ATTACHED, () => {
				if (currentPlayToken === playToken) {
					markAsPlaying(name);
					videoElement.play().catch(() => {});
				}
			});

			hls.on(Hls.Events.ERROR, (event, data) => {
				if (data.fatal) destroyPlayer({ silent: false, nextState: PlayerState.ERROR });
				else if (data.details === 'bufferStalledError') hls.startLoad();
			});
		}
	}

	// --- MPEGTS Engine ---
	if (currentEngine === 'mpegts') {
		player = mpegts.createPlayer({
			type: 'mpegts', isLive: true, url: finalUrl
		}, {
			enableStashBuffer: false, 
			liveBufferLatencyChasing: true, 
			reuseInternalLoader: false
		});

		window.activePlayer = player;
		const localPlayer = player;
		const speedHistory = [];

		player.on(mpegts.Events.ERROR, (type, detail) => {
			if (player !== localPlayer || shouldIgnoreError()) return;
			destroyPlayer({ silent: true, nextState: PlayerState.ERROR });
		});

		player.on(mpegts.Events.MEDIA_INFO, () => {
			if (player !== localPlayer) return;
			markAsPlaying(name);
		});

		player.attachMediaElement(videoElement);

		const startMpegtsMonitor = () => {
			window.bitrateTimer = setInterval(() => {
				if (player !== localPlayer || playerState !== PlayerState.PLAYING) return;
				const stats = player.statisticsInfo;
				if (!stats || typeof stats.speed === 'undefined') return;

				// speed is in KB/s -> convert to Mbit/s
				const mbit = (stats.speed * 8) / 1000;
				updateBitrateUI(name, mbit, speedHistory, 3);
			}, 3000);
		};

		try {
			player.load();
			setTimeout(startMpegtsMonitor, 2000);
			setTimeout(() => { if (player === localPlayer) videoElement.play().catch(() => {}); }, 500);
		} catch (e) {
			updateStatus(UI_TEXT.ERR_STARTUP, 'error', true, true);
		}
	}
}

	/**
	 * Saves current UI settings (Quality, Deinterlace) to localStorage.
	 */
	function saveSettings() {
		if (streamTypeSelect) {
			localStorage.setItem('playerStreamMode', streamTypeSelect.value);
		}
		if (qualitySelect) {
			localStorage.setItem('playerQuality', qualitySelect.value);
		}
		if (deinterlaceCheck) {
			localStorage.setItem('playerDeinterlace', deinterlaceCheck.checked);
		}
	}

	// --- 5. Custom Controls Logic ---

	/**
	 * Handles Play/Pause toggle for the active stream or starts a new one.
	 * Also allows restarting the stream if the player is in an error state.
	 * @function handlePlayPause
	 */
	const handlePlayPause = () => {
		const opt = channelSelect?.options[channelSelect.selectedIndex];

		if (player && playerState === PlayerState.PLAYING) {
			if (videoElement?.paused) {
				videoElement.play().catch(() => {});
			} else {
				videoElement?.pause();
			}
		} 
		// Allow restart if idle OR if previously failed with an error
		else if ((playerState === PlayerState.IDLE || playerState === PlayerState.ERROR) && opt?.value) {
			retryCount = 0;
			debugLog(`[UI] Restarting stream from state: ${playerState}`);
			play(opt.value, opt.text);
		}
	};

	/**
	 * Toggles native browser controls based on the current fullscreen state.
	 * @function handleFullscreenChange
	 */
	const handleFullscreenChange = () => {
		if (!videoElement) return;

		// Use standard property, with a fallback for WebKit-based browsers (iOS/Safari)
		const isFullscreen = !!(document.fullscreenElement || document.webkitFullscreenElement);
		
		videoElement.controls = isFullscreen;
		debugLog(`[UI] Fullscreen state changed. Native controls: ${isFullscreen}`);
	};

	// --- 8. Event Binding ---

	ctrlPlayPause?.addEventListener('click', handlePlayPause);
	stopBtn?.addEventListener('click', () => { currentRetryToken = null; if (playlistAbortController) playlistAbortController.abort(); destroyPlayer(); });
	/**
	 * Toggles mute state and synchronizes volume UI.
	 * @listens click
	 */
	ctrlMute?.addEventListener('click', () => {
		if (!videoElement || !ctrlVolume) return;
		
		const newMuteState = !videoElement.muted;
		videoElement.muted = newMuteState;

		// Persist the new mute state to allow restoration on next boot
		localStorage.setItem('playerMuted', newMuteState);

		// If unmuting while slider is at 0, boost to 10% so user hears something
		if (!newMuteState && parseFloat(ctrlVolume.value) === 0) {
			ctrlVolume.value = 0.1;
			videoElement.volume = 0.1;
		}

		syncVolumeUI();
	});

	/**
	 * Updates volume and mute state on slider interaction.
	 * @param {InputEvent} e
	 */
	ctrlVolume?.addEventListener('input', (e) => {
		if (!videoElement) return;

		const val = parseFloat(e.target.value);
		 
		videoElement.volume = val;
		videoElement.muted = (val === 0);
		
		syncVolumeUI();
	});

	// Blur slider after interaction to hide tooltip on mouse out
	ctrlVolume?.addEventListener('change', () => {
		ctrlVolume.blur();
		syncVolumeUI();
	});

	/**
	 * Binds fullscreen toggle functionality to all responsive triggers.
	 * Using data-action ensures logic persists across different UI breakpoints.
	 */
	document.querySelectorAll('[data-action="videoFullscreen"]').forEach(btn => {
		btn.addEventListener('click', toggleFullscreen);
	});

	// Double click on video to toggle fullscreen
	videoElement?.addEventListener('dblclick', toggleFullscreen);

	// --- Execution ---
	syncVolumeUI();

	// Restore Settings (Stream Mode, Quality and Deinterlace) before loading playlist
	const savedMode = localStorage.getItem('playerStreamMode');
	if (savedMode && streamTypeSelect) {
		streamTypeSelect.value = savedMode;
	}

	const savedQuality = localStorage.getItem('playerQuality');
	if (savedQuality && qualitySelect) {
		qualitySelect.value = savedQuality;
	}

	const savedDeinterlace = localStorage.getItem('playerDeinterlace');
	if (savedDeinterlace !== null && deinterlaceCheck) {
		deinterlaceCheck.checked = (savedDeinterlace === 'true');
	}

	if (channelSelect) {
		// Pass 'true' for isInitial and 'null' for the forced station
		loadPlaylist(1, null, true); 

		let configTimeout;
		const debouncedLoad = () => {
			clearTimeout(configTimeout);
			// Default calls (like from settings change) will use isInitial = false
			configTimeout = setTimeout(loadPlaylist, 500);
		};

		qualitySelect?.addEventListener('change', debouncedLoad);
		qualitySelect?.addEventListener('change', updateDeinterlaceState);
		streamTypeSelect?.addEventListener('change', debouncedLoad);
		deinterlaceCheck?.addEventListener('change', debouncedLoad);

		// Initial check on page load
		updateDeinterlaceState();

		channelSelect.addEventListener('change', (e) => {
			const opt = e.target.options[e.target.selectedIndex];
			if (opt?.value) { retryCount = 0; play(opt.value, opt.text); }
		});

		// Sync icons with video element state
		videoElement?.addEventListener('play', () => ctrlPlayPause?.setAttribute('uk-icon', 'pause'));
		videoElement?.addEventListener('pause', () => {
			if (ctrlPlayPause) ctrlPlayPause.setAttribute('uk-icon', 'play');
			
			// Update status message when manually paused (avoiding 'ended' state)
			if (playerState === PlayerState.PLAYING && stationName && !videoElement.ended) {
				updateStatus(`${UI_TEXT.PAUSED}${stationName.textContent}`, 'info', false);
			}
		});

		// Handle Fullscreen UI toggle
		document.addEventListener('fullscreenchange', handleFullscreenChange);
		document.addEventListener('webkitfullscreenchange', handleFullscreenChange);
	}

	/**
	 * Restores the saved volume and mute state from localStorage on startup.
 	 */
	const savedVolume = localStorage.getItem('playerVolume');
	const savedMuteState = localStorage.getItem('playerMuted');
	if (savedVolume !== null && ctrlVolume && videoElement) {
		const vol = parseFloat(savedVolume);
		ctrlVolume.value = vol;
		videoElement.volume = vol;

		// Restore mute state either from explicit 'playerMuted' or if vol is 0
		videoElement.muted = (savedMuteState === 'true') || (vol === 0);

		syncVolumeUI();
	}

	/**
	 * Synchronizes custom volume UI and saves the state to localStorage.
	 * This handles changes from both custom UI and native fullscreen controls.
	 */
	videoElement?.addEventListener('volumechange', () => {
		if (!ctrlVolume || !videoElement) return;

		// Update the slider value to match the video element's volume
		ctrlVolume.value = videoElement.volume;

		// Persist both volume level and mute state to localStorage
		localStorage.setItem('playerVolume', videoElement.volume);
		localStorage.setItem('playerMuted', videoElement.muted);

		syncVolumeUI();
	});

});


// vim: ts=4 sw=4 noet:
// kate: space-indent off; indent-width 4; mixed-indent off;
