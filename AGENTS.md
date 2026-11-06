# Remarc

macOS menu bar app (SwiftUI + AppKit) for contextual commenting on text selections.

- Bundle ID: `com.metepolat.Remarc`
- Min macOS: standard build 14.0 (`app/Config/Shared.xcconfig`); opt-in Ventura build 13.0 (`app/Config/Ventura.xcconfig` with `REMARC_VENTURA=1`). Xcode 26.2 / Swift 6.2 is required by the locked dependencies. LSUIElement (no dock icon)
- Delivery build: use the **Release** GitHub Actions workflow in `handsomeliuyang/Remarc`; build both Ventura Intel and Apple Silicon from the same version commit (see `RELEASING.md`).
- Debug log: `/tmp/remarc_debug.log` (Debug builds only; release builds write no log file unless `defaults write com.metepolat.Remarc debugFileLoggingEnabled -bool YES`)
- Data: `~/Library/Application Support/Remarc/comments.json` (legacy fallback: `data.json`)

**MANDATORY: After every successful build, you MUST relaunch Remarc.** The user cannot verify changes otherwise. Do this every single time, no exceptions:
1. Build with `-derivedDataPath "$(pwd)/DerivedData"` (deterministic output path — no grep/find needed). Both build scripts relaunch their exact output on the matching CI host.
2. For local delivery on this Ventura Intel machine, download the exact release's Intel package, verify it, re-sign with `scripts/sign-ventura-local.sh`, install at `/Applications/Remarc.app`, and relaunch that installed app. Do not launch a stale Debug build or the arm64 package here.

## Build

When working on UI changes in SwiftUI, always do a clean build after layout changes to avoid stale build cache issues. Use `xcodebuild clean` or delete DerivedData when builds behave unexpectedly.

### Required Delivery and Release Process

- Every requested deliverable build must produce **both** packages: **Hackintosh / Ventura Intel (`x86_64`, macOS 13+)** and **M5 Pro / Apple Silicon (`arm64`, macOS 14+)**. Do not stop after building only the local machine's architecture.
- Use `.github/workflows/release.yml` for versioned delivery. It builds both packages in **Release** configuration from one exact commit, runs both Swift test profiles plus Intel compatibility and packaged MCP checks, and publishes both assets with SHA-256 checksums to the same GitHub Release in `handsomeliuyang/Remarc`.
- Increment marketing version and build number for a new release. The workflow owns the version commit and annotated tag; never move an existing tag or overwrite published assets. See `RELEASING.md` for retries.
- Actions artifacts are intermediate build output, not a completed GitHub Release. Verify the published Release assets and include its URL in the delivery response.
- Standalone **Ventura Intel** / **Apple Silicon** workflows remain available for development and troubleshooting; they do not publish a Release.
- Packages use ad-hoc signing unless this fork configures its own Developer ID and notarization credentials. Do not claim Apple notarization or use the upstream author's signing, appcast, website or release credentials. Fork packages use manual updates.
- After publishing, update and relaunch the local Intel installation using the existing local signing identity, preserve user data, and keep a rollback backup. Verify the arm64 package on its matching CI host and download it for transfer to the M5 Pro; do not claim physical M5 Pro testing unless performed.

### Worktree Builds

When building from worktrees, always verify the correct DerivedData path and binary location before launching. Use absolute paths instead of $PWD in build commands.

## UI Work

When the user describes a UI bug, confirm WHICH specific component/view they mean before editing. Ask clarifying questions if the target is ambiguous (e.g., 'comment cards' vs 'session chips').

## Development

### Contribution Attribution

Use `liuyang <40610243@qq.com>` as both author and committer of new repository and automated release commits, and as the tagger of annotated tags. Do not add `Co-authored-by` or equivalent attribution for bots, models or agents. Preserve existing commit history and upstream authorship; do not rewrite old commits to change attribution. Attribute another contributor only when the maintainer explicitly requests it.

### Fork Maintenance and Branches

This fork is independently maintained on `main`. It contains the macOS 13 compatibility work and accepted customizations; do not wait for upstream PRs to merge before integrating changes here.

- Work in the current project directory on `main` by default, as requested by the maintainer. Do not create a branch or worktree for every edit.
- Use a temporary branch only when isolation is needed or requested. Integrate accepted changes into `main` and remove the temporary branch after verification.
- `origin` is this fork; `upstream` is the original author's repository. Review upstream updates before merging them into `main`, preserving local compatibility and customizations.
- Keep `compat/macos13` available for the existing upstream PR; it is not the daily development or release branch.
- On Ventura, use the cloud **Release** workflow for delivery; it calls the existing Intel and Apple Silicon builders. Download the Intel asset for the exact release commit, verify it, re-sign with `scripts/sign-ventura-local.sh`, and install at the stable `/Applications/Remarc.app` path before relaunching. Xcode 14 on Ventura cannot build the Swift 6 package locally.

For an explicitly requested worktree, use `.worktrees/<name>`. Always use `"$(pwd)/DerivedData"` (command substitution), never `"$PWD/DerivedData"` (variable).

### Crit Mode / Microphone Capture

When building from worktrees (or after nuking DerivedData), macOS TCC microphone permissions get fragmented across binary paths. The audio tap silently produces 0 buffers without any error. **Fix: nuke DerivedData + reset TCC before relaunch:**

```bash
rm -rf app/DerivedData
# rebuild...
tccutil reset Microphone com.metepolat.Remarc
pkill -x Remarc; sleep 0.5; open app/DerivedData/Build/Products/Debug/Remarc.app
```

The user must grant mic access when macOS prompts after the reset. Do this whenever audio capture stops working (0 buffers in debug log).

### Color System

All brand colors and gradients are defined in `Views/Colors.swift` as `Color` extensions. When making color-related changes:

- **Use `remarc*` tokens** (`remarcPrimary`, `remarcSecondary`, `remarcAccent`, etc.) — never hardcode brand hex values in views
- **All tokens take `colorScheme`** — they adapt for light/dark mode automatically
- **Popover background** uses `remarcBackgroundGradient(for:)` — layered EllipticalGradients with `.plusLighter` blend over a darkened base. Do not add `.background(.regularMaterial)` to SwiftUI — the VEV provides that
- **Quote references** use a 2pt indigo left border via `.overlay(alignment: .leading)` — keep this consistent across CommentCardView, CommentEditorView, and CommentInputView
- **Buttons** use `remarcBrandGradient` for primary CTAs and `remarcPrimary` for accent text

### Research During Brainstorming & Planning

When brainstorming features or writing implementation plans, **always do online research** (WebSearch, WebFetch) and **check Context7 docs** for relevant Apple frameworks and libraries before proposing approaches. API availability, deprecation status, and permission requirements change frequently — don't rely on training data alone.

### Architecture

- `app/RemarcPackage/` — Swift Package with all app source
- `app/RemarcPackage/Sources/RemarcFeature/` — Main feature module
  - `Views/` — SwiftUI views and AppKit window controllers
  - `Services/` — PersistenceManager, SelectionMonitor, ExportManager, etc.
- `scripts/` — Automation scripts
- `tools/ax-inspect/` — Accessibility inspection CLI (standalone SPM package)
