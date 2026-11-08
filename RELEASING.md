# Releasing this Remarc fork

This fork is maintained at `handsomeliuyang/Remarc`. The **Release** workflow
publishes both supported architectures in one GitHub Release:

| Asset | Target | Configuration |
|---|---|---|
| `Remarc-Ventura-x86_64.zip` | Hackintosh / Intel, macOS 13+ | Release |
| `Remarc-Apple-Silicon-arm64.dmg` | M5 Pro / Apple Silicon, macOS 14+ | Release |
| `Remarc-Ventura-Install-Tools.zip` | Local Intel signing helper and dependencies | — |
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
Always specify `-R handsomeliuyang/Remarc`: this checkout also has an upstream remote.

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
   `vX.Y.Z` tag with the same liuyang identity, and uploads all five assets to a
   draft Release. It verifies names/sizes and downloads the draft assets to
   compare their bytes and checksums before publishing.
6. Publishes the Release as latest and downloads/verifies the published assets
   again. Deliver the Release URL, not just an Actions run link.

Only `GITHUB_TOKEN` with `contents: write` is required by preparation and
publishing. Builders have read-only repository access. This process does not
use upstream Developer ID, notarization, Sparkle, Gist or website credentials.
It does not publish an upstream appcast or website update.

## Signing and installation

These packages are ad-hoc signed and **not Apple-notarized**. GitHub Release
publication does not change that. If first launch is blocked, follow
[Apple's Open Anyway instructions](https://support.apple.com/en-us/102445).
Both packages disable upstream automatic updates; install future versions manually.

### Hackintosh / Ventura Intel

1. Download and verify the release assets with `shasum -a 256 -c SHA256SUMS`.
2. Extract the app ZIP with Archive Utility or `ditto` to preserve the bundle.
3. Extract `Remarc-Ventura-Install-Tools.zip` and run:

```bash
bash /absolute/path/ventura-install-tools/scripts/sign-ventura-local.sh /absolute/path/Remarc.app
```

The helper creates/reuses a local signing identity in the dedicated keychain
under `~/Library/Application Support/RemarcLocalSigning` and adds a code-signing
trust entry for the current user. Keep private key material outside the repo.
An existing source checkout can use `scripts/sign-ventura-local.sh` directly.

4. Quit Remarc, back up the installed app and user data, replace
   `/Applications/Remarc.app` with the re-signed app, and relaunch that path.
   Preserve `~/Library/Application Support/Remarc`; do not reset TCC routinely.
5. Verify the installed version, signature and running process. Keep the old
   app backup for rollback. Local delivery is not complete until this relaunch.

Xcode 14 on Ventura cannot compile the locked Swift 6 dependencies. Build in
Actions. Standalone Intel development builds default to Debug; use
`REMARC_BUILD_CONFIGURATION=Release bash scripts/build-ventura.sh` on a compatible
Intel build host for the release configuration.

### M5 Pro / Apple Silicon

For a stable local signing identity across updates, copy the app from the DMG
to a writable directory and run `bash scripts/sign-local.sh /absolute/path/Remarc.app`
from a source checkout (or the same script in the installation tools ZIP), then
install it at `/Applications/Remarc.app`. Reuse the generated identity on future
updates. The first switch from an upstream or ad-hoc signature may require granting
Accessibility and Screen Recording again. This is local signing, not notarization.

Open the DMG, drag `Remarc.app` into Applications, and open it there. No Rosetta
is needed. The standard speech backends are retained; voice features require
macOS 26. Grant required permissions when prompted. The workflow validates
startup on an Apple Silicon runner; this does not imply physical M5 Pro testing.

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
