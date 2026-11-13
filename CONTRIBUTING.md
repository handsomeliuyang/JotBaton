# Contributing to Remarc

Thanks for your interest in improving Remarc.

## Prerequisites

- Xcode 26.2 / Swift 6.2 on a supported development Mac (or the documented CLT preview SDK).
- Runtime: macOS 14+ on Apple Silicon; the opt-in Intel build supports macOS 13+.
- Ventura with Xcode 14 cannot compile the package. Download the Intel package from GitHub Releases; there is no automatic GitHub fallback.

## Build and run

```bash
git clone https://github.com/handsomeliuyang/Remarc.git
cd Remarc
bash scripts/dev-preview.sh
```

This builds the current Mac's development package locally when its toolchain is
supported, signs it with the shared test identity, and installs/relaunches
`Remarc Dev.app`. Unsupported hosts receive an error instead of dispatching cloud
compilation. Local builds are Dev only and skip full tests by default; add
`--with-tests` explicitly when needed. Production uses the manually dispatched
GitHub Release workflow with full tests and both native packages; see
[RELEASING.md](RELEASING.md).

Development has a DEV app icon and distinct menu icon, Bundle ID
`com.metepolat.Remarc.dev`, local data in `Application Support/Remarc Dev`, and
snapshots in `iCloud Drive/Remarc Dev`. It can coexist with production `Remarc`.
Their settings, permissions, callbacks, sockets and integration registrations are
separate. See [RELEASING.md](RELEASING.md) for the full channel contract.

Debug builds log to `/tmp/remarc_dev_debug.log`. Production Release logging is off
unless enabled with `defaults write com.metepolat.Remarc debugFileLoggingEnabled -bool YES`;
then it uses `~/Library/Logs/Remarc/remarc_debug.log` and one previous `.old` log.

Grant Accessibility and Screen Recording to **Remarc Dev** on first use on each
Mac. Reuse the same identity on subsequent builds; do not fall back to ad-hoc signing.

## Project structure

| Path | Contents |
|------|----------|
| `app/Remarc/` | App target: entry point, Info.plist, entitlements |
| `app/RemarcPackage/Sources/App/` | Lifecycle, routing, menu bar and dependency wiring |
| `app/RemarcPackage/Sources/Features/` | Code grouped by business feature |
| `app/RemarcPackage/Sources/Core/` | Platform, localization, theme and reusable UI |
| `app/RemarcPackage/Tests/RemarcFeatureTests/` | Swift tests grouped by capability |
| `app/Config/Shared.xcconfig` | Version numbers and deployment target |
| `mcp/vendor/` | Vendored MCP server artifact (built in [remarc-agent-plugins](https://github.com/metedata/remarc-agent-plugins); do not edit by hand - the build verifies its sha256) |
| `extension/` | Chrome extension |
| `tests/` | Test suite |

See [ARCHITECTURE.md](ARCHITECTURE.md) for target ownership, dependency rules and
the relationship between feature implementations and application UI workflows.

## Code style

- Swift 6 with strict concurrency; keep new code `@MainActor`-correct rather than sprinkling `@unchecked Sendable`.
- Colors come from the token system in `app/RemarcPackage/Sources/Core/Theme/Colors.swift` (`remarcPrimary`, `remarcAccent`, ...). Never hardcode hex values in views; every token adapts to light and dark mode.
- Tooltips use SwiftUI's `.help()` modifier, matching the rest of the app.
- No em dashes in user-facing strings (UI copy, release notes); use hyphens.

## Pull requests

Before opening a PR:

1. The app builds without warnings introduced by your change.
2. You launched the Debug build and exercised the affected flow.
3. UI changes include a screenshot or short recording.
4. Keep PRs focused; unrelated cleanups belong in their own PR.

Manually invoked development workflows use the shared test fixture. Push/PR events do not compile on GitHub; run relevant checks locally before delivery.

## Reporting bugs

Use the bug report issue template. Attaching the tail of the debug log helps a lot; the template explains how to enable logging on a release build (it is off by default). Development Debug builds log to `/tmp/remarc_dev_debug.log`. Scrub anything you consider private first.
