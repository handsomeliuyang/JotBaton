#!/bin/bash
# Warm binary artifacts serially. SwiftPM < 6.4 has a cold-cache download race:
# https://github.com/swiftlang/swift-package-manager/issues/10138
set -euo pipefail
PACKAGE="${1:?Usage: resolve-packages.sh /absolute/package/path}"
RESOLVE_LOG="$(mktemp -t remarc-resolve)"
trap 'rm -f "$RESOLVE_LOG"' EXIT
for attempt in 1 2 3; do
  if swift package --package-path "$PACKAGE" resolve >"$RESOLVE_LOG" 2>&1; then
    cat "$RESOLVE_LOG"
    exit 0
  else
    status=$?
  fi
  cat "$RESOLVE_LOG" >&2
  if [[ "$attempt" -lt 3 ]] && grep -q 'failed downloading' "$RESOLVE_LOG" &&
      grep -Eq 'already exists in file system|doesn.t exist' "$RESOLVE_LOG"; then
    echo "Retrying only the known SwiftPM binary-artifact cache race (attempt $attempt)" >&2
  else
    exit "$status"
  fi
done
