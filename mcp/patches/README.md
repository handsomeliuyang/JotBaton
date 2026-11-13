# Fork patches

`unlimited-sessions.patch` removes the bundled server's active-session cap and
capacity-based dismissal. Existing session data and lifecycle cleanup remain
compatible with the upstream server.

`scripts/sync-mcp-vendor.sh` applies these patches after building the upstream
bundle. A patch that no longer applies stops the sync for review. The provenance
file records the original bundle, each patch, and the final bundle's SHA-256.

Verify with `node scripts/smoke-mcp-images.mjs`. Its disposable storage fixtures
exercise creation of 64 sessions through Claude Code and Codex without touching
live application data or sending reload notifications.
