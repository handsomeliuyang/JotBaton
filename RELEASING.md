# Personal updates and optional public releases

The default workflow is local production compilation on **any eligible Apple Silicon
Mac**, followed by private distribution through iCloud Drive. It is not tied to a
model, hostname, or a particular computer. GitHub compilation is manual opt-in;
pushes and pull requests do not start builds.

## Build hosts and receiving Macs

A production build host needs full selected Xcode 26.2+, Swift 6.2+, Node.js,
an active iCloud Drive, and the existing production signing identity. Check with
`xcodebuild -version` and `xcrun swiftc --version`. It creates both packages from
one exact version commit:

| Personal archive | Runtime |
|---|---|
| `Remarc-<version>-<build>-<date-to-seconds>-arm64.zip` | Apple Silicon, macOS 14+ |
| `Remarc-<version>-<build>-<date-to-seconds>-x86_64.zip` | Intel, macOS 13+ |

The Ventura Intel machine with macOS 13.7.8 / Xcode 14.3.1 / Swift 5.8.1 is a
receiving and runtime test host. It cannot build this dependency graph. Do not
attempt to fix that by lowering dependency pins. Cross-compiling Intel on Apple
Silicon does not establish Ventura runtime compatibility; verify it on Intel after
installation. Cross-builds do not launch an Intel process or require Rosetta.

## Provision production signing once per build host

Keep the existing production certificate **and private key**. The pinned public
fingerprint is in `signing/identities.json`. Do not create a replacement identity,
use ad-hoc signing, reset TCC, or change certificate trust as part of a normal build.

If an original private backup is available:

```bash
python3 scripts/setup-production-signing.py import-p12 /absolute/private/path/identity.p12
```

Otherwise migrate the existing GitHub Actions Secrets without exposing plaintext:

```bash
brew install age
python3 scripts/setup-production-signing.py prepare-migration
```

This prints a dispatch command containing **only a public age recipient**. Run that
command on the build host. The one-time `signing-migration.yml` workflow runs on
Ubuntu (no macOS runner/build), encrypts the existing P12/password in memory, and
uploads only `production-signing.age` with one-day retention. Download that artifact
from the exact run onto the same destination Mac, then:

```bash
python3 scripts/setup-production-signing.py import-migration /absolute/path/production-signing.age
```

The destination Mac decrypts in memory, checks the certificate fingerprint, and
imports into `~/Library/Keychains/RemarcProduction.keychain-db`. A private P12 is
written only to a protected temporary directory during import and is removed on
exit. Passwords are entered interactively and are never logged. The recipient key
is deleted after successful import; delete the encrypted Actions artifact afterward.
Never send a private key/password in workflow inputs. Never decrypt or import on an
installation-only Intel Mac. Keep an encrypted offline recovery backup separately.

The dedicated keychain stays unlocked for up to six hours. Unlock it with Keychain
Access before later builds if needed. `REMARC_PRODUCTION_KEYCHAIN` may select another
dedicated local keychain; repositories and iCloud locations are rejected. Local
signing selects the pinned identity without exporting private material. Keychain
Access may request permission for the local publisher to sign its update description. Other
receiving Macs need only the signed application, not this keychain.

## Publish a personal update

Commit accepted source changes on `main` first. On an eligible build host:

```bash
python3 scripts/publish-icloud-update.py
# Or explicitly choose a new version and build:
python3 scripts/publish-icloud-update.py --version 1.2.23 --build-number 42
```

The script:

1. Checks host/toolchain/signing/iCloud prerequisites before modifying versions.
2. Increments marketing/build versions (or validates explicit increases) and creates
   `Release vX.Y.Z` using `liuyang <40610243@qq.com>`. This version commit is local;
   push it separately to synchronize source. It never dispatches Actions.
3. Runs the standard and Ventura Swift suites locally, then clean-builds Intel and
   ARM Release apps. Dependencies use the checkout's verified PackageCache and pins.
   Native ARM builds relaunch their exact output; Intel cross-builds are statically
   checked and await runtime validation on an Intel host.
4. Builds an architecture-matched native installation helper into each signed app;
   checks every bundled Mach-O deployment floor, production identity, version/source
   and packaged MCP behavior; retains both immutable ZIPs locally.
5. Signs `latest.json` with the existing production private key. It includes a
   signed payload containing version, build, source commit, publication time,
   architectures, minimum OS versions, names, sizes and SHA-256 checksums.
6. Places packages under `iCloud Drive/Remarc/Updates`, waits for both uploads,
   atomically commits the signed description and confirms its upload. The previous
   known package pair is cleaned only afterward; managed abandoned uploads older than
   one day are cleaned after a successful publication when they are not uploading. Data snapshots/current.json and
   unknown files are not removed. Concurrent description changes abort publication.
7. Verifies, installs and relaunches `/Applications/Remarc.app` from its native ARM
   archive, backing up the previous matching app/data without re-signing.

Outputs remain at `app/DerivedData/PersonalReleases/v<version>-<build>/`, including
both ZIPs and checksums. An iCloud timeout does not justify claiming publication
success. Resume a failed build/upload from the exact clean version commit with:

```bash
python3 scripts/publish-icloud-update.py --resume
```

Successful per-commit tests and immutable archives can be reused, but package
signatures/provenance are checked again. Never reuse a version/build for different
source. If code must change after a failure, commit it and choose a new version.

## Receiving and installing updates

A new computer logs into the same iCloud account, enables iCloud Drive and manually
installs its native ZIP once into `/Applications`. It must authorize directory and
macOS permissions on that computer. Existing older app versions without this updater
also need this one manual installation. Signing identity continuity does not grant
permissions automatically on another Mac.

Production Remarc reads `Remarc/Updates` independently of snapshot synchronization.
It checks after launch, periodically, on activation, or through **Check for Updates**
in the About settings/right-click menu. A newer supported build prompts **Install
Update**, **Later**, or **Skip This Version**; manual checks can revisit skipped
versions. A delayed iCloud download shows a waiting state with cancellation.

Installation copies out of iCloud into a local private stage and verifies the
signed description, archive hash/size, pinned production code signature, source,
version, OS and architecture. The bundled helper prepares a verified replacement
before the app quits, then waits for the old process to finish. The app refuses to
quit if pending data cannot be saved. The helper backs up app/data, replaces the
bundle, relaunches and checks that the new process remains alive. Failed launches
restore the previous app/data; the failed data is retained inside that one backup.
No Python, development tools or signing private key are needed on receiving Macs.

One previous upgrade backup is retained under
`~/Library/Application Support/Remarc Update Backups/Previous/`. To recover manually,
quit only production Remarc and restore `Remarc.app` from that backup to
`/Applications/Remarc.app`. Preserve the `user-data` backup before changing local
data. Never restore production backups into Remarc Dev.

Production identity/storage remains `com.metepolat.Remarc`,
`Application Support/Remarc`, and `iCloud Drive/Remarc`. Dev remains independently
signed as `com.metepolat.Remarc.dev`, with `Remarc Dev` storage and DEV visuals; it
does not consume production update packages. Packages retain the existing private
self-signed certificate and are not Apple-notarized.

## Optional GitHub public release

Only when explicitly requested, manually dispatch `.github/workflows/release.yml`
on `main` with a new version/build and notes. It owns its version commit/tag and
builds both packages from one commit, tests both profiles and native host behavior,
verifies signatures and publishes both assets/checksums to one Release:

- `Remarc-Ventura-x86_64.zip`
- `Remarc-Apple-Silicon-arm64.dmg`
- `INSTALL.txt`, `SHA256SUMS`

CI, Development and standalone architecture workflows are also manual only. Never
silently use them when a local build host is missing. Workflow signing may still
use `REMARC_SIGNING_P12_BASE64` and `REMARC_SIGNING_P12_PASSWORD` in Actions Secrets.

For a failed public release, rerun all jobs only while main remains the exact
version commit. If source changes, choose a new version/build. Never move a tag or
overwrite published assets. Inspect and recover a verified draft rather than
blindly replacing it. If publication succeeded but later verification failed,
verify the existing published assets instead of republishing. A completed public
release requires the Release URL and verified assets, followed by installation and
relaunch of the current machine's native package. Actions artifacts alone do not
constitute a public Release.
