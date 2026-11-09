#!/bin/bash
# Build Remarc Dev for this Mac only, install it and launch it.
#
# Hosts that can compile the Swift 6 package build locally through
# run-local.sh. Hosts that cannot (Ventura with Xcode 14) build only their own
# package in the cloud Development workflow, then download, verify, install
# and relaunch it here. Production delivery still goes through Release.
#
# Usage: scripts/dev-preview.sh [--cloud] [--with-tests]
#   --cloud       Use the cloud build even when this Mac can build locally.
#   --with-tests  Run the Swift test suites in the cloud build (skipped by default).
set -euo pipefail
REMARC_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REMARC_ROOT"

FORCE_CLOUD=0
SKIP_TESTS=true
for argument in "$@"; do
    case "$argument" in
        --cloud) FORCE_CLOUD=1 ;;
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

if [ "$FORCE_CLOUD" = 0 ] && can_build_locally; then
    echo "Building Remarc Dev locally."
    exec bash "$REMARC_ROOT/scripts/run-local.sh"
fi

case "$(uname -m)" in
    x86_64)
        TARGET=ventura-intel
        ARTIFACT=Remarc-Dev-Ventura-x86_64
        PACKAGE="Remarc Dev-Ventura-x86_64.zip"
        ;;
    arm64)
        TARGET=apple-silicon
        ARTIFACT=Remarc-Dev-Apple-Silicon-arm64
        PACKAGE="Remarc Dev-Apple-Silicon-arm64.dmg"
        ;;
    *) echo "Unsupported architecture: $(uname -m)" >&2; exit 1 ;;
esac

# An exported token that is invalid shadows a valid keyring login.
GH=(gh)
if ! gh api user --silent >/dev/null 2>&1; then
    GH=(env -u GITHUB_TOKEN gh)
    "${GH[@]}" api user --silent >/dev/null || { echo "gh is not authenticated; run: gh auth login" >&2; exit 1; }
fi

# The cloud builds the pushed branch head, so local edits would silently be missing.
BRANCH="$(git rev-parse --abbrev-ref HEAD)"
if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
    echo "Commit and push your changes first: the cloud build only sees the pushed branch." >&2
    exit 1
fi
git fetch --quiet origin "$BRANCH"
HEAD_SHA="$(git rev-parse HEAD)"
if [ "$HEAD_SHA" != "$(git rev-parse "origin/$BRANCH")" ]; then
    echo "Push $BRANCH first: local HEAD differs from origin/$BRANCH." >&2
    exit 1
fi

echo "Cloud build of $TARGET at ${HEAD_SHA:0:7} (tests skipped: $SKIP_TESTS)."
DISPATCHED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
DISPATCH_OUTPUT="$("${GH[@]}" workflow run development.yml --ref "$BRANCH" \
    -f target="$TARGET" -f skip_tests="$SKIP_TESTS" 2>&1)"
RUN_ID="$(printf '%s\n' "$DISPATCH_OUTPUT" | grep -Eo 'actions/runs/[0-9]+' | head -n 1 | cut -d/ -f3)" || true
# Older gh releases don't print the run URL; find the run this dispatch created.
for _ in $(seq 1 20); do
    [ -n "$RUN_ID" ] && break
    sleep 3
    RUN_ID="$("${GH[@]}" run list --workflow development.yml --branch "$BRANCH" --event workflow_dispatch \
        --limit 10 --json databaseId,headSha,createdAt \
        --jq "[.[] | select(.headSha == \"$HEAD_SHA\" and .createdAt >= \"$DISPATCHED_AT\")][0].databaseId // empty")"
done
[ -n "$RUN_ID" ] || { echo "Could not find the dispatched Development run." >&2; exit 1; }
echo "Waiting for run $RUN_ID."
"${GH[@]}" run watch "$RUN_ID" --exit-status --interval 20 >/dev/null || {
    echo "Development run $RUN_ID failed:" >&2
    "${GH[@]}" run view "$RUN_ID" --log-failed 2>&1 | tail -n 40 >&2
    exit 1
}

# Downloads are kept per run so earlier previews remain available.
DOWNLOAD_DIR="$REMARC_ROOT/app/DerivedData/DevPreview/$RUN_ID"
rm -rf "$DOWNLOAD_DIR"
mkdir -p "$DOWNLOAD_DIR"
"${GH[@]}" run download "$RUN_ID" --name "$ARTIFACT" --dir "$DOWNLOAD_DIR"
(cd "$DOWNLOAD_DIR" && shasum -a 256 -c SHA256SUMS)

APP_DIR="$DOWNLOAD_DIR/app"
mkdir -p "$APP_DIR"
if [ "$TARGET" = ventura-intel ]; then
    ditto -x -k "$DOWNLOAD_DIR/$PACKAGE" "$APP_DIR"
else
    MOUNT_POINT="$(mktemp -d)"
    hdiutil attach -nobrowse -readonly -mountpoint "$MOUNT_POINT" "$DOWNLOAD_DIR/$PACKAGE" >/dev/null
    trap 'hdiutil detach "$MOUNT_POINT" -quiet || true' EXIT
    ditto "$MOUNT_POINT/Remarc Dev.app" "$APP_DIR/Remarc Dev.app"
fi

python3 "$REMARC_ROOT/scripts/sign-app.py" --channel development --verify-only "$APP_DIR/Remarc Dev.app"
python3 "$REMARC_ROOT/scripts/install-app.py" "$APP_DIR/Remarc Dev.app" --channel development
echo "Remarc Dev from run $RUN_ID (${HEAD_SHA:0:7}) is installed and running."
