---
description: Publish Remarc through GitHub with commit-derived Chinese notes and a pinned source
argument-hint: "[patch|minor|major|X.Y.Z] [--dry-run]"
---

# Release Remarc

Repository: `handsomeliuyang/Remarc`. Read `AGENTS.md` and `RELEASING.md`.
Arguments: `$ARGUMENTS`. Default increment: `patch`.

1. Read the current version/build and show it in the conversation. Preview with
   `python3 scripts/release.py <increment-or-version> --dry-run`. Only accepted
   commits on clean `main`, already pushed to `origin/main`, can be published.
   Do not automatically commit unrelated/unreviewed edits or silently push them.
2. Use the preview's published baseline and exact source SHA. Review the commit
   subjects/bodies/diffs as necessary. Turn entries into concise Chinese bullets
   grouped by additions, fixes, performance, breaking changes and other changes.
   Preserve commit links, removals, migration requirements and significant
   maintenance changes; do not invent improvements or ignore legacy subjects.
   Include the complete compare link. Use `###` headings and `- ` bullets.
3. Write the exact Markdown notes to a temporary file outside the repository.
   Preview again with `--notes-file /absolute/path/notes.md --source-sha <full-SHA>`
   and show current/target version/build, commit range and notes. A source change
   requires a fresh review. `feat` does not silently change the default patch
   increment; flag breaking changes and recommend a deliberate version choice.
4. If `--dry-run` was requested, stop after the preview. An explicit request to
   publish (including invoking `/release` without `--dry-run`) authorizes dispatch;
   do not repeatedly ask for confirmation once the exact action is authorized.
   A request only to implement/fix the release command does not authorize delivery.
5. Dispatch the same version, source and notes using:

   ```bash
   python3 scripts/release.py <increment-or-version> --publish \
     --source-sha <full-SHA> --notes-file /absolute/path/notes.md
   ```

   Do not locally bump versions, build/sign production packages or create tags.
   GitHub owns `chore(X.Y.Z): release vX.Y.Z`, version/build and changelog updates.
   An authentication/API error is a stop, never evidence that a release is absent.
6. Identify the newly dispatched run using repository, `release.yml`, event
   `workflow_dispatch`, full source SHA and dispatch time; inspect candidates with
   `gh run list -R handsomeliuyang/Remarc --workflow release.yml --commit <full-SHA>
   --event workflow_dispatch --json databaseId,headSha,createdAt,status,url`.
   Watch that exact run ID with `gh run watch <ID> -R handsomeliuyang/Remarc`.
   Do not use an unscoped watcher or select an unrelated older run. Dispatch
   acceptance and Actions artifacts do not mean publication succeeded.
7. Check the public Release for the exact version, both native packages,
   `INSTALL.txt`, both architecture appcasts and `SHA256SUMS`, plus the workflow's
   downloaded draft/public verification. Report the public URL, version/build and
   release source commit. For failure recovery follow `RELEASING.md`: rerun only
   the exact version commit, inspect existing drafts, never move tags or overwrite
   published assets. Resume keeps the committed notes unchanged.
8. Install on this Mac only when requested. Use the published native package and
   `scripts/install-app.py --channel production`, retaining checksum/signature/
   architecture checks, backup and matching-channel relaunch. Do not add local
   regression suites or post-install diagnostics/UI walkthroughs for delivery.

Both standard/Ventura full Swift suites, Intel compatibility checks, extension
tests remain mandatory in GitHub. Both packages use the
same pinned production signing identity. Sparkle uses the repository's signed
architecture feeds. Apple notarization, Gist appcasts, upstream repositories and
iCloud software publishing are not part of this flow.
