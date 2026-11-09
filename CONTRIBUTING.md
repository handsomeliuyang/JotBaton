# Contributing to Remarc

Thanks for your interest in improving Remarc.

## Prerequisites

- Xcode 26.2 / Swift 6.2 on a supported development Mac (or the documented CLT preview SDK).
- Runtime: macOS 14+ on Apple Silicon; the opt-in Intel build supports macOS 13+.
- Ventura with Xcode 14 uses the cloud **Development** workflow artifacts.

## Build and run

```bash
git clone https://github.com/handsomeliuyang/Remarc.git
cd Remarc
bash scripts/run-local.sh
```

This clean-builds, signs, installs and relaunches `Remarc Dev.app`. Both development
Macs reuse the committed test certificate and password in `signing/`; no Apple
Developer account or per-machine certificate generation is needed. Production
certificate/private key and password are exclusively in Actions Secrets.

Development has a DEV app icon and distinct menu icon, Bundle ID
`com.metepolat.Remarc.dev`, local data in `Application Support/Remarc Dev`, and
snapshots in `iCloud Drive/Remarc Dev`. It can coexist with production `Remarc`.
Their settings, permissions, callbacks, sockets and integration registrations are
separate. See [RELEASING.md](RELEASING.md) for the full channel contract.

Debug builds log to `/tmp/remarc_dev_debug.log`. Production Release logging is off
unless enabled with `defaults write com.metepolat.Remarc debugFileLoggingEnabled -bool YES`;
then it uses `~/Library/Logs/Remarc/remarc_debug.log` and one previous `.old` log.

Grant Accessibility and Screen Recording to **Remarc Dev** on first use on each
Mac. Voice features additionally require their microphone permissions and macOS
26. Reuse the same identity on subsequent builds; do not fall back to ad-hoc signing.

## Project structure

| Path | Contents |
|------|----------|
| `app/Remarc/` | App target: entry point, Info.plist, entitlements |
| `app/RemarcPackage/Sources/RemarcFeature/` | Nearly all app code (services, views, models) |
| `app/Config/Shared.xcconfig` | Version numbers and deployment target |
| `mcp/vendor/` | Vendored MCP server artifact (built in [remarc-agent-plugins](https://github.com/metedata/remarc-agent-plugins); do not edit by hand - the build verifies its sha256) |
| `extension/` | Chrome extension |
| `tests/` | Test suite |

## Code style

- Swift 6 with strict concurrency; keep new code `@MainActor`-correct rather than sprinkling `@unchecked Sendable`.
- Colors come from the token system in `app/RemarcPackage/Sources/RemarcFeature/Views/Colors.swift` (`remarcPrimary`, `remarcAccent`, ...). Never hardcode hex values in views; every token adapts to light and dark mode.
- Tooltips use SwiftUI's `.help()` modifier, matching the rest of the app.
- No em dashes in user-facing strings (UI copy, release notes); use hyphens.

## Pull requests

Before opening a PR:

1. The app builds without warnings introduced by your change.
2. You launched the Debug build and exercised the affected flow.
3. UI changes include a screenshot or short recording.
4. Keep PRs focused; unrelated cleanups belong in their own PR.

CI signs development builds with the shared test fixture. Production Secrets are not required for PR builds; all checks must pass.

## Reporting bugs

Use the bug report issue template. Attaching the tail of the debug log helps a lot; the template explains how to enable logging on a release build (it is off by default). Development Debug builds log to `/tmp/remarc_dev_debug.log`. Scrub anything you consider private first.
