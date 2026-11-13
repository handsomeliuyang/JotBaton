# Security Policy

## Supported versions

Only the latest release receives security fixes.

## Reporting a vulnerability

Use [this repository's private vulnerability reporting form](https://github.com/handsomeliuyang/JotBaton/security/advisories/new) with a description of the issue, steps to reproduce, and the installed version. Do **not** open a public GitHub issue for security problems.

Reports go to the maintainer of this independently maintained project. Include
the release tag and whether you are using the production or development app.

## Scope

In scope:

- The shipped JotBaton app (this repository)
- The Chrome extension (`extension/`)
- The Cloudflare Worker and waitlist API (`website/worker/`)

Out of scope:

- Static presentation copy and assets (`website/public/`), unless they create a security impact
- Third-party dependencies (report upstream, but a heads-up is appreciated if JotBaton's usage is affected)

JotBaton runs with Accessibility and Screen Recording permissions, so reports about ways a malicious process or web page could abuse JotBaton's access are particularly valuable.
