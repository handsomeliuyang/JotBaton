# Remarc

Independently maintained macOS menu bar app (SwiftUI + AppKit) for contextual commenting on text selections.

- Production: `Remarc.app`, bundle ID `com.metepolat.Remarc`, executable `Remarc`
- Development: `Remarc Dev.app`, bundle ID `com.metepolat.Remarc.dev`, executable `RemarcDev`; separate DEV app and menu bar icons
- Min macOS: standard build 14.0 (`app/Config/Shared.xcconfig`); opt-in Ventura build 13.0 (`app/Config/Ventura.xcconfig` with `REMARC_VENTURA=1`). Xcode 26.2 / Swift 6.2 is required by the locked dependencies. LSUIElement (no dock icon)
- Delivery build: use the **Release** GitHub Actions workflow in `handsomeliuyang/Remarc`; build both Ventura Intel and Apple Silicon from the same version commit (see `RELEASING.md`).
- Development debug log: `/tmp/remarc_dev_debug.log`. Production Release writes no file unless `defaults write com.metepolat.Remarc debugFileLoggingEnabled -bool YES`; then it uses `~/Library/Logs/Remarc/remarc_debug.log`.
- Production data: `~/Library/Application Support/Remarc/comments.json` (legacy fallback: `data.json`)
- Development data: `~/Library/Application Support/Remarc Dev/comments.json`; never copy production data or defaults into it automatically
- iCloud snapshots: production `iCloud Drive/Remarc`; development `iCloud Drive/Remarc Dev`

**MANDATORY: After every successful build, you MUST relaunch Remarc.** The user cannot verify changes otherwise. Do this every single time, no exceptions:
1. Build with `-derivedDataPath "$(pwd)/DerivedData"` (deterministic output path — no grep/find needed). Both build scripts relaunch their exact output on the matching CI host.
2. For local delivery, detect the current machine's architecture with `uname -m` and download the matching package from the exact release: the Apple Silicon DMG for `arm64`, or the Ventura Intel ZIP for `x86_64`. Verify its checksum and pinned production certificate with `scripts/sign-app.py --channel production --verify-only`. Install with `python3 scripts/install-app.py /absolute/path/Remarc.app --channel production`; it backs up the matching app and user data, installs without re-signing, and relaunches `/Applications/Remarc.app`. Retain both native downloads.
3. Development installs use `--channel development` and `/Applications/Remarc Dev.app`. Relaunch only the corresponding executable; never kill the other channel as part of a build or install.

### Development Previews: This Mac Only

A development (dev) preview builds **only the package for the current Mac** and runs it there. Do not build both architectures for a preview.

- Run `bash scripts/dev-preview.sh`. On a host that can compile the package (Xcode 26.2+, or the CLT macOS 26.5 SDK) it builds locally through `scripts/run-local.sh`. Otherwise (this Ventura Intel Mac with Xcode 14) it dispatches the **Development** workflow for this Mac's package only (`target` from `uname -m`, tests skipped), waits, downloads and checksums the artifact, verifies the development identity, installs it with `install-app.py --channel development` and relaunches `Remarc Dev`.
- The cloud path builds the pushed branch head, so commit and push before running it; the script refuses uncommitted or unpushed work. Downloads are kept in `app/DerivedData/DevPreview/<run-id>/`.
- `--with-tests` runs the Swift suites in the cloud preview; `--cloud` forces the cloud path on a local-capable Mac.
- Both-architecture builds remain the rule for deliverables (Release workflow), not for previews.

## Build

When working on UI changes in SwiftUI, always do a clean build after layout changes to avoid stale build cache issues. Use `xcodebuild clean` or delete DerivedData when builds behave unexpectedly.

### Required Delivery and Release Process

- Every requested deliverable build must produce **both** packages: **Hackintosh / Ventura Intel (`x86_64`, macOS 13+)** and **M5 Pro / Apple Silicon (`arm64`, macOS 14+)**. Do not stop after building only the local machine's architecture.
- Use `.github/workflows/release.yml` for versioned delivery. It builds both packages in **Release** configuration from one exact commit, runs both Swift test profiles plus Intel compatibility and packaged MCP checks, and publishes both assets with SHA-256 checksums to the same GitHub Release in `handsomeliuyang/Remarc`.
- Increment marketing version and build number for a new release. The workflow owns the version commit and annotated tag; never move an existing tag or overwrite published assets. See `RELEASING.md` for retries.
- Actions artifacts are intermediate build output, not a completed GitHub Release. Verify the published Release assets and include its URL in the delivery response.
- Standalone **Ventura Intel** / **Apple Silicon** workflows remain available for development and troubleshooting; they do not publish a Release.
- Packages use a fixed private self-signed production certificate stored in this repository's Actions Secrets. They are manually updated and are not Apple-notarized. Never fall back to ad-hoc signing or replace a missing identity with a newly generated certificate.
- After publishing, install and relaunch the matching native package on the current machine. Verify both architectures on their matching CI hosts and retain both downloads for transfer between Macs. Report the local checks actually performed.

### Development and Production Identities

- Local testing and the **Development** workflow share the exact `signing/development.p12` and `signing/development-password.txt`. These are deliberately committed **test-only** credentials, an explicit maintainer-approved exception. The secret scanner exception covers only this `.p12` file.
- Production certificate plus private key exist exclusively in GitHub Actions Secrets `REMARC_SIGNING_P12_BASE64`; its password is `REMARC_SIGNING_P12_PASSWORD`. Never commit, log, retain, or download production private material for local signing. Only the public fingerprint is in `signing/identities.json`.
- Both Intel and Apple Silicon production packages use that same production identity. Both development packages and both Macs' local builds use the other, shared test identity. Select and verify identities by pinned fingerprint, not just certificate name.
- `scripts/sign-app.py` imports into a temporary dedicated keychain, restores the original keychain search list and deletes the temporary keychain. Signing does not require changing user/system certificate trust or authorization rules. Keep command failures and timeout messages free of credentials.
- `scripts/run-local.sh` clean-builds the development app on supported hosts, signs, installs and relaunches it. Preserve its CLT/macOS 26.5 SDK preview path, including development icons and identity. Xcode 14 / Swift 5.8 on Ventura cannot compile this package (Xcode 16+ needs macOS 14.5+); there `scripts/dev-preview.sh` builds this Mac's package in the cloud and installs it. Direct Xcode Debug builds are finalized by the scheme post-build action; builders set `REMARC_SIGNING_IN_BUILDER=1` and finalize once themselves.
- The **Development** workflow builds one exact commit. Its `target` input selects `both` (default), `ventura-intel` or `apple-silicon`, and `skip_tests` skips the Swift suites for quick previews; `scripts/dev-preview.sh` sets both. Its Actions artifacts are development output, not a published production Release. Versioned production delivery still requires the **Release** workflow and both published assets.
- Use `AppIdentity.current` (the app's Bundle ID) for persistent paths and routing. A DEBUG compilation flag alone does not identify the installed channel. Keep local comments, images, model caches, settings, sync records/outbox/backups, agent markers and reload notifications isolated.
- Cloud connection, creation and authorization must all use the same channel's child directory. Accept iCloud Drive root or that channel's folder; reject the other channel's folder and symbolic links. Never automatically migrate, merge, publish or apply data between channels. Keep production paths unchanged for existing data.
- Production uses `remarc://`, browser port `9274`, MCP entry `remarc`, and Control+Option shortcuts. Development uses `remarc-dev://`, port `9275`, MCP entry `remarc-dev`, and Control+Option+Shift defaults. Stock browser/marketplace integrations target production; the development bundled MCP uses development storage.
- Regenerate development visual assets with `swift scripts/generate-development-icons.swift /absolute/repo/path`; keep the DEV app icon and distinct template menu bar icon. Do not substitute the production app icon for CLT previews. Floating selection prompts use `RemarcBrandMark`; comment composers/editors, screenshot preview and annotation toolbars use `DevelopmentIdentityBadge`. The screenshot selection overlay also draws the same DEV app icon and name. Keep every development surface identifiable, including loading and empty states; do not leave the production R logo in development floating UI.
- Each Mac and each app has independent macOS permission grants. A deliberate certificate rotation can require one-time reauthorization. Do not routinely reset TCC; `scripts/install-app.py --reset-permissions` is only for an explicitly requested certificate migration and resets Accessibility/ScreenCapture for the selected channel alone.
- Resolve dependencies through `scripts/resolve-packages.sh` and the checkout's `app/DerivedData/PackageCache`. Its Sparkle prefetch verifies the exact upstream SHA-256 and pinned version, with an official asset API download fallback. Do not disable checksum validation or change dependency revisions to bypass download failures.

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
- Use this repository's cloud **Release** workflow for deliverables. Development previews use `scripts/dev-preview.sh`: a local build on supported machines, and a cloud build of only this Mac's package on Ventura, where Xcode 14 cannot build the Swift 6 package.

For an explicitly requested worktree, use `.worktrees/<name>`. Always use `"$(pwd)/DerivedData"` (command substitution), never `"$PWD/DerivedData"` (variable).

### Crit Mode / Microphone Capture

When building from worktrees (or after nuking DerivedData), macOS TCC microphone permissions get fragmented across binary paths. The audio tap silently produces 0 buffers without any error. **Fix: nuke DerivedData + reset TCC before relaunch:**

```bash
rm -rf app/DerivedData
# rebuild...
tccutil reset Microphone com.metepolat.Remarc.dev
python3 scripts/relaunch-app.py "/Applications/Remarc Dev.app"
```

The example targets development. For a confirmed production issue, use `com.metepolat.Remarc` and `/Applications/Remarc.app` instead. Reset only the affected channel after confirming 0 buffers in its log; the user must grant mic access again when macOS prompts.

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
