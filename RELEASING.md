# GitHub releases and local development

Local compilation is for **Remarc Dev only**. Production packages are built, tested,
signed and published by the manually dispatched **Release** workflow on GitHub.
Pushes and pull requests never start compilation. Software releases no longer use
iCloud; production and development iCloud data snapshots remain independent.

## Local development

Use a supported Xcode 26.2+ / Swift 6.2+ toolchain:

```bash
bash scripts/dev-preview.sh
# Explicitly include the current profile's Swift suite when needed:
bash scripts/dev-preview.sh --with-tests
```

The default builds only the current host architecture in Debug, uses the shared
committed development identity, installs `/Applications/Remarc Dev.app`, and
relaunches that exact app. It does not run the full test suite. `run-local.sh`
retains its Command Line Tools / macOS 26.5 SDK preview path. UI layout changes
require a clean build; the Xcode builders already clean-build.

Local Release build, packaging and signing entry points fail before performing
production work. Production signature verification and installation of downloaded
GitHub packages remain available locally. No local production keychain is needed.
Existing keychains, historical iCloud update files and app/data backups are not
removed automatically.

Ventura with Xcode 14 / Swift 5.8 is an installation/runtime verification host. Do
not downgrade dependencies or install unsupported toolchains there. Download the
Intel package from GitHub instead.

## Publish a production release

Commit accepted changes to `main` and push `origin/main`. Manually dispatch
`.github/workflows/release.yml` with a new `X.Y.Z`, an increased integer build
number and release notes. For example:

```bash
gh workflow run release.yml -R handsomeliuyang/Remarc --ref main \
  -f version=1.2.28 -f build_number=47 \
  -f release_notes='Check for updates through GitHub Releases.'
```

The workflow:

1. Checks release inputs, provenance validation, local build guards and browser
   extension tests before changing versions.
2. Creates `Release vX.Y.Z` with author and committer
   `liuyang <40610243@qq.com>`, pushes it to `main`, then gives every job that exact
   commit. No bot/model coauthor attribution is added.
3. Builds Intel (macOS 13+) and ARM (macOS 14+) Release packages on native GitHub
   runners with Xcode 26.2. Full Swift suites run for **both standard and Ventura
   profiles** on ARM runners with Metal; compatibility tests also run on Intel.
   A production release cannot skip these suites.
4. Uses the existing pinned production certificate from Actions Secrets
   `REMARC_SIGNING_P12_BASE64` and `REMARC_SIGNING_P12_PASSWORD`. Both packages use
   the same identity. Signing uses temporary isolated keychains; never rotate the
   identity, fall back to ad-hoc signing, expose private material or change trust.
5. Verifies packaged MCP behavior, all bundled Mach-O architectures and deployment
   floors, code signatures, version/build/source and GitHub update metadata.
6. Creates a new annotated tag and draft Release, verifies uploaded assets and
   checksums, publishes the Release, then downloads and checks the published bytes.

Published assets:

- `Remarc-Ventura-x86_64.zip`
- `Remarc-Apple-Silicon-arm64.dmg`
- `INSTALL.txt`
- `SHA256SUMS`

The production certificate is private/self-signed; these builds are not
Apple-notarized. Never move tags or overwrite published assets. Actions artifacts
alone are not a production Release.

## Application update checks

Production reads the public API for
`handsomeliuyang/Remarc/releases/latest`. No token, GitHub login or iCloud folder
authorization is required. Only published, non-prerelease versions are accepted.
Versions are compared numerically and older/equal releases are never offered as an
upgrade. A compatible native installer must exist in that exact Release.

Checks run shortly after launch and at most once every six hours in the background;
**Check for Updates** in the menu or About checks immediately. Manual checks report
when the app is up to date or when GitHub/network access fails. New versions offer
**Download from GitHub**, **Later** and **Skip This Version**. Download opens the
matching installer URL in the browser. Quit Remarc and replace the app in
Applications manually. The updater does not replace/relaunch the app itself.
Development does not consume production updates.

Application update settings are separate from comment/image/snapshot iCloud sync.
Only obsolete software-update authorization and skip/defer preferences are retired.
Existing production data, snapshots and permissions are retained. An old installed
version that only understands iCloud updates needs one manual upgrade to this version.

## Verified installation after publication

Download the assets from the exact Release and run in that directory:

```bash
shasum -a 256 -c SHA256SUMS
```

On Apple Silicon, mount the ARM DMG read-only. On Intel, extract the Intel ZIP with
Archive Utility or `ditto`. From this checkout, verify and install the extracted app:

```bash
python3 scripts/install-app.py /absolute/path/Remarc.app --channel production --keep-one-backup
```

The installer verifies the pinned signature and native architecture, backs up the
previous app and data under `Application Support/Remarc Update Backups/Previous`,
installs without re-signing, and relaunches `/Applications/Remarc.app`. Verify the
running version/build matches the Release. Never launch an Intel package on ARM or
claim Ventura runtime verification from an ARM host. Intel macOS 13 still needs its
own installation/runtime verification.

Do not routinely reset macOS permission grants. `--reset-permissions` is reserved
for an explicitly requested certificate migration. Production and development have
separate Bundle IDs, permissions, local data and iCloud directories; do not copy
or merge between them.

## Recovery

If a release fails before publication, rerun all jobs only while `main` remains the
exact version commit. If source must change, choose a new version/build. Inspect
and recover an existing verified draft instead of creating a duplicate. If a release
was published but final verification failed, verify its existing assets rather
than republishing or replacing them.

A completed release requires a public Release URL and both verified architecture
assets. When local installation is requested, also install and relaunch the native
package and confirm its running version. The old local/iCloud publication and
signing-migration workflows have been removed.
