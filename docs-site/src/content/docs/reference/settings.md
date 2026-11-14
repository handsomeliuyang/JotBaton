---
title: Settings
description: A tab-by-tab reference of every Remarc setting, with the default value and available options for each one.
---

This page lists every Remarc setting with its default, tab by tab. Open Settings from the gear button in the popover footer, or right-click the menu bar icon and choose "Preferences...".

## General

### App

These settings control startup, selection detection, and how dates appear on comment cards.

| Setting | Default | Notes |
| --- | --- | --- |
| Launch at Login | On after onboarding | Remarc registers itself as a login item when onboarding completes. |
| Show in Dock | Off | When off, the Dock icon appears only while the Settings or Permissions windows are open. |
| Menu bar indicator | Count | What appears with the menu bar icon. See [Menu bar indicator](#menu-bar-indicator) below. |
| Detection mode | Auto-detect + Hotkey | "Hotkey Only" hides the selection popup and waits for `Ctrl+Option+C`; Remarc keeps detecting selections in the background. The composer can also open from the [PopClip](/basics/popclip/) bar if installed. |
| Tooltip position | Above selection | Or "Below selection". |
| Date format | Short (e.g. "Aug 8") | Five styles, shown as sample dates in the picker. |
| Time format | 12-hour | Or 24-hour. |

#### Menu bar indicator

The menu bar icon keeps the same width whatever it shows, so Remarc never shifts other menu bar items or slips into a menu bar manager's hidden section when comments arrive. Resolving a comment removes it from the indicator without deleting it.

| Option | What you see |
| --- | --- |
| Count | The number of unresolved comments beside the icon, in the same monochrome style as other menu bar items. Nothing at zero; above 99 it shows `99+`. |
| Dot | A small dot on the icon's corner when at least one unresolved comment exists. |
| Off | The icon only. |

A new comment makes the indicator pop once; with **Reduce motion** turned on in System Settings it simply appears. In every option, an orange mark on the icon's corner means iCloud sync needs attention; open Remarc to see what to do.

### Clipboard

Two settings shape what ends up on the clipboard.

| Setting | Default | Notes |
| --- | --- | --- |
| Clean up whitespace | On | Normalizes whitespace in the quoted selection text. |
| Add screenshots to clipboard | Off | Also copies the captured image when you save a screenshot comment. |

### Screenshots

| Setting | Default | Notes |
| --- | --- | --- |
| Storage folder | `~/Library/Application Support/Remarc/images` | Choose a folder for new screenshots and pasted image attachments. Use Default restores Application Support for new images. |

Choose a folder that Remarc can write to and your agent can access. Existing images stay editable in their original locations; choosing another folder or Use Default does not migrate them. Keep those folders available for previewing and editing older images.

If the selected folder becomes unavailable or a write fails, Remarc does not silently fall back to Application Support. Reconnect the folder or choose another location before saving again. History retention also covers associated Remarc images and their annotation sidecars in current and previous folders.

### Retention

History retention covers archived comments and their images and attachments. Its period starts when a comment moves to History. Expired records and their image families are removed on the next cleanup, except images still referenced by another retained comment. Exported local image references can stop working after cleanup; save a separate copy if you need it longer. Failed image deletions stay queued for retry.

| Setting | Default | Notes |
| --- | --- | --- |
| History retention | 1 day | Options: 1 day, 1 week, 1 month. Comments, screenshots, attachments, and annotation files share this period. Active comments and their images are kept. |
| Delete resolved | Never | Options: Never, Immediately, After 15 min, After 1 hour, After 1 day. |
| Auto-delete inactive sessions | Off | When on, a "Delete after" picker appears: After 30 min through After 24 hours, default After 4 hours. The Inbox, the current session, and sessions with unresolved comments are never deleted. |

## Shortcuts

Rebind global shortcuts here; Remarc flags conflicts between its own shortcuts as you record them, and a Reset button restores the defaults. The Chrome extension shortcuts also appear here. Full list: [keyboard shortcuts](/reference/keyboard-shortcuts/).

## Export

Export settings control how Copy All and file exports format your comments, with a live preview on the right; hover a control to highlight what it changes. See [copy and export](/basics/export-comments/) for how the output is used.

| Setting | Default | Notes |
| --- | --- | --- |
| Reference prefix | Blockquote | Options: Blockquote, Re: Prefix, Quoted. |
| Comment prefix | Comment: | Options: Comment:, Note:, Dash, Arrow, None. |
| List style | Numbered | Options: Numbered, Bulleted, None. |
| Comment dividers | Blank Line | Options: Rule, Double, Dotted, Blank Line. |
| Metadata divider | Pipe | Options: Pipe, Dash, Dot, Comma. |
| Include: Type | On | |
| Include: Source app | On | |
| Include: Date | On | |
| Include: Include time | Off | Enabled only when Date is on. |
| Include: Status | Off | |
| Include: Comment ID | On | Short IDs identify comments when sharing feedback. |
| After copying | Always Ask | Options: Always Ask, Always Keep, Always Delete. |
| File export format | Markdown | Or JSON. |

## Chrome Extension

This tab manages the [Chrome extension](/chrome-extension/)'s connection and capture behavior:

- **Connection**: live status with the port number (9274). If another app holds the port, a Retry button appears.
- **Chrome Shortcuts**: Grab Element (`Option+Shift+G`) and Select Region (`Option+Shift+R`), with a Reset to Defaults button.
- **Captured Metadata**: five toggles, all on by default, disabled until the extension has connected once: React components, Computed styles, Accessibility, Layout & structure, Element identity.

## Webhooks

This tab holds the [webhooks](/automation/webhooks/) that send comment events as HTTP POST requests to any endpoint. Each webhook has a name, URL, event checkboxes, an optional signing secret, an optional custom payload template, a test button, and an enable toggle.

## Excluded Apps

Remarc never shows the Comment tooltip in the apps listed here. Add apps with the + button (an open panel starting in /Applications), remove them with -. The list is empty by default.

## About

The About tab shows the app version and build number, the total count of remarks you have created, a "Check for Updates..." button, and links to the Website, Documentation, and GitHub.
