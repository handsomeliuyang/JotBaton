#!/bin/bash
# Build JotBaton Dev for this Mac only, install it and launch it.
#
# Supported toolchains build locally through run-local.sh. Unsupported hosts
# receive an error; this command never dispatches Actions.
# Usage: scripts/dev-preview.sh [--with-tests]
set -euo pipefail
REMARC_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REMARC_ROOT"

SKIP_TESTS=true
for argument in "$@"; do
    case "$argument" in
        --cloud) echo "Cloud previews must be explicitly dispatched from Actions." >&2; exit 2 ;;
        --with-tests) SKIP_TESTS=false ;;
        *) echo "Unknown option: $argument" >&2; exit 2 ;;
    esac
done

# Same capability check as run-local.sh: Xcode 26.2+, or the CLT 26.5 SDK.
can_build_locally() {
    local xcode_version
    xcode_version="$(xcodebuild -version 2>/dev/null | head -n 1 | awk '{print $2}')" || true
    if python3 - "${xcode_version:-0}" <<'PYTHON'
import sys
raise SystemExit(0 if tuple(map(int, sys.argv[1].split('.'))) >= (26, 2) else 1)
PYTHON
    then
        return 0
    fi
    [ -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk ]
}

if can_build_locally; then
    if [ "$SKIP_TESTS" = false ]; then
        bash "$REMARC_ROOT/scripts/resolve-packages.sh" "$REMARC_ROOT/app/RemarcPackage"
        xcrun swift test --package-path "$REMARC_ROOT/app/RemarcPackage" --cache-path "$REMARC_ROOT/app/DerivedData/PackageCache"
    fi
    echo "Building JotBaton Dev locally."
    exec bash "$REMARC_ROOT/scripts/run-local.sh"
fi

echo "This Mac cannot compile the current package locally. Use a supported Apple Silicon Mac for builds." >&2
echo "Cloud builds are manual only; this command never dispatches GitHub Actions." >&2
exit 1
