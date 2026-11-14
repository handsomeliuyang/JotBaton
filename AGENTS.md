# JotBaton

Independently maintained macOS menu bar app (SwiftUI + AppKit): a lightweight inbox for AI collaboration. Quickly capture ideas and product feedback with their context, copy them to an external AI tool, then manually mark the work complete. Future MCP retrieval and status updates are a possible handoff extension; do not advertise them as the current workflow. See `docs/brand-transition.md` for the agreed positioning and brand compatibility decisions.

- Production: `JotBaton.app`, bundle ID `com.metepolat.Remarc`, executable `Remarc`
- Development: `JotBaton Dev.app`, bundle ID `com.metepolat.Remarc.dev`, executable `RemarcDev`; separate DEV app and menu bar icons
- Min macOS: standard build 14.0 (`app/Config/Shared.xcconfig`); opt-in Ventura build 13.0 (`app/Config/Ventura.xcconfig` with `REMARC_VENTURA=1`). Xcode 26.2 / Swift 6.2 is required by the locked dependencies. LSUIElement (no dock icon)
- Delivery: local compilation is Development only. Production builds/signing/tests/publication run through the manually dispatched GitHub **Release** workflow. Application updates check this repository’s GitHub Releases and use Sparkle for user-initiated download, verified installation and relaunch; software releases no longer use iCloud (see `RELEASING.md`).
- Development debug log: `/tmp/remarc_dev_debug.log`. Production Release writes no file unless `defaults write com.metepolat.Remarc debugFileLoggingEnabled -bool YES`; then it uses `~/Library/Logs/Remarc/remarc_debug.log`.
- Production data: `~/Library/Application Support/Remarc/comments.json` (legacy fallback: `data.json`)
- Development data: `~/Library/Application Support/Remarc Dev/comments.json`; never copy production data or defaults into it automatically
- iCloud sync folders: production `iCloud Drive/JotBaton`; development `iCloud Drive/JotBaton Dev`

**MANDATORY: After a successful native app build/install, relaunch that exact channel.** The user must be able to verify changes:
1. Use the checkout's deterministic `app/DerivedData` output. Existing Xcode builders use `-derivedDataPath "$(pwd)/DerivedData"` from `app/` and clean-build UI changes.
2. Production delivery uses `.github/workflows/release.yml`: build both architectures from one version commit, run full standard/Ventura Swift suites and native Intel compatibility checks, verify packages/signatures/provenance, then publish both assets to one GitHub Release. Do not compile production packages locally.
3. Intel runtime compatibility verification, when explicitly requested, must run on an Intel Mac after native package installation. Do not launch Intel apps on Apple Silicon or claim Ventura runtime verification there.
4. Production checks the public GitHub latest Release, compares semantic versions numerically and offers Upgrade and Restart. Sparkle verifies the signed native package and feed before replacing/relaunching the app, after app/data backup and editor/capture/save gates. Never offer a downgrade or consume production updates in Dev. Keep application-update settings separate from iCloud snapshot sync.
5. For explicit manual installs use `python3 scripts/install-app.py /absolute/path/JotBaton.app --channel production`; development uses `--channel development`. These verify, back up, install without re-signing, and relaunch only the matching app.
6. Standing maintainer preference: when asked to publish a production release and update this Mac, do not rerun local suites solely for delivery, and do not run post-install diagnostics, smoke tests, UI walkthroughs or functional tests unless explicitly requested. The production installer defaults to a normal launch without diagnostics. Keep pre-install checksum/signature/architecture checks, backups and the matching-channel relaunch; read version/build metadata only to report installation. Required GitHub Release workflow checks still run. Do not ask the maintainer to repeat this preference.


### Development Previews

- `bash scripts/dev-preview.sh` builds locally only when the selected toolchain can compile the package; it never dispatches GitHub automatically. `scripts/run-local.sh` retains full Xcode and the existing CLT preview path.
- The current Ventura Intel machine (macOS 13.7.8 / Xcode 14.3.1 / Swift 5.8.1) is an install/runtime verification host. Do not attempt full app compilation there, downgrade pinned dependencies, or install unsupported toolchains to bypass this limitation.
- A development preview builds the current host’s architecture only and skips full tests by default; `--with-tests` explicitly runs the current profile’s suite. Production publication builds native ARM (macOS 14+) and Intel (macOS 13+) packages on GitHub runners.
- `JotBaton Dev` keeps its shared development identity, DEV visuals and isolated storage. GitHub production releases use `JotBaton.app` and the existing production identity.

## Build

When working on UI changes in SwiftUI, always do a clean build after layout changes to avoid stale build cache issues. Use `xcodebuild clean` or delete DerivedData when builds behave unexpectedly.

### Production Delivery through GitHub

- Production builds are GitHub-only. Local build scripts default to Debug and reject Release before resolving or compiling; local production packaging/signing is disabled. Local verification and installation of downloaded signed production packages are supported.
- Explicitly dispatch `.github/workflows/release.yml` on clean, accepted `main` source with a new version/build and notes. It owns the version commit and tag. All packages/tests use that exact commit. Both author and committer remain `liuyang <40610243@qq.com>`.
- Release entry point: `python3 scripts/release.py [patch|minor|major|X.Y.Z]` previews commit-derived notes; only `--publish` dispatches GitHub. `/release` is documented in `.claude/commands/release.md`. Use `--source-sha` to pin the reviewed full SHA and `--notes-file` for reviewed Chinese bullets. The workflow commits version/build and `CHANGELOG.md` together as `chore(X.Y.Z): release vX.Y.Z`; the same notes reach GitHub and Sparkle. Do not bump versions or create release commits locally.
- Release must run full Swift suites for both standard and Ventura profiles, Intel compatibility behavior, browser extension tests, release/build policy checks. Both signed architecture packages and checksums must be published and verified before claiming success.
- Never move tags or overwrite published assets; follow `RELEASING.md` recovery instructions. Actions artifacts alone are not a public Release.
- Production checks GitHub Releases for newer versions and offers user-initiated in-app upgrades through Sparkle. Publish signed `appcast-arm64.xml` and `appcast-x86_64.xml` alongside the native packages. `signing/updates.json` pins the public EdDSA key; its private key is GitHub Secret `REMARC_UPDATE_EDDSA_KEY`, separate from the pinned production certificate. No local/iCloud software publisher, update-folder authorization or legacy custom installer remains. Do not delete historical cloud files, keychains or backups automatically.
- iCloud comment/image/snapshot synchronization remains supported and channel-isolated. Never mix software release cleanup with snapshot data.
- CI, Development and standalone architecture workflows remain explicit manual opt-in; pushes and pull requests do not trigger compilation. No silent cloud fallback for local Dev failures.
- Packages use the same pinned production certificate, without ad-hoc fallback or automatic certificate rotation. Apple notarization is not part of this flow.

### Development and Production Identities

- Local testing and the **Development** workflow share the exact `signing/development.p12` and `signing/development-password.txt`. These are deliberately committed **test-only** credentials, an explicit maintainer-approved exception. The secret scanner exception covers only this `.p12` file.
- Production signing is authorized only in GitHub Actions using existing Secrets `REMARC_SIGNING_P12_BASE64` and `REMARC_SIGNING_P12_PASSWORD`. No local production keychain provisioning or migration is part of delivery. Never put private keys, P12s, passwords or decrypted material in repositories, iCloud, logs or release assets. Only the public identity fingerprint is committed.
- Both Intel and Apple Silicon production packages use that same production identity. Both development packages and both Macs' local builds use the other, shared test identity. Select and verify identities by pinned fingerprint, not just certificate name.
- `scripts/sign-app.py` uses temporary isolated keychains for development and explicitly dispatched GitHub production signing. Local production `--verify-only` is allowed for installing downloaded packages. Keep failures free of credentials and do not change user/system certificate trust or reset permissions.
- `scripts/run-local.sh` clean-builds the development app on supported hosts, signs, installs and relaunches it. Preserve its CLT/macOS 26.5 SDK preview path, including development icons and identity. Xcode 14 / Swift 5.8 on Ventura cannot compile this package (Xcode 16+ needs macOS 14.5+); there obtain the Intel production package from GitHub Releases; no automatic cloud fallback is allowed. Direct Xcode Debug builds are finalized by the scheme post-build action; builders set `REMARC_SIGNING_IN_BUILDER=1` and finalize once themselves.
- When explicitly requested, the **Development** workflow builds one exact commit. Its `target` input selects `both` (default), `ventura-intel` or `apple-silicon`, and `skip_tests` skips the Swift suites for quick previews; manual dispatch must set both inputs deliberately. Its Actions artifacts are development output, not a published production Release. Production delivery requires the **Release** workflow and both published assets; local builds are Dev only.
- Use `AppIdentity.current` (the app's Bundle ID) for persistent paths and routing. A DEBUG compilation flag alone does not identify the installed channel. Keep local comments, images, model caches, settings, sync records/outbox/backups, device-specific metadata isolated.
- Cloud connection, creation and authorization must all use the same channel's child directory. Accept iCloud Drive root or that channel's folder; reject the other channel's folder and symbolic links. Never automatically migrate, merge, publish or apply data between channels. Keep production paths unchanged for existing data.
- Production uses `remarc://`, browser port `9274`, and Control+Option shortcuts. Development uses `remarc-dev://`, port `9275`, and Control+Option+Shift defaults. Stock browser integrations target production.
- Regenerate development visual assets with `swift scripts/generate-development-icons.swift /absolute/repo/path` (DEV only), or add `--all` to regenerate both channels and companion icons; keep the DEV app icon and distinct template menu bar icon. Do not substitute the production app icon for CLT previews. Floating selection prompts use `RemarcBrandMark`; comment composers/editors, screenshot preview and annotation toolbars use `DevelopmentIdentityBadge`. The screenshot selection overlay also draws the same DEV app icon and name. Keep every development surface identifiable, including loading and empty states; do not leave the production R logo in development floating UI.
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

This repository is independently developed and released at `handsomeliuyang/JotBaton` on `main`. All accepted customizations and compatibility work belong to this repository's own development flow.

- Work in the current project directory on `main` by default, as requested by the maintainer. Do not create a branch or worktree for every edit.
- Use a temporary branch only when isolation is needed or requested. Integrate accepted changes into `main` and remove the temporary branch after verification.
- Keep `origin` as the only remote, pointing to `git@github.com:handsomeliuyang/JotBaton.git`. Local `main` tracks `origin/main`.
- Do not configure an `upstream` remote, synchronize from the original project, or submit changes or pull requests to it. Development and release do not depend on the original project's review or merge process.
- Local builds are Dev only. Production delivery uses the explicitly dispatched GitHub Release workflow with full regression tests and both published native packages. Ventura Intel downloads its native Intel package from GitHub and performs runtime verification only when explicitly requested; it cannot compile the current Swift package with its installed toolchain.

For an explicitly requested worktree, use `.worktrees/<name>`. Always use `"$(pwd)/DerivedData"` (command substitution), never `"$PWD/DerivedData"` (variable).

### Color System

All brand colors and gradients are defined in `app/RemarcPackage/Sources/Core/Theme/Colors.swift` as `Color` extensions. When making color-related changes:

- **Use `remarc*` tokens** (`remarcPrimary`, `remarcSecondary`, `remarcAccent`, etc.) — never hardcode brand hex values in views
- **All tokens take `colorScheme`** — they adapt for light/dark mode automatically
- **Popover background** uses `remarcBackgroundGradient(for:)` — layered EllipticalGradients with `.plusLighter` blend over a darkened base. Do not add `.background(.regularMaterial)` to SwiftUI — the VEV provides that
- **Quote references** use a 2pt indigo left border via `.overlay(alignment: .leading)` — keep this consistent across CommentCardView, CommentEditorView, and CommentInputView
- **Buttons** use `remarcBrandGradient` for primary CTAs and `remarcPrimary` for accent text

### Research During Brainstorming & Planning

When brainstorming features or writing implementation plans, **always do online research** (WebSearch, WebFetch) and **check Context7 docs** for relevant Apple frameworks and libraries before proposing approaches. API availability, deprecation status, and permission requirements change frequently — don't rely on training data alone.

### Architecture

- `app/RemarcPackage/` — One Swift Package with explicit `Core*`, `Feature*` and application-composition targets
- `app/RemarcPackage/Sources/App/` — Lifecycle, routing, menu bar and dependency wiring
- `app/RemarcPackage/Sources/Features/<feature>/` — Feature-owned models, rules, repositories and native capabilities; `UI/` holds application workflows compiled by `RemarcFeature`
- `app/RemarcPackage/Sources/Core/` — Platform, localization, theme and reusable UI; never imports features
- `app/RemarcPackage/Tests/RemarcFeatureTests/` — Tests grouped by feature, core capability and architecture
- `tests/architecture/` — Dependency-direction and exact source-ownership checks for both profiles
- Read `ARCHITECTURE.md` before adding a target or moving sources. Keep manifest exclusions, tests, resources, generators and source-contract paths synchronized.
- `scripts/` — Automation scripts
- `tools/ax-inspect/` — Accessibility inspection CLI (standalone SPM package)
