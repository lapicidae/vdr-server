/**
 * VDR-Server Docker Web Interface - Core UI & Navigation
 * Handles dynamic component loading (Header/Footer), navigation state, and general UI utility.
 * * @requires UIkit 3.x (https://getuikit.com/)
 */

document.addEventListener("DOMContentLoaded", async () => {

	// --- 1. DOM Element References ---
	/** @type {HTMLElement|null} */
	const toTop = document.getElementById('back-to-top');
	/** @type {HTMLElement|null} */
	const placeholderSpinner = document.getElementById('placeholder-spinner');

	// --- 2. Component Loading Logic ---

	/**
	 * Shared logic to fetch and inject external HTML components into the DOM.
	 * @async
	 * @param {string} file - Path to the HTML file to fetch.
	 * @param {string} containerId - ID of the target DOM element.
	 * @returns {Promise<boolean>} True if injection was successful, false otherwise.
	 */
	async function injectComponent(file, containerId) {
		const container = document.getElementById(containerId);
		if (!container) return false;

		try {
			const response = await fetch(file);
			if (!response.ok) throw new Error(`HTTP error! status: ${response.status}`);
			const html = await response.text();
			container.innerHTML = html;
			return true;
		} catch (error) {
			console.error(`[UI] Error loading ${file}:`, error);
			return false;
		}
	}

	/**
	 * Orchestrates the loading of global UI parts (Header, Footer) and initializes UIkit components.
	 * @async
	 * @returns {Promise<void>}
	 */
	async function initGlobalUI() {
		// Load Header and Footer in parallel for better performance
		const [navLoaded, footerLoaded] = await Promise.all([
			injectComponent('/navigation.html', 'navigation-include'),
			injectComponent('/footer.html', 'footer-include')
		]);

		if (navLoaded) {
			const headerContainer = document.getElementById('navigation-include');
			
			// Hide loading spinner once navigation is injected
			if (placeholderSpinner) placeholderSpinner.setAttribute('hidden', '');

			// Trigger UIkit update to recognize newly injected DOM elements
			UIkit.update(document.body, 'update');

			// Specifically initialize navbar and sticky components if present
			const nav = headerContainer.querySelector('[uk-navbar]');
			const sticky = headerContainer.querySelector('[uk-sticky]');
			if (nav) UIkit.navbar(nav);
			if (sticky) UIkit.sticky(sticky);

			updateNavigationState(headerContainer);
		}
	}

	/**
	 * Synchronizes navigation links with the current URL path and handles accordion states.
	 * @param {HTMLElement} container - The container element holding the navigation links.
	 * @returns {void}
	 */
	function updateNavigationState(container) {
		const currentPath = window.location.pathname;
		const navLinks = container.querySelectorAll('ul.uk-navbar-nav a, ul.uk-nav a, ul.uk-nav-primary a');

		navLinks.forEach(link => {
			const href = link.getAttribute('href');
			if (!href || href === '#' || href.startsWith('javascript:')) return;
			
			// Normalize link path for comparison using the origin
			const linkPath = new URL(link.href, window.location.origin).pathname;

			if (linkPath === currentPath || (currentPath === '/' && linkPath === '/index.html')) {
				const parentLi = link.closest('li');
				if (parentLi) {
					parentLi.classList.add('uk-active');
					
					// Traverse upwards to activate and open parent menu items
					let ancestor = parentLi.parentElement.closest('li');
					while (ancestor) {
						ancestor.classList.add('uk-active');
						
						// If inside an off-canvas navigation, ensure accordions are expanded
						if (ancestor.classList.contains('uk-parent') && link.closest('.uk-offcanvas-bar')) {
							ancestor.classList.add('uk-open');
							
							// Force visibility of sub-menus (UIkit sometimes keeps them hidden via attribute)
							const subNav = ancestor.querySelector('ul');
							if (subNav) subNav.removeAttribute('hidden');
						}
						ancestor = ancestor.parentElement.closest('li');
					}
				}
			}
		});

		// Re-initialize all Nav components to ensure UIkit manages the injected state
		UIkit.nav(container.querySelectorAll('ul[uk-nav]'));
	}

	// --- 3. UI Helper Utilities ---

	/**
	 * Replaces host placeholders (myHost:PORT) in specific elements with the current server host.
	 * Uses innerHTML to preserve nested structures like list items.
	 * @returns {void}
	 */
	const replaceHostPlaceholders = () => {
		const items = document.querySelectorAll(".url_replace, .host_replace");
		const newHost = window.location.host;
		const oldHost = "myHost:PORT";

		if (newHost && items.length) {
			const searchRegex = new RegExp(oldHost, 'g');
			items.forEach(el => {
				if (el.innerHTML.includes(oldHost)) {
					el.innerHTML = el.innerHTML.replace(searchRegex, newHost);
				}
			});
		}
	};

	/**
	 * Initializes the scroll-based visibility logic for the 'back-to-top' button.
	 * @returns {void}
	 */
	const handleToTop = () => {
		if (!toTop) return;

		window.addEventListener('scroll', () => {
			const passed = window.scrollY > (window.innerHeight * 0.5);
			if (passed && toTop.hasAttribute('hidden')) {
				toTop.removeAttribute('hidden');
				UIkit.util.addClass(toTop, 'uk-animation-fade');
			} else if (!passed && !toTop.hasAttribute('hidden')) {
				toTop.setAttribute('hidden', '');
			}
		});
	};

	/**
	 * Global UIkit event listener to prevent tooltips from appearing on touch devices.
	 * Improves mobile UX by avoiding "sticky" tooltips.
	 */
	UIkit.util.on(document, 'beforeshow', '.uk-tooltip', (e) => {
		if ('ontouchstart' in window || navigator.maxTouchPoints > 0) {
			e.preventDefault();
		}
	});

	// --- 4. Initialization Execution ---

	// Start global UI injection
	await initGlobalUI();

	// Execute general helpers
	replaceHostPlaceholders();
	handleToTop();

});


// vim: ts=4 sw=4 noet:
// kate: space-indent off; indent-width 4; mixed-indent off;
