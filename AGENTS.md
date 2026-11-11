# Remarc

Independently maintained macOS menu bar app (SwiftUI + AppKit) for contextual commenting on text selections.

- Production: `Remarc.app`, bundle ID `com.metepolat.Remarc`, executable `Remarc`
- Development: `Remarc Dev.app`, bundle ID `com.metepolat.Remarc.dev`, executable `RemarcDev`; separate DEV app and menu bar icons
- Min macOS: standard build 14.0 (`app/Config/Shared.xcconfig`); opt-in Ventura build 13.0 (`app/Config/Ventura.xcconfig` with `REMARC_VENTURA=1`). Xcode 26.2 / Swift 6.2 is required by the locked dependencies. LSUIElement (no dock icon)
- Default delivery: build and sign locally on any eligible Apple Silicon Mac with full Xcode 26.2+, Swift 6.2+ and the existing production identity in a dedicated local keychain. Publish both architectures to `iCloud Drive/Remarc/Updates` using `python3 scripts/publish-icloud-update.py`. Do not bind this flow to a model, hostname or individual Mac. GitHub builds are explicit opt-in only (see `RELEASING.md`).
- Development debug log: `/tmp/remarc_dev_debug.log`. Production Release writes no file unless `defaults write com.metepolat.Remarc debugFileLoggingEnabled -bool YES`; then it uses `~/Library/Logs/Remarc/remarc_debug.log`.
- Production data: `~/Library/Application Support/Remarc/comments.json` (legacy fallback: `data.json`)
- Development data: `~/Library/Application Support/Remarc Dev/comments.json`; never copy production data or defaults into it automatically
- iCloud snapshots: production `iCloud Drive/Remarc`; development `iCloud Drive/Remarc Dev`

**MANDATORY: After a successful native app build/install, relaunch that exact channel.** The user must be able to verify changes:
1. Use the checkout's deterministic `app/DerivedData` output. Existing Xcode builders use `-derivedDataPath "$(pwd)/DerivedData"` from `app/` and clean-build UI changes.
2. Personal production delivery uses `python3 scripts/publish-icloud-update.py` on an eligible Apple Silicon build host. It builds both architectures from one version commit, tests both Swift profiles, verifies signatures/provenance, publishes only after package uploads complete, then installs/relaunches the native production app.
3. An Intel cross-build on Apple Silicon must not launch the Intel app, kill the native production app or claim Ventura runtime verification. Verify the package statically; run/verify it after installation on an Intel Mac. No Rosetta dependency is required for publication.
4. Client updates select the native package, copy it out of iCloud, verify the signed description/checksum/pinned certificate and install with the bundled native helper. Keep one previous app/data backup. Never copy Dev data into production.
5. For explicit manual installs use `python3 scripts/install-app.py /absolute/path/Remarc.app --channel production`; development uses `--channel development`. These verify, back up, install without re-signing, and relaunch only the matching app.

### Development Previews

- `bash scripts/dev-preview.sh` builds locally only when the selected toolchain can compile the package; it never dispatches GitHub automatically. `scripts/run-local.sh` retains full Xcode and the existing CLT preview path.
- The current Ventura Intel machine (macOS 13.7.8 / Xcode 14.3.1 / Swift 5.8.1) is an install/runtime verification host. Do not attempt full app compilation there, downgrade pinned dependencies, or install unsupported toolchains to bypass this limitation.
- A development preview builds the current host's architecture only. A personal production publication builds both native ARM (macOS 14+) and Intel (macOS 13+) packages on the eligible Apple Silicon host.
- `Remarc Dev` keeps its shared development identity, DEV visuals and isolated storage. Personal production updates use `Remarc.app` and the existing production identity.

## Build

When working on UI changes in SwiftUI, always do a clean build after layout changes to avoid stale build cache issues. Use `xcodebuild clean` or delete DerivedData when builds behave unexpectedly.

### Default Personal Delivery and Optional Public Release

- Use `python3 scripts/publish-icloud-update.py` on an eligible Apple Silicon Mac. This capability rule is not specific to any model. Require full Xcode 26.2+, Swift 6.2+, Node.js for packaged MCP checks, an active iCloud Drive, a clean `main` checkout and the pinned production identity.
- The script owns the marketing/build increment and the `Release vX.Y.Z` version commit. Both archives use that exact commit; author and committer remain `liuyang <40610243@qq.com>`. Push source separately when desired; pushing must not start a GitHub build.
- Publish signed, immutable, readable package names containing version/build, architecture and a date to seconds in `iCloud Drive/Remarc/Updates/`. Upload both ZIPs and confirm upload before atomically committing the signed `latest.json`; confirm that description's upload before cleaning the previous known package names. Never mix update cleanup with snapshot cleanup.
- Keep only the latest cloud package pair and description. A client keeps one previous app/data backup under `Application Support/Remarc Update Backups/Previous`. New computers install manually once and authorize iCloud/system access; subsequent supported versions can prompt for updates.
- Never silently fall back to cloud compilation. GitHub CI, Development, Intel, Apple Silicon and Release builds run only after explicit user instruction/manual dispatch. CI has no push/PR compilation triggers.
- Public GitHub Releases remain optional and must be explicitly requested. For that path `.github/workflows/release.yml` still builds/verifies both architectures from one commit and publishes both packages/checksums. Never move tags or overwrite published assets; follow `RELEASING.md` recovery instructions. Actions artifacts alone are not a public Release.
- Packages use the same fixed private production certificate, without ad-hoc fallback or automatic certificate rotation. Apple notarization is not part of this flow.

### Development and Production Identities

- Local testing and the **Development** workflow share the exact `signing/development.p12` and `signing/development-password.txt`. These are deliberately committed **test-only** credentials, an explicit maintainer-approved exception. The secret scanner exception covers only this `.p12` file.
- Production signing is explicitly authorized on eligible Apple Silicon build hosts using the existing identity in a dedicated local keychain (`~/Library/Keychains/RemarcProduction.keychain-db`, overridable with `REMARC_PRODUCTION_KEYCHAIN`). Provision with `scripts/setup-production-signing.py`. GitHub Secrets remain available for optional cloud releases. Never put private keys, P12s, passwords or decrypted migration material in repositories, iCloud, logs or release assets. Only the public identity fingerprint is committed.
- Both Intel and Apple Silicon production packages use that same production identity. Both development packages and both Macs' local builds use the other, shared test identity. Select and verify identities by pinned fingerprint, not just certificate name.
- `scripts/sign-app.py` uses the dedicated persistent keychain for authorized local production builds, or temporary isolated keychains for development and explicit CI signing. Local production signing never exports a private key. One-time migration uses `signing-migration.yml` on Ubuntu to encrypt existing Secrets to a recipient generated on the destination Apple Silicon Mac; only that Mac decrypts/imports them. Keep failures free of credentials and do not change user/system certificate trust or reset permissions.
- `scripts/run-local.sh` clean-builds the development app on supported hosts, signs, installs and relaunches it. Preserve its CLT/macOS 26.5 SDK preview path, including development icons and identity. Xcode 14 / Swift 5.8 on Ventura cannot compile this package (Xcode 16+ needs macOS 14.5+); there obtain the Intel package from the eligible Apple Silicon builder through iCloud; no automatic cloud fallback is allowed. Direct Xcode Debug builds are finalized by the scheme post-build action; builders set `REMARC_SIGNING_IN_BUILDER=1` and finalize once themselves.
- When explicitly requested, the **Development** workflow builds one exact commit. Its `target` input selects `both` (default), `ventura-intel` or `apple-silicon`, and `skip_tests` skips the Swift suites for quick previews; manual dispatch must set both inputs deliberately. Its Actions artifacts are development output, not a published production Release. Optional public GitHub delivery requires the **Release** workflow and both published assets; personal delivery uses the local iCloud publisher.
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
- Default personal delivery builds both packages locally on an eligible Apple Silicon Mac and distributes via iCloud. GitHub workflows are opt-in only. Ventura Intel receives the native Intel package and performs runtime verification; it cannot compile the current Swift package with its installed toolchain.

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
