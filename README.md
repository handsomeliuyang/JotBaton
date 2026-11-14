# JotBaton

An independently maintained macOS inbox for AI collaboration. Quickly capture a passing idea or product feedback, keep the relevant text, screenshot, or web context, and copy it to the AI tool you use. Mark the task complete when the work is done.

**随手记录想法与反馈，带着上下文交给 AI，做完就清掉。**

The everyday workflow is **capture → collect → copy to AI → mark complete**.
You can record a rough thought immediately and add detail before handing it off.
Codex, Claude Code, or another external AI tool does the work; you update the
status yourself. Completion and deletion remain separate actions.

Future MCP support may let an agent retrieve selected records and update their
statuses. That is a possible extension of the handoff, not a requirement for the
current copy-based workflow.

JotBaton develops independently from [metedata/Remarc](https://github.com/metedata/Remarc),
with its own product direction, releases, and update feed. Its name and independently
created baton icon distinguish it from the original project. See the
[positioning and compatibility notes](docs/brand-transition.md).

## How it works

### 1. Capture ideas and feedback

JotBaton runs from the menu bar, ready whenever an idea occurs or you spot something worth changing. Write a quick note or attach feedback to selected text, a screenshot, or a web element. The original context stays with your note so you can hand it to AI later without reconstructing what you saw.

#### Text comments

Select text in any app and attach a comment to that exact selection. JotBaton saves the quote and source app with your note. The [text comments guide](https://docs.remarc.app/basics/commenting-on-selections/) covers the tooltip, keyboard shortcut, and app exclusions.

#### Screenshot comments

Grab any region of the screen, adjust the selection, then add arrows, shapes, text, counters, blur, or pixelation. The screenshot stays attached to the comment, and you can reopen it to add or edit annotations. Read about [screenshot capture](https://docs.remarc.app/screenshots/capturing/) and [annotation and redaction](https://docs.remarc.app/screenshots/annotating-and-redacting/).

#### Web element comments

The [companion Chrome extension](https://remarc.app/chrome-extension/) captures the page URL, selected element or page region, CSS, layout, accessibility data, and React component details when available. The captured web context stays with the comment. Installation and capture shortcuts are in the [extension guide](https://docs.remarc.app/chrome-extension/).


#### Quick Notes

Open a [Quick Note](https://docs.remarc.app/basics/quick-notes/) when there is nothing to select or capture. It creates a standalone comment for a thought, task, or piece of feedback.

### 2. Collect and hand off tasks

Comments land in a session. Review them together, update their statuses, and copy or export the context when you are ready to share.

#### Sessions keep each review together

Group comments into [sessions](https://docs.remarc.app/basics/sessions/) by review, project, or agent conversation. The permanent Inbox catches anything you do not file elsewhere, and you can create sessions for each review.

#### Statuses close the loop

Each comment can move through Open, Handed Off, In-Progress, and Resolved. Update statuses as you work through your review. Deleted comments go to searchable [History](https://docs.remarc.app/basics/statuses-and-history/) instead of disappearing.

#### Copy or export the handoff

Copy a session into an agent prompt, paste it into the app you are using, or [export it as Markdown or JSON](https://docs.remarc.app/basics/export-comments/) with control over references and metadata. You can also send comment events to automation tools through [webhooks](https://docs.remarc.app/automation/webhooks/).

### 3. Complete the work and clear the active list

After your AI tool finishes the work, mark the corresponding records **Resolved**
and use status filters to focus on pending work. Delete a record when you want to
remove it; deleted records remain available in searchable **History**.

#### Local until you hand it off

Comments and screenshots stay on your Mac unless you turn on iCloud sync, hand them to an agent, or send them through a webhook you configured. There are no JotBaton accounts or telemetry. The [data and privacy guide](https://docs.remarc.app/reference/data-and-privacy/) explains what is stored and which features use the network.

#### Keep every Mac in sync through iCloud

In **Settings → iCloud Sync**, name each Mac (for example, Office Mac and Home Mac) and turn on **Sync automatically**. JotBaton uses `iCloud Drive/Remarc`; development uses the separate `iCloud Drive/Remarc Dev` folder.

Sync runs on its own: after local edits, when another Mac's changes arrive, when the main window opens, after waking, and every few minutes. Each Mac writes only its own file under `sync-v3/devices/`, and screenshots are uploaded once as content-addressed files under `sync-v3/blobs/`, so a sync transfers only what changed.

Changes merge task by task and field by field. Tasks added on different Macs never conflict, and edits to different fields of one task are both kept. When the same field changed on two Macs, the newer edit wins on every Mac and the other version is offered on that task. Deleting a task wins over a concurrent edit; the task stays restorable from History.

Every Mac keeps working offline and while iCloud is still downloading. Files macOS has removed from local storage are downloaded again automatically. If iCloud is unavailable, a download is stuck, or changes have not uploaded for a while, a banner in the main window and a badge on the menu bar icon say so. Before a merge changes local data, JotBaton saves a restore point, and **Undo Last Sync** returns to it.

Device permissions, shortcuts, credentials, selection and other device settings stay local. Production and development never share data. The retired manual snapshot files are removed from iCloud after the first automatic sync.

## Documentation

Use this README and [RELEASING.md](RELEASING.md) for this project's installation,
updates, and build instructions. Links to `remarc.app` and `docs.remarc.app` in
feature descriptions refer to the original project's documentation and downloads;
their behavior and release instructions may differ from this project's.

## Install

JotBaton production packages are published only by the manual Release workflow.
Legacy Remarc versions that validate the old GitHub repository path need one
manual upgrade to JotBaton. Existing data and signing identities are preserved.
Download filenames retain the `Remarc-` prefix for compatibility.

Download both packages from [this project's GitHub Releases](https://github.com/handsomeliuyang/JotBaton/releases/latest):

- `Remarc-Ventura-x86_64.zip`: Hackintosh / Intel, macOS 13+.
- `Remarc-Apple-Silicon-arm64.dmg`: Apple Silicon, macOS 14+.
- [Install the companion Chrome extension](https://remarc.app/chrome-extension/) for web context in Chrome and other Chromium browsers.

These builds use a fixed private signing certificate and are not Apple-notarized. Production checks this repository’s GitHub Releases. Click **Upgrade and Restart** to download, verify, install and relaunch automatically. Versions with browser-only downloads or the retired iCloud updater need one final manual upgrade to enable this flow.
See [installation and release instructions](RELEASING.md) for verified installation without local re-signing,
first launch, checksums and permissions. The upstream signed distribution is
available separately at [remarc.app/download](https://remarc.app/download).

## Build from source

Prerequisites: a supported build host with Xcode 26.2+ / Swift 6.2+. Local builds are Development only. Production packages are built, fully tested, signed and published by the manually dispatched GitHub Release workflow. Ventura with Xcode 14 is an installation/runtime test host.

To build the current checkout and immediately launch its Debug app, without a commit or GitHub build:

```bash
./scripts/run-local.sh
```

With supported Xcode selected, the script clean-builds and signs `JotBaton Dev.app` with the shared test identity, installs it at `/Applications/JotBaton Dev.app`, and relaunches it. It preserves the production app. The DEV app icon and floating-window badges, Bundle ID, local data (`Application Support/Remarc Dev`), settings, and iCloud folder (`iCloud Drive/Remarc Dev`) are independent. Each Mac grants permissions to each app once. On Ventura with Xcode 14, download the Intel production package from GitHub Releases; previews never fall back to GitHub automatically.

On a Mac with only Command Line Tools and the macOS 26.5 SDK, the script also supports a local preview: it compiles the actual application sources using SwiftPM, expands the shortcut dependency's SwiftUI environment entry in an isolated copy under DerivedData, and omits Xcode canvas previews. Installed visual assets are reused if available; the app and menu bar icons always use the separate development assets. This preview uses its local SwiftPM resource bundles; keep the worktree/build directory while running it. Full Xcode remains the supported path for release builds and the complete XCTest suite.

Run `./scripts/test-cloud-sync.sh` for the iCloud sync suite. With CLT, run the local preview script first; the test script uses the same production sources and pinned dependencies in a separate Swift Testing target without the unavailable XCTest runtime.

For a direct Xcode build:

```bash
git clone https://github.com/handsomeliuyang/JotBaton.git
cd JotBaton
# On an Apple Silicon build host:
REMARC_BUILD_CONFIGURATION=Debug bash scripts/build-apple-silicon.sh
# On a compatible Intel build host:
REMARC_BUILD_CONFIGURATION=Debug bash scripts/build-ventura.sh
```

Local `dev-preview.sh` skips full tests by default; add `--with-tests` when needed. Local Release builds/signing are disabled. The [Release workflow](.github/workflows/release.yml) builds both production packages, runs full regression tests and publishes to GitHub when explicitly dispatched. See [RELEASING.md](RELEASING.md) for publication and installation.

## Ventura / Intel compatibility build

This project's `main` branch is the maintained version, including macOS 13 support
and local UI customizations. Use `main` for development and builds. Any retained
compatibility branches are historical; development and releases do not depend on
merging changes into the original project.

An opt-in build supports **macOS 13.0+ / x86_64**,
including Ventura 13.7.8. The standard build keeps the upstream macOS 14 minimum.
Comments, sessions, selection monitoring, screenshots, annotations and exports
share the same implementation and data format.
The app checks GitHub Releases for updates. **Upgrade and Restart** selects the native Intel package and completes download, verification, installation and relaunch. Background installation without user consent remains disabled.

For versioned delivery, use the **Release** workflow to build both Intel and
Apple Silicon packages from the same commit with Xcode 26.2. Download
`Remarc-Ventura-x86_64.zip` from [this project's Releases](https://github.com/handsomeliuyang/JotBaton/releases)
and extract it with Archive Utility or `ditto` to preserve the app bundle. No Developer ID
certificate or notarization is needed for personal use. Both production packages
are already signed with the same fixed private certificate from Actions Secrets.
Install directly without local re-signing. From a source checkout:

```bash
python3 scripts/install-app.py /absolute/path/JotBaton.app --channel production
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
`app/DerivedData/Build/Products/Debug/JotBaton Dev.app`.

Ventura itself cannot run Xcode 26.2; it is the runtime test machine, while the
cloud runner is the compiler host. On Ventura, verify first launch and permissions,
selection-to-comment, session rename/cancel, search-field arrow keys, toast/undo,
screenshot annotation (including blur/pixelation), export and restart persistence.

## Apple Silicon build

The **Release** workflow builds and publishes a native arm64 Release app together
with the Intel app. The standalone **Apple Silicon** workflow is for development
and produces an Actions artifact only. The standard macOS 14 minimum is preserved.
Automatic upstream updates are disabled for this independently packaged build.

Download `Remarc-Apple-Silicon-arm64.dmg` from
[this project's Releases](https://github.com/handsomeliuyang/JotBaton/releases).
Drag `JotBaton.app` into Applications. This works on Apple Silicon Macs, including
Apple Silicon, without Rosetta. The app uses the fixed private release certificate and is not Apple-notarized; if the
first launch is blocked, use **System Settings → Privacy & Security → Open Anyway**
as described in [Apple's instructions](https://support.apple.com/en-us/102445).
The artifact includes installation instructions, the source commit and SHA-256.
See [RELEASING.md](RELEASING.md) for the dual-architecture release and installation process.

On an Apple Silicon Mac with Xcode 26.2, run
`REMARC_BUILD_CONFIGURATION=Debug bash scripts/build-apple-silicon.sh` to clean-build, sign, relaunch and verify
`app/DerivedData/Build/Products/Debug/JotBaton Dev.app`. Production signing runs only in Actions.

## Repository layout

| Path | Contents |
|------|----------|
| `app/` | The macOS app (SwiftUI + AppKit, Swift 6) |
| `extension/` | Chrome extension for web page context |
| `website/` | remarc.app site and launch router (Cloudflare Workers + static assets) |
| `docs-site/` | docs.remarc.app end-user documentation (Astro Starlight) |
| `docs/` | Design docs and historical planning notes |

## Tech stack

Swift 6, SwiftUI + AppKit, [Sparkle](https://github.com/sparkle-project/Sparkle) for updates, [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts).

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Bug reports and pull requests are welcome.

## Support

For this independently maintained project, use
[this repository](https://github.com/handsomeliuyang/JotBaton).
The source remains available under the MIT License.

## Security

To report a vulnerability, please see [SECURITY.md](SECURITY.md). Do not open a public issue for security problems.

## License

JotBaton is released under the [MIT License](LICENSE).

The original Remarc name, logo, and app icon belong to Metedata LLC. JotBaton uses its own name and independently drawn artwork. Original code copyright and license notices are preserved; third-party software notices are listed in [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).
