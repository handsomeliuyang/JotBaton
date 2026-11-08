# Remarc

Independently maintained macOS menu bar app (SwiftUI + AppKit) for contextual commenting on text selections.

- Bundle ID: `com.metepolat.Remarc`
- Min macOS: standard build 14.0 (`app/Config/Shared.xcconfig`); opt-in Ventura build 13.0 (`app/Config/Ventura.xcconfig` with `REMARC_VENTURA=1`). Xcode 26.2 / Swift 6.2 is required by the locked dependencies. LSUIElement (no dock icon)
- Delivery build: use the **Release** GitHub Actions workflow in `handsomeliuyang/Remarc`; build both Ventura Intel and Apple Silicon from the same version commit (see `RELEASING.md`).
- Debug log: `/tmp/remarc_debug.log` (Debug builds only; release builds write no log file unless `defaults write com.metepolat.Remarc debugFileLoggingEnabled -bool YES`)
- Data: `~/Library/Application Support/Remarc/comments.json` (legacy fallback: `data.json`)

**MANDATORY: After every successful build, you MUST relaunch Remarc.** The user cannot verify changes otherwise. Do this every single time, no exceptions:
1. Build with `-derivedDataPath "$(pwd)/DerivedData"` (deterministic output path — no grep/find needed). Both build scripts relaunch their exact output on the matching CI host.
2. For local delivery, detect the current machine's architecture with `uname -m` and download the matching package from the exact release: the Apple Silicon DMG for `arm64`, or the Ventura Intel ZIP for `x86_64`. Verify it, preserve the existing local signing identity using `scripts/sign-local.sh`, install at `/Applications/Remarc.app`, and relaunch that installed app. Keep a rollback backup and preserve user data.

## Build

When working on UI changes in SwiftUI, always do a clean build after layout changes to avoid stale build cache issues. Use `xcodebuild clean` or delete DerivedData when builds behave unexpectedly.

### Required Delivery and Release Process

- Every requested deliverable build must produce **both** packages: **Hackintosh / Ventura Intel (`x86_64`, macOS 13+)** and **M5 Pro / Apple Silicon (`arm64`, macOS 14+)**. Do not stop after building only the local machine's architecture.
- Use `.github/workflows/release.yml` for versioned delivery. It builds both packages in **Release** configuration from one exact commit, runs both Swift test profiles plus Intel compatibility and packaged MCP checks, and publishes both assets with SHA-256 checksums to the same GitHub Release in `handsomeliuyang/Remarc`.
- Increment marketing version and build number for a new release. The workflow owns the version commit and annotated tag; never move an existing tag or overwrite published assets. See `RELEASING.md` for retries.
- Actions artifacts are intermediate build output, not a completed GitHub Release. Verify the published Release assets and include its URL in the delivery response.
- Standalone **Ventura Intel** / **Apple Silicon** workflows remain available for development and troubleshooting; they do not publish a Release.
- Packages use ad-hoc signing unless this repository configures its own Developer ID and notarization credentials. Use this repository's releases and credentials. Packages use manual updates; only claim Apple notarization when verified.
- After publishing, install and relaunch the matching native package on the current machine. Verify both architectures on their matching CI hosts and retain both downloads for transfer between Macs. Report the local checks actually performed.

### Worktree Builds

When building from worktrees, always verify the correct DerivedData path and binary location before launching. Use absolute paths instead of $PWD in build commands.

## UI Work

When the user describes a UI bug, confirm WHICH specific component/view they mean before editing. Ask clarifying questions if the target is ambiguous (e.g., 'comment cards' vs 'session chips').

## Development

### Contribution Attribution

Use `liuyang <40610243@qq.com>` as both author and committer of all new commits, including merge and automated release commits, and as the tagger of annotated tags. The release workflow must use this same identity. Do not add `Co-authored-by` or equivalent attribution for bots, models or agents. Preserve existing commit history; do not rewrite historical attribution. Attribute another contributor only when the maintainer explicitly requests it.

### Independent Development and Branches

This repository is independently developed and released at `handsomeliuyang/Remarc` on `main`. All accepted customizations and compatibility work belong to this repository's own development flow.

- Work in the current project directory on `main` by default, as requested by the maintainer. Do not create a branch or worktree for every edit.
- Use a temporary branch only when isolation is needed or requested. Integrate accepted changes into `main` and remove the temporary branch after verification.
- Keep `origin` as the only remote, pointing to `git@github.com:handsomeliuyang/Remarc.git`. Local `main` tracks `origin/main`.
- Do not configure an `upstream` remote, synchronize from the original project, or submit changes or pull requests to it. Development and release do not depend on the original project's review or merge process.
- Use this repository's cloud **Release** workflow for deliverables. Local source previews are available through `scripts/run-local.sh` on supported development machines; Xcode 14 on Ventura cannot build the Swift 6 package locally.

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
