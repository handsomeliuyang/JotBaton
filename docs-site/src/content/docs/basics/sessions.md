---
title: Sessions & the Inbox
description: Group Remarc comments into sessions, switch between them from the sidebar, and understand the permanent Inbox.
---

Sessions group related comments, such as one review pass or one agent conversation. There is no fixed limit on active sessions.

## The Inbox

The **Inbox** is a permanent session that catches comments not filed anywhere else. It cannot be renamed or deleted, and it is never auto-deleted.

## The session sidebar

The session sidebar sits beside the comment list in the [popover](/basics/menu-bar-and-popover/). Each row shows a session's name and comment count for the selected status filters. Click a row to switch to that session. The Inbox comes first, followed by pinned sessions and ordinary sessions.

- **Create**: click the **+** button. New sessions are named automatically (Session A, Session B, ...) and scroll into view ready to rename.
- **Find**: search by name at the top of the sidebar, or scroll when the list exceeds the available height. The search field and **+** button remain visible.
- **Pin**: right-click a row and choose Pin session to keep it near the top and protect it from empty-session cleanup.
- **Rename**: double-click a row, or right-click it and choose Rename.
- **Delete**: right-click a row and choose Delete.

When saving a comment, the composer's session picker chooses which session it goes to. Move an existing comment between sessions from its card actions - see [statuses and history](/basics/statuses-and-history/).

## Agent-created sessions

Agent integrations create sessions of their own, so an agent conversation gets a matching Remarc session. Creating one does not hide older sessions to make room. These carry a small origin badge next to the session name: the Claude logo for Claude Code, the Codex logo for Codex, or OMP's gradient pi mark for OMP. See [agent integrations](/agents/overview/).

## Auto-delete inactive sessions

Settings has an **Auto-delete inactive sessions** toggle, off by default. When enabled, sessions with no recent activity are deleted after a chosen interval, from After 30 min to After 24 hours (default: After 4 hours). Their comments move to History, where they can be restored.

Only the Inbox is exempt. Any new or updated comment counts as activity and resets a session's timer, but a session left untouched past the interval is deleted even if it is the current one or still has unresolved comments.
