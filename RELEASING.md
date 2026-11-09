# Releasing this Remarc fork

This fork is maintained at `handsomeliuyang/Remarc`. The **Release** workflow
publishes both supported architectures in one GitHub Release:

| Asset | Target | Configuration |
|---|---|---|
| `Remarc-Ventura-x86_64.zip` | Hackintosh / Intel, macOS 13+ | Release |
| `Remarc-Apple-Silicon-arm64.dmg` | M5 Pro / Apple Silicon, macOS 14+ | Release |
| `INSTALL.txt` | Installation instructions and exact source commit | — |
| `SHA256SUMS` | SHA-256 of all other assets | — |

Download from [this fork's Releases](https://github.com/handsomeliuyang/Remarc/releases).
Actions artifacts are intermediate outputs with an expiry date; they are not
published Releases. Standalone **Ventura Intel** and **Apple Silicon** workflows
remain useful for development, but do not publish a Release.

## Start a release

1. Commit accepted changes to `main` and push to `origin`.
2. Choose a new `X.Y.Z` marketing version and a larger build number than those
   in `app/Config/Shared.xcconfig`. Do not change these fields manually for a
   normal release; the workflow creates the version commit.
3. Run **Actions → Release → Run workflow** on `main`, with version, build
   number and nonempty release notes, or use:

```bash
gh workflow run release.yml -R handsomeliuyang/Remarc --ref main \
  -f version='1.2.5' -f build_number='24' \
  -f release_notes='Improve comment status styling and ship Intel and Apple Silicon installers.'
```

The values above are an example, not values to reuse after that release ships.
Always specify `-R handsomeliuyang/Remarc`. This independent repository uses only origin.

## What the workflow guarantees

1. Requires this fork and `main`; validates version/build increments, release
   notes, and existing tags/releases. It creates `Release vX.Y.Z` using
   `liuyang <40610243@qq.com>` as author and committer.
2. Passes that exact version commit to both reusable builders. Both perform
   clean Release builds with Xcode 26.2 and locked dependency revisions, then
   sign, relaunch and verify their apps on matching build hosts.
3. Runs the full Swift suite for both standard and Ventura profiles, Intel
   compatibility tests, and packaged MCP image delivery checks for both apps.
4. Downloads both artifacts, verifies checksums, extracts/mounts the packages,
   and checks signatures, architecture, deployment floor, version, build,
   source commit and manual-update setting in each app.
5. Requires `main` still to identify that source commit, creates the annotated
   `vX.Y.Z` tag with the same liuyang identity, and uploads both packages, installation instructions and checksums to a
   draft Release. It verifies names/sizes and downloads the draft assets to
   compare their bytes and checksums before publishing.
6. Publishes the Release as latest and downloads/verifies the published assets
   again. Deliver the Release URL, not just an Actions run link.

Preparation and publishing require `GITHUB_TOKEN` with `contents: write`.
Production builders require `REMARC_SIGNING_P12_BASE64` and `REMARC_SIGNING_P12_PASSWORD`
from Actions Secrets. Builders have read-only repository access. This process does not
use upstream Developer ID, notarization, Sparkle, Gist or website credentials.
It does not publish an upstream appcast or website update.

## Signing and installation

Both architectures are signed with one fixed private production certificate. They
are **not Apple-notarized**. Production `.p12` and password live exclusively in
GitHub Actions Secrets (`REMARC_SIGNING_P12_BASE64`, `REMARC_SIGNING_P12_PASSWORD`).
Only the public certificate fingerprint is committed in `signing/identities.json`.
Missing or mismatched credentials fail signing; there is no ad-hoc fallback.

1. Download both packages and verify `shasum -a 256 -c SHA256SUMS`.
2. On Intel, extract the ZIP with Archive Utility or `ditto`. On Apple Silicon,
   open the DMG. Keep both downloads for transfer between Macs.
3. From a source checkout, use `python3 scripts/install-app.py /absolute/path/Remarc.app --channel production`.
   It verifies the signature and native architecture, backs up the matching app and
   local data, trusts only its embedded public code-signing certificate, installs
   and relaunches. Use `--reset-permissions` only for a deliberate certificate migration.
   For manual installation, quit only the matching app, back it up, then replace `/Applications/Remarc.app`.
   Preserve `~/Library/Application Support/Remarc` and `iCloud Drive/Remarc`.
4. Relaunch the installed app. No local re-signing is necessary. The first
   migration to this new certificate requires granting Accessibility and Screen
   Recording again on **each Mac**. Future releases reuse this identity.
5. Verify signature, version, running path and functionality. Keep the rollback
   backup. If blocked on first launch, use [Apple's Open Anyway instructions](https://support.apple.com/en-us/102445).

### Development app

The **Development** workflow builds both architectures from one commit using the
same dedicated test certificate as local builds. Download its paired artifacts.
On supported Macs, `bash scripts/run-local.sh` clean-builds, signs, installs and
relaunches `/Applications/Remarc Dev.app`. Xcode 26.2+ is required; Ventura with
Xcode 14 must use the cloud-built Intel development artifact.

`signing/development.p12` and `signing/development-password.txt` are deliberately
shared test credentials. Both Macs use these exact bytes; do not regenerate them
per machine or build. `scripts/sign-app.py` uses a temporary dedicated keychain,
trusts the selected self-signed certificate for code signing, restores the original
keychain search list, and removes the temporary keychain. No login keychain or
production signing credentials are needed for development.

| Property | Production | Development |
|---|---|---|
| App | Remarc.app | Remarc Dev.app (DEV icon and separate menu bar icon) |
| Bundle ID | com.metepolat.Remarc | com.metepolat.Remarc.dev |
| Local data | Application Support/Remarc | Application Support/Remarc Dev |
| iCloud snapshots | iCloud Drive/Remarc | iCloud Drive/Remarc Dev |
| Settings and permission grants | Production bundle domain | Development bundle domain |
| Callback | remarc:// | remarc-dev:// |
| Browser socket | 9274 | 9275 |
| Default shortcut modifiers | Control+Option | Control+Option+Shift |
| Debug log | /tmp/remarc_debug.log (Debug only) | /tmp/remarc_dev_debug.log |

The apps can be installed and run together. Comments, screenshots, speech models,
snapshot receipts/outbox/backups, and integration markers use their channel's
local root. Sync authorization accepts only iCloud Drive or the **same channel's**
child folder; choosing the other channel's folder is rejected. No automatic data
migration or synchronization happens between channels. Bundled development MCP
uses the development root and notification name; explicit registrations use
`remarc-dev`, preserving the production `remarc` entry.
The stock browser extension and marketplace integration continue targeting production.

Both channels use manual updates. The standard Apple Silicon package retains
speech backends; voice features require macOS 26. CI startup checks do not imply
physical M5 Pro testing.

## Failure recovery

- Before publication, a failed build may be retried with the same inputs only
  while `main` is still the exact `Release vX.Y.Z` version commit. Rerun all jobs
  to ensure both artifacts are present. A matching existing tag can be reused.
- If source changes are needed after a failed build, land them on `main` and
  choose a new version/build. Never move an existing release tag.
- If a draft exists, inspect and verify it. The workflow refuses to overwrite
  it. Recover the verified draft manually, or explicitly remove the failed
  draft before restarting; do not delete an already-published release.
- If publication succeeded but a later network verification failed, verify
  the published assets and checksums. Do not republish or replace the assets.
- If `main` advances during compilation, publishing stops. Start a new release
  from the accepted source rather than tagging a different commit under the
  packages that were already built.

The commit, tag and package versions must always agree.
