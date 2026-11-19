---
title: Statuses & history
description: Track Remarc comment statuses from Open to Resolved, act on individual cards, and restore deleted comments from History.
---

Every comment has a status that tracks where it is in your workflow, and deleted comments go to a searchable History instead of disappearing.

## Statuses

A comment is always in one of five statuses:

| Status | Color | Meaning |
| --- | --- | --- |
| Open | Gray | New, nothing has happened yet |
| Reusable | Blue | Included in every Copy and Start; kept when tasks are batch completed |
| In-Progress | Amber | Being worked on |
| On Hold | Mauve | Set aside and skipped by Copy and Start |
| Resolved | Green | Done |

Each card shows a status dot in its top-right corner. Hover to expand it into a labeled pill, click it to change the status yourself.

Reusable is useful for prompts, release checklists, or collaboration guidelines you need over several days. Starting copies the same comment without changing its status. Batch completion and export cleanup preserve it. Choose On Hold to stop including it temporarily, or manually choose Resolved when you are finished. Reusable does not change the comment’s sort position.

## Card actions

Hover a card to reveal its actions:

| Action | What it does |
| --- | --- |
| Copy | Copy the comment to the clipboard |
| Copy and Start | Copy Open, Reusable, or In-Progress comments; only Open comments become In-Progress |
| Edit | Open the comment in the editor |
| Send to webhook | Post the comment to a [webhook](/automation/webhooks/); shown only when a webhook is enabled |
| Move to session | Move the comment to another session, or a new one |
| Delete | Delete after confirmation, with an Undo toast |

Hovering also reveals the comment's short ID; click it to copy. Agents use these IDs to reference comments.

## History

Deleted comments move to History: click the clock icon in the popover header. From there, restore a comment to the current session or permanently delete it. History is searchable and sortable by date.

Two settings control cleanup:

- **Delete resolved**: automatically delete resolved comments. Never (default), Immediately, After 15 min, After 1 hour, or After 1 day.
- **History retention**: how long History keeps deleted comments. 1 day (default), 1 week, or 1 month.

## Bulk actions

The footer’s **Copy All**, **Copy and Start**, and **Complete in-progress tasks** act only on comments shown by the current status filters, including comments further down the scrollable list. Hidden comments are neither copied nor updated. Copy and Start still skips On Hold and Resolved comments; completion affects only visible in-progress tasks and offers Undo. These three buttons remain unavailable while searching or viewing History. The More menu keeps its session-wide actions: **Resolve All**, which completes other unfinished comments while preserving Reusable context, and **Delete All**. These two actions ask for confirmation. Explicit deletion can still remove Reusable comments.
