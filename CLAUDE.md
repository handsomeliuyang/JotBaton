# Remarc

macOS menu bar app (SwiftUI + AppKit) for contextual commenting on text selections.

- Bundle ID: `com.metepolat.Remarc`
- Min macOS: 14.0 (`MACOSX_DEPLOYMENT_TARGET` in `app/Config/Shared.xcconfig` is the source of truth), Swift 6.0+, LSUIElement (no dock icon)
- Debug log: `/tmp/remarc_debug.log` (Debug builds only; release builds write no log file unless `defaults write com.metepolat.Remarc debugFileLoggingEnabled -bool YES`)
- Data: `~/Library/Application Support/Remarc/comments.json` (legacy fallback: `data.json`)

## PopClip payload

`popclip/Remarc.popclipext/` is copied into the app bundle by a "Copy PopClip Extension" shell script build phase, not Copy Bundle Resources - the Xcode project uses synchronized folder groups, which would flatten a `.popclipext` directory into loose files instead of copying it as a package.

This machine accumulates stale LaunchServices registrations for the `remarc:` scheme from deleted worktrees. When testing the URL scheme, confirm from `/tmp/remarc_debug.log` which bundle actually received it rather than assuming it was this build.

## Build & Relaunch

Build: `cd app && xcodebuild build -workspace Remarc.xcworkspace -scheme Remarc -configuration Debug -derivedDataPath "$(pwd)/DerivedData"`

**MANDATORY: After every successful build, relaunch Remarc.** The user cannot verify changes otherwise.
`pkill -x Remarc; sleep 0.5; open app/DerivedData/Build/Products/Debug/Remarc.app`

Always use `"$(pwd)/DerivedData"` (command substitution), never `"$PWD/DerivedData"` — `$PWD` resolves incorrectly in subshells and worktree contexts.

## Contribution Attribution

Use `Mete Polat <20049378+metedata@users.noreply.github.com>` as the author of repository and automated release commits and as the tagger of annotated tags. Automated commits must use the same identity as committer. Do not add `Co-authored-by` or equivalent attribution for bots, models, agents, or anyone else. Attribute another contributor only when Mete explicitly requests it.

## Git Worktrees — MANDATORY

**All code changes MUST be made in a git worktree, not on main.** Only exceptions: root config files (CLAUDE.md, scripts/, .claude/).

Worktrees go in `.worktrees/` (gitignored). Use `git worktree add .worktrees/<name> -b <branch>`.

## UI Work

When the user describes a UI bug, confirm WHICH specific component/view they mean before editing. Ask clarifying questions if ambiguous.

## Color System

The source map and dependency rules are in [ARCHITECTURE.md](ARCHITECTURE.md).
App composition lives in `Sources/App`, business capabilities in
`Sources/Features`, and reusable mechanisms in `Sources/Core` under
`app/RemarcPackage`. Keep SwiftPM source ownership and architecture tests in sync
when adding or moving files.

Colors/gradients defined in `app/RemarcPackage/Sources/Core/Theme/Colors.swift`. Use `remarc*` tokens (`remarcPrimary`, `remarcSecondary`, `remarcAccent`, etc.) — never hardcode hex values. All tokens take `colorScheme` for light/dark adaptation.

## Copy Style

Never use em dashes (—) in **user-facing text** - UI strings, marketing copy, release notes, anything a user reads. Use hyphens (-) instead.

This rule does NOT extend to developer-facing writing: code comments, these docs, plan and spec files, and commit messages may use em dashes freely.

## Research

When brainstorming or planning, **always do online research** (WebSearch, WebFetch) and **check Context7 docs** for Apple frameworks before proposing approaches. Don't rely on training data alone.
