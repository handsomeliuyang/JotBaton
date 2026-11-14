# JotBaton positioning and brand compatibility

The product is a lightweight macOS inbox for AI collaboration. It captures
passing ideas and product feedback with enough context to hand them to an AI
tool, then lets the user clear completed work from the active list.

**随手记录想法与反馈，带着上下文交给 AI，做完就清掉。**

The maintainer confirmed this positioning and selected **JotBaton** with its
independently drawn baton icon on 2026-11-13. “Jot” means a quick note; “baton”
expresses handing the work to an AI tool.

## Everyday workflow

1. Capture a rough thought or product feedback without interrupting the current activity.
2. Keep relevant text, screenshots, and web context together; add detail when preparing the handoff.
3. Copy individual records or a session to Codex, Claude Code, or another external AI tool.
4. Manually mark completed work Resolved and use status filters to focus on pending tasks.

Completion and deletion are separate operations. Deletion continues to use the
existing searchable History behavior. The brand transition does not change these
operations or add automatic deletion.

## Future AI handoff

A future MCP integration may allow the user to copy references to selected
records, let an agent retrieve their context, and let it update the task statuses
after processing them. This extends the same capture and handoff workflow.
Implementation, transport, link format, and authorization remain future work.
Current product copy must describe copying and manual completion accurately.

## Name and artwork

**JotBaton** is the product name. The mark combines an open capture frame with
two diagonal baton strokes. Production and development have separate application
and monochrome menu bar icons; the development application carries a DEV badge,
and its menu bar icon includes an additional dot.

[Selected source vector](brand-proposals/jotbaton-app-icon.svg) ·
[Initial naming comparison](brand-proposals/overview.png)

`swift scripts/generate-development-icons.swift /absolute/repo/path --all`
reproduces the installed assets for both channels, the browser extension, and
PopClip. Omitting `--all` regenerates DEV assets only. The artwork uses the
existing theme palette. The initial naming comparison remains an archive of the
three proposals, not the final selection state.

Initial exact-name web searches found no JotBaton matches on 2026-11-13. This is
not a claim of trademark, domain, or marketplace availability. See
[Apple's app icon guidance](https://developer.apple.com/design/human-interface-guidelines/app-icons).

## Application identity and existing installations

Display names and application filenames use the new brand. Persistent identity
and local storage keep their existing values; iCloud sync folders use the new brand:

| Setting | Production | Development |
| --- | --- | --- |
| App | JotBaton.app | JotBaton Dev.app |
| Executable | Remarc | RemarcDev |
| Bundle identifier | com.metepolat.Remarc | com.metepolat.Remarc.dev |
| Local data directory | Application Support/Remarc | Application Support/Remarc Dev |
| iCloud directory | JotBaton | JotBaton Dev |
| URL scheme | remarc | remarc-dev |
| Browser port | 9274 | 9275 |

`AppIdentity.directoryName` is independent of `displayName`, keeping existing
production and development local data paths unchanged. `AppIdentity.cloudDirectoryName`
selects `JotBaton` or `JotBaton Dev` for iCloud sync independently. The maintainer
confirmed this cloud-folder change on 2026-11-14; old cloud folders and backups
are not imported, migrated or used as fallbacks. Bundle identifiers, executables,
URL schemes, browser ports, defaults, signing identities, and the EdDSA key remain
stable. Changing a bundle identifier is outside this branding change because
settings, permissions, keychain access, and routing depend on it. See
[Apple's bundle identifier guidance](https://developer.apple.com/documentation/xcode/changing-the-bundle-identifier).

The installer verifies the matching legacy app's signature and identity, backs up
that app and the original data directory, then installs under the new filename.
A failed installation restores the prior filename. Production and development
stay isolated. The application update backup records the app's actual filename.

Published package filenames keep the `Remarc-` prefix as a compatibility contract;
newly built packages contain JotBaton.app. Historical releases are immutable.

Local builds remain Development only. Production delivery continues through the
manual GitHub Release workflow; keep existing releases and signed assets intact.
This transition does not implement MCP, redesign task handling, or migrate data
between channels.

## Independent GitHub repository

The repository is maintained independently from `metedata/Remarc`. Keep the
original MIT copyright and permission notice, commit history, and source credit.
Only `origin` points to `git@github.com:handsomeliuyang/JotBaton.git`. The local
GitHub CLI's default repository is `handsomeliuyang/JotBaton`, so unqualified
commands target this project.

The GitHub repository was renamed in place to
[handsomeliuyang/JotBaton](https://github.com/handsomeliuyang/JotBaton), preserving
its repository ID. Repository renaming and leaving the fork network are separate
operations. On 2026-11-14 the maintainer authorized **Leave fork network**,
and GitHub detached JotBaton in place. The repository is now standalone;
`fork` is false and `parent` and `source` references are absent.

The release command, workflow repository guard, GitHub API discovery, Sparkle
feed URLs, package verification, and current documentation target JotBaton. The
new release selector accepts exact release URLs under either this owner's
JotBaton or legacy Remarc repository name and requires asset URLs to match the
same repository as their release. It continues to reject other repositories,
lookalike names, insecure URLs, and mixed repository URLs.

Old published apps validate the old repository path exactly; GitHub's redirect
cannot satisfy that application check. They require one manual upgrade to a
rebranded production package after its publication. This change does not publish
a production release. Do not reuse the old Remarc repository name while older
links and installations rely on its redirects. See
[GitHub's repository rename guidance](https://docs.github.com/en/repositories/creating-and-managing-repositories/renaming-a-repository).

The GitHub description and homepage now reflect this project's copy-based
workflow. Private vulnerability reporting is enabled for this repository, and
the security policy uses that private form. Upstream sponsorship links have
been removed from the active README and funding configuration.

At the initial inventory the fork had 20 published releases with 86 assets,
three Actions Secret names required by the publishing workflow, no child forks,
and no stars or watchers. No secret values were read or exported. Existing
release assets and publishing configuration must be preserved.

Before detachment, all Git refs were saved in a verified standalone Git bundle,
and all 86 release assets (398.3 MiB) were backed up outside the checkout.
Sixty-six payload files matched the published SHA256SUMS across all 20 releases.
The local backup is under `~/Library/Application Support/JotBaton Maintenance/`.
It contains no exported secret values.

After detachment, the repository ID, branches and tags, all 20 releases and
86 assets, the three Actions Secret names and their creation/update timestamps,
Actions permissions, and private vulnerability reporting matched the saved
inventory. Download counters were excluded because making the backups increments
them. GitHub's fork relationship and upstream synchronization controls are now
removed. Commit history, original attribution, and release URLs remain in place.
Detachment is permanent. See
[GitHub's fork detachment guidance](https://docs.github.com/en/pull-requests/how-tos/work-with-forks/detaching-a-fork).
