# Remarc

Remarc is the feedback layer between you and your coding agent. Point at anything on your Mac: text, a screenshot, or a web element. Talk through a review or jot down a quick note. Remarc keeps the relevant context with each comment so your agent can take it from there.

https://github.com/user-attachments/assets/4393066b-1a22-484c-8703-c55ebef7edbb

## How it works

### 1. Comment on anything

Remarc runs from the menu bar, ready whenever you spot something worth changing. Comment on selected text, screenshots, web elements, or speak your feedback. Remarc keeps the original selection, screenshot, web context, or recording with your note, so your agent works from what you saw instead of a paraphrase.

#### Text comments

Select text in any app and attach a comment to that exact selection. Remarc saves the quote and source app with your note. The [text comments guide](https://docs.remarc.app/basics/commenting-on-selections/) covers the tooltip, keyboard shortcut, and app exclusions.

#### Screenshot comments

Grab any region of the screen, adjust the selection, then add arrows, shapes, text, counters, blur, or pixelation. The screenshot stays attached to the comment, and you can reopen it to add or edit annotations. Read about [screenshot capture](https://docs.remarc.app/screenshots/capturing/) and [annotation and redaction](https://docs.remarc.app/screenshots/annotating-and-redacting/).

#### Web element comments

The [companion Chrome extension](https://remarc.app/chrome-extension/) captures the page URL, selected element or page region, CSS, layout, accessibility data, and React component details when available. The captured web context stays with the comment. Installation and capture shortcuts are in the [extension guide](https://docs.remarc.app/chrome-extension/).

#### Voice comments and Crit Mode

On macOS 26 or later, dictate one comment or record a longer review in [Crit Mode](https://docs.remarc.app/voice/voice-comments-and-crit-mode/). Crit Mode transcribes the recording and splits it into separate comment cards. Apple Speech, WhisperKit, and Parakeet all run transcription on your Mac.

#### Quick Notes

Open a [Quick Note](https://docs.remarc.app/basics/quick-notes/) when there is nothing to select or capture. It creates a standalone comment for a thought, task, or piece of feedback.

### 2. Your agent picks up the comments

Comments land in a session. Once you connect an agent, it can read each one with the attached context and work through the list. You do not have to rebuild that context in a separate prompt.

#### Sessions keep each review together

Group comments into [sessions](https://docs.remarc.app/basics/sessions/) by review, project, or agent conversation. The permanent Inbox catches anything you do not file elsewhere, and connected agents can create sessions for their own conversations.

#### MCP and plugins carry the context

Claude Code, Codex, and OMP connect through plugins from the public [Remarc agent integrations repository](https://github.com/metedata/remarc-agent-plugins), Cursor is configured by the app, and Claude Desktop or another MCP client can connect manually. Every supported client gets the same context and MCP tools for reading comments, managing sessions, and resolving work. The [agent integrations guide](https://docs.remarc.app/agents/overview/) covers each setup path.

#### Statuses close the loop

Each comment can move through Open, Handed Off, In-Progress, and Resolved. Agents can update the status as they work and leave a resolution summary when they finish. Deleted comments go to searchable [History](https://docs.remarc.app/basics/statuses-and-history/) instead of disappearing.

#### Copy, export, or automate the handoff

Copy a session into an agent prompt, paste it into the app you are using, or [export it as Markdown or JSON](https://docs.remarc.app/basics/export-comments/) with control over references and metadata. You can also send comment events to automation tools through [webhooks](https://docs.remarc.app/agents/webhooks/).

#### Local until you hand it off

Comments and screenshots stay on your Mac unless you publish an iCloud snapshot, hand them to an agent, or send them through a webhook you configured. There are no Remarc accounts or telemetry. The [data and privacy guide](https://docs.remarc.app/reference/data-and-privacy/) explains what is stored and which features use the network.

#### Switch Macs with one current iCloud copy

In **Settings → iCloud Sync**, name each Mac (for example, Office Mac and Home Mac) and enable **iCloud Data**. Remarc uses `iCloud Drive/Remarc`; development uses the separate `iCloud Drive/Remarc Dev` folder. Publishing and applying remain manual.

The cloud toolbar opens the current cloud source, publication time, **Publish**, **Apply**, and **Roll Back**. Publish reads the current local data and generates a temporary package. The payload has a readable filename such as `2026-11-11_18-45-32+0800_Office-Mac_1FD1CBD4.zip`; `current.json` identifies the selected payload. A new payload must finish uploading before the current marker is switched. Both files must confirm upload before the previous payload and obsolete UUID-named history are cleaned up. A concurrent publication is rechecked before switching the marker.

There is no persistent publication outbox or cloud version-history list. A failed publish keeps the existing cloud payload; clicking Publish again reads the latest local data and prepares a fresh package. Upload confirmation metadata survives restarts without retaining a local publication package. Checks never apply cloud data automatically.

Applying verifies the complete cloud package, including comments, sessions, deleted records, screenshots, attachments and editable image annotations. Before replacing local data, Remarc saves one complete local undo package. The replacement and its undo reference are committed together. A failed application keeps the previous undo copy; a successful application replaces it. **Roll Back** restores the complete pre-application data on this Mac, replacing edits made since the application. Undo survives restarts, is consumed after a successful rollback, and does not publish changes to iCloud.

Device permissions, shortcuts, credentials, and live agent connections stay local. Production and development never share data or rollback files. iCloud access is restricted to the matching channel's folder; an authorization action is offered when needed. The current-data format replaces the old version-history protocol. Old cloud snapshots and local outbox/backup folders are cleaned up only after the first new current copy has confirmed upload.

## Documentation

Read the [full Remarc documentation](https://docs.remarc.app/getting-started/what-is-remarc/) for setup and feature guides. Useful starting points include [installation](https://docs.remarc.app/getting-started/installation/), [permissions](https://docs.remarc.app/getting-started/permissions/), [agent integrations](https://docs.remarc.app/agents/overview/), [keyboard shortcuts](https://docs.remarc.app/reference/keyboard-shortcuts/), and [troubleshooting](https://docs.remarc.app/reference/troubleshooting/).

## Install

Download both packages from [this fork's GitHub Releases](https://github.com/handsomeliuyang/Remarc/releases/latest):

- `Remarc-Ventura-x86_64.zip`: Hackintosh / Intel, macOS 13+.
- `Remarc-Apple-Silicon-arm64.dmg`: Apple Silicon, macOS 14+.
- [Install the companion Chrome extension](https://remarc.app/chrome-extension/) for web context in Chrome and other Chromium browsers.

These fork builds use a fixed private signing certificate and are not Apple-notarized. Production checks this repository’s GitHub Releases. Click **Upgrade and Restart** to download, verify, install and relaunch automatically. Versions with browser-only downloads or the retired iCloud updater need one final manual upgrade to enable this flow. iCloud data snapshot synchronization remains supported.
See [installation and release instructions](RELEASING.md) for verified installation without local re-signing,
first launch, checksums and permissions. The upstream signed distribution is
available separately at [remarc.app/download](https://remarc.app/download).

## Build from source

Prerequisites: a supported build host with Xcode 26.2+ / Swift 6.2+. Local builds are Development only. Production packages are built, fully tested, signed and published by the manually dispatched GitHub Release workflow. Ventura with Xcode 14 is an installation/runtime test host.

To build the current checkout and immediately launch its Debug app, without a commit or GitHub build:

```bash
./scripts/run-local.sh
```

With supported Xcode selected, the script clean-builds and signs `Remarc Dev.app` with the shared test identity, installs it at `/Applications/Remarc Dev.app`, and relaunches it. It preserves the production app. The DEV app icon and floating-window badges, Bundle ID, local data (`Application Support/Remarc Dev`), settings, and iCloud folder (`iCloud Drive/Remarc Dev`) are independent. Each Mac grants permissions to each app once. On Ventura with Xcode 14, download the Intel production package from GitHub Releases; previews never fall back to GitHub automatically.

On a Mac with only Command Line Tools and the macOS 26.5 SDK, the script also supports a local preview: it compiles the actual application sources using SwiftPM, expands the shortcut dependency's SwiftUI environment entry in an isolated copy under DerivedData, and omits Xcode canvas previews. Voice segmentation uses the existing speech-segment fallback because CLT lacks the Foundation Models macro plugin. Installed visual assets are reused if available; the app and menu bar icons always use the separate development assets. This preview uses its local SwiftPM resource bundles; keep the worktree/build directory while running it. Full Xcode remains the supported path for release builds and the complete XCTest suite.

Run `./scripts/test-snapshots.sh` for the snapshot suite. With CLT, run the local preview script first; the test script uses the same production sources and pinned dependencies in a separate Swift Testing target without the unavailable XCTest runtime.

For a direct Xcode build:

```bash
git clone https://github.com/handsomeliuyang/Remarc.git
cd Remarc
# On an Apple Silicon build host:
REMARC_BUILD_CONFIGURATION=Debug bash scripts/build-apple-silicon.sh
# On a compatible Intel build host:
REMARC_BUILD_CONFIGURATION=Debug bash scripts/build-ventura.sh
```

Local `dev-preview.sh` skips full tests by default; add `--with-tests` when needed. Local Release builds/signing are disabled. The [Release workflow](.github/workflows/release.yml) builds both production packages, runs full regression tests and publishes to GitHub when explicitly dispatched. See [RELEASING.md](RELEASING.md) for publication and installation.

## Ventura / Intel compatibility build

This fork's `main` branch is the maintained version, including macOS 13 support
and local UI customizations. Use `main` for development and builds. The
`compat/macos13` branch is retained for the upstream compatibility PR.

An opt-in build supports **macOS 13.0+ / x86_64**,
including Ventura 13.7.8. The standard build keeps the upstream macOS 14 minimum.
Comments, sessions, selection monitoring, screenshots, annotations and exports
share the same implementation and data format. Voice features still require
macOS 26; FluidAudio/Parakeet is omitted from the compatibility build. Official
The app checks GitHub Releases for updates. **Upgrade and Restart** selects the native Intel package and completes download, verification, installation and relaunch. Background installation without user consent remains disabled.

For versioned delivery, use the **Release** workflow to build both Intel and
Apple Silicon packages from the same commit with Xcode 26.2. Download
`Remarc-Ventura-x86_64.zip` from [this fork's Releases](https://github.com/handsomeliuyang/Remarc/releases)
and extract it with Archive Utility or `ditto` to preserve the app bundle. No Developer ID
certificate or notarization is needed for personal use. Both production packages
are already signed with the same fixed private certificate from Actions Secrets.
Install directly without local re-signing. From a source checkout:

```bash
python3 scripts/install-app.py /absolute/path/Remarc.app --channel production
```

The installer verifies signature and architecture, preserves a rollback backup and
user data, installs and relaunches. The first migration to the new signing identity
requires granting Accessibility and Screen Recording again on each Mac.

To build on a Mac that can run Xcode 26.2:

```bash
bash scripts/build-ventura.sh
```

The script selects `REMARC_VENTURA=1` and `Config/Ventura.xcconfig`, performs a
clean Debug build by default (set `REMARC_BUILD_CONFIGURATION=Release` for Release),
relaunches the app, and verifies all bundled Mach-O images
have an Intel slice and support macOS 13.0 or earlier. It retains the upstream
pinned dependency revisions and fails if resolution changes them. Output:
`app/DerivedData/Build/Products/Debug/Remarc Dev.app`.

Ventura itself cannot run Xcode 26.2; it is the runtime test machine, while the
cloud runner is the compiler host. On Ventura, verify first launch and permissions,
selection-to-comment, session rename/cancel, search-field arrow keys, toast/undo,
screenshot annotation (including blur/pixelation), export and restart persistence.

## Apple Silicon fork build

The **Release** workflow builds and publishes a native arm64 Release app together
with the Intel app. The standalone **Apple Silicon** workflow is for development
and produces an Actions artifact only. The standard macOS 14 minimum
and full speech backends are preserved (voice features require macOS 26).
Automatic upstream updates are disabled for this independently packaged build.

Download `Remarc-Apple-Silicon-arm64.dmg` from
[this fork's Releases](https://github.com/handsomeliuyang/Remarc/releases).
Drag `Remarc.app` into Applications. This works on Apple Silicon Macs, including
Apple Silicon, without Rosetta. The app uses the fixed private release certificate and is not Apple-notarized; if the
first launch is blocked, use **System Settings → Privacy & Security → Open Anyway**
as described in [Apple's instructions](https://support.apple.com/en-us/102445).
The artifact includes installation instructions, the source commit and SHA-256.
See [RELEASING.md](RELEASING.md) for the dual-architecture release and installation process.

On an Apple Silicon Mac with Xcode 26.2, run
`REMARC_BUILD_CONFIGURATION=Debug bash scripts/build-apple-silicon.sh` to clean-build, sign, relaunch and verify
`app/DerivedData/Build/Products/Debug/Remarc Dev.app`. Production signing runs only in Actions.

## Repository layout

| Path | Contents |
|------|----------|
| `app/` | The macOS app (SwiftUI + AppKit, Swift 6) |
| `mcp/` | Vendored MCP server artifact + agent skill, bundled into the app |
| `extension/` | Chrome extension for web page context |
| `website/` | remarc.app site and launch router (Cloudflare Workers + static assets) |
| `docs-site/` | docs.remarc.app end-user documentation (Astro Starlight) |
| `docs/` | Design docs and historical planning notes |

The MCP server's source of truth lives in the public, MIT-licensed [remarc-agent-plugins](https://github.com/metedata/remarc-agent-plugins) repository, which also hosts the Claude Code, Codex, and OMP integrations plus their compatibility and release documentation. This repo vendors the built artifact.

## Tech stack

Swift 6, SwiftUI + AppKit, [Sparkle](https://github.com/sparkle-project/Sparkle) for updates, [WhisperKit](https://github.com/argmaxinc/WhisperKit) and [FluidAudio](https://github.com/FluidInference/FluidAudio) for on-device transcription, [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts), and the Model Context Protocol for agent integrations.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Bug reports and pull requests are welcome.

## Support

If Remarc is useful to you, you can [Buy Me a Coffee](https://buymeacoffee.com/metedata) to support its continued development. Remarc remains free and open source.

## Security

To report a vulnerability, please see [SECURITY.md](SECURITY.md). Do not open a public issue for security problems.

## License

Remarc is released under the [MIT License](LICENSE).

The Remarc name, logo, and app icon belong to Metedata LLC and are not covered by the MIT license. Third-party software notices are listed in [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md). If you distribute a fork, ship it under a different name and icon.
