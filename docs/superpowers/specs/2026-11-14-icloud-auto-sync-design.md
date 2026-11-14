# iCloud automatic, incremental sync

Status: agreed 2026-11-14. Supersedes the manual whole-document snapshot flow
(`SnapshotSync`, format v2) for day-to-day sync.

## Problems

1. Sync is manual. The only automatic trigger is reopening the main window, and
   every change to either side ends in "back up" or "restore", which replace the
   whole document.
2. Sync is not incremental. Each publish zips every task and image.
3. Evicted iCloud files dead-lock sync. A large, rarely read archive is the first
   file macOS evicts. `transferState` reports `.waiting` for a non-current
   archive, `.waiting` blocks both publish and apply, and only `apply()` would
   start the archive download. Nothing re-checks when a download finishes.

Apple provides no public API for "Keep Downloaded" (pinning), so the design must
self-heal from eviction rather than prevent it.

## Decisions

- Merge per comment, per field. Never compare whole-document clocks.
  - New comments have UUIDs; adding on two Macs never conflicts.
  - Edits to different fields of one comment both survive (three-way, field level).
  - A true conflict is the same field group changed on both Macs since the last
    merge. The value with the newer `updatedAt` wins, ties broken by device ID, so
    every Mac converges on the same result. The losing value is recorded locally
    and surfaced on that comment; sync is never blocked waiting for a choice.
  - Delete and edit at the same time: delete wins (soft delete, restorable).
  - Hard-pruned history must not resurrect: present in base, absent on one side,
    soft-deleted on the other means pruned.
  - Inbox sessions created independently on two Macs are folded into one.
  - Device-local fields (`activeSessionID`, `claudeCodeSessionId`, `emptySince`,
    `wakeRequestedAt`, orphan bookkeeping, unknown fields) never sync.
- Storage is per device so no two Macs write the same file:

  ```
  iCloud Drive/<app folder>/sync-v3/
    devices/<deviceID>.json    one device's merged entity state plus image manifest
    blobs/<sha256>.blob        content-addressed image files, written once
  ```

  Storage unit (per device) and merge unit (per comment) are deliberately
  different: one shared file produces iCloud conflict copies, and one file per
  comment multiplies eviction.
- Each Mac keeps the last merged copy of every other device under
  `Application Support/.../sync-v3/base/<deviceID>.json` as the three-way base.
- Automatic triggers through one serial coordinator: local change (debounced),
  iCloud folder change, main window shown (pull first), wake/activation, and a
  periodic fallback.
- Eviction: start downloads for every device file and missing blob each cycle,
  wait with a timeout, skip a device whose file is not available yet, and merge
  it later. Missing images never fail a merge.
- Health and strong prompts: a persistent banner in the main window plus a menu
  bar badge when iCloud is unavailable, a download has been stuck for 5 minutes,
  local changes have not synced for 10 minutes, another Mac uses a newer format,
  or a conflict is unresolved. Banners never block editing.
- A rolling set of local restore points is kept before applying remote merges.
- No migration from v2: each Mac starts from its own local data. After a Mac's
  first successful publish, the retired v2 files (`current.json`, timestamped
  archives, per-UUID files) are deleted from iCloud, and leftover local v2
  bookkeeping is removed at launch. The v2 code is gone, and the feature module
  is now `FeatureCloudSync`.
- Menu bar icon: one renderer, one fixed-width canvas per style (Count / Dot /
  Off, always hidden at zero; counts above 99 show `99+`). Monochrome template
  rendering, except an orange warning badge when sync needs attention, which
  takes priority over the dot. A newly arrived task or warning pops once
  (240ms), skipped under Reduce Motion.

## Phases

- P0: fix the eviction dead-lock in v2 (prefetch the archive, wait for downloads,
  recheck automatically, publishing never depends on the old archive).
- P1: merge engine, v3 storage, automatic coordinator.
- P2: health banner, menu bar badge, per-comment conflict prompt, simplified
  settings.
- P3 (evaluation only): CloudKit `CKSyncEngine` under Developer ID signing.
