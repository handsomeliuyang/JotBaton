// @ts-check
import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';
import starlightLinksValidator from 'starlight-links-validator';
import starlightLlmsTxt from 'starlight-llms-txt';

// https://astro.build/config
export default defineConfig({
	site: 'https://docs.remarc.app',
	trailingSlash: 'always',
	redirects: {
		// Old slugs from the pre-release IA restructure, kept harmless.
		'/exporting/copy-and-export/': '/basics/export-comments/',
		'/agents/webhooks/': '/automation/webhooks/',
		'/chrome-extension/setup-and-capture/': '/chrome-extension/',
	},
	integrations: [
		starlight({
			title: 'Remarc',
			description: 'Documentation for Remarc, the free open-source macOS menu bar app for contextual commenting, screenshots and export.',
			favicon: '/favicon.png',
			components: {
				// Header logo links to remarc.app; logos live in the override.
				SiteTitle: './src/components/SiteTitle.astro',
			},
			social: [{ icon: 'github', label: 'GitHub', href: 'https://github.com/metedata/Remarc' }],
			head: [
				{ tag: 'meta', attrs: { property: 'og:image', content: 'https://docs.remarc.app/og.png' } },
				{ tag: 'meta', attrs: { name: 'twitter:image', content: 'https://docs.remarc.app/og.png' } },
			],
			plugins: [
				starlightLinksValidator(),
				starlightLlmsTxt({
					projectName: 'Remarc',
					description:
						'Free open-source macOS menu bar app for contextual commenting, screenshots and export',
				}),
			],
			customCss: ['./src/styles/custom.css'],
			sidebar: [
				{
					label: 'Getting Started',
					items: [
						{ label: 'What is Remarc', slug: 'getting-started/what-is-remarc' },
						{ label: 'Install Remarc', slug: 'getting-started/installation' },
						{ label: 'Permissions', slug: 'getting-started/permissions' },
					],
				},
				{
					label: 'Basics',
					items: [
						{ label: 'Menu bar & popover', slug: 'basics/menu-bar-and-popover' },
						{ label: 'Comment on text selections', slug: 'basics/commenting-on-selections' },
						{ label: 'PopClip', slug: 'basics/popclip' },
						{ label: 'Quick notes', slug: 'basics/quick-notes' },
						{ label: 'Sessions & the Inbox', slug: 'basics/sessions' },
						{ label: 'Statuses & history', slug: 'basics/statuses-and-history' },
						{ label: 'Copy & export comments', slug: 'basics/export-comments' },
					],
				},
				{
					label: 'Screenshots',
					items: [
						{ label: 'Capture screenshot comments', slug: 'screenshots/capturing' },
						{ label: 'Annotate & redact', slug: 'screenshots/annotating-and-redacting' },
					],
				},
				{ label: 'Chrome extension', slug: 'chrome-extension' },
				{ label: 'Webhooks', slug: 'automation/webhooks' },
				{
					label: 'Reference',
					items: [
						{ label: 'Keyboard shortcuts', slug: 'reference/keyboard-shortcuts' },
						{ label: 'Settings', slug: 'reference/settings' },
						{ label: 'Troubleshooting & FAQ', slug: 'reference/troubleshooting' },
						{ label: 'Data, privacy & updates', slug: 'reference/data-and-privacy' },
					],
				},
			],
		}),
	],
});
