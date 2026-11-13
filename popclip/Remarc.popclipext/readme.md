# JotBaton

Add a JotBaton action to PopClip and turn selected text into a contextual comment for your coding agent.

## Requirements

- [JotBaton 1.2.0 or later](https://github.com/handsomeliuyang/JotBaton/releases/latest/download)
- macOS 14 or later

## Use

1. Install and launch JotBaton, then grant its requested Accessibility permission.
2. Select text in any app.
3. Click the JotBaton action in PopClip.
4. Write your comment and press Command-Return to save it.

JotBaton quotes the selection, records the source app, and keeps the comment locally until you choose to hand it to an agent or another integration.

## Avoid two selection popups

JotBaton has its own selection tooltip. To use only PopClip's action bar, open **JotBaton Settings > General** and set **Detection mode** to **Hotkey Only**.

## Privacy

The extension has no network entitlement and never transmits the selected text. It opens JotBaton on the same Mac using the `remarc://comment` URL, and JotBaton reads the selection locally through macOS Accessibility.

When invoked from a browser, the extension may also pass the current page URL to the local JotBaton app so the saved comment can retain its source. See [JotBaton's data and privacy guide](https://docs.remarc.app/reference/data-and-privacy/) for details.

## Help and source

- [PopClip setup guide](https://docs.remarc.app/basics/popclip/)
- [JotBaton documentation](https://docs.remarc.app/)
- [Source code and issues](https://github.com/handsomeliuyang/JotBaton)

JotBaton is created by Mete Polat at Metedata.

## Changelog

- 2026-08-21: Initial PopClip Extensions Directory release.
