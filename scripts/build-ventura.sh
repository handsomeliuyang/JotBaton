#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export REMARC_VENTURA=1
CONFIGURATION="${REMARC_BUILD_CONFIGURATION:-Debug}"
case "$CONFIGURATION" in
  Debug|Release) ;;
  *) echo "Unsupported build configuration: $CONFIGURATION" >&2; exit 1 ;;
esac
cd "$REPO_ROOT/app"

# Resolve the reduced dependency graph, retaining the upstream pinned revisions.
PIN_BACKUP_DIR="$(mktemp -d)"
PIN_BACKUP="$PIN_BACKUP_DIR/package.resolved"
LOCK_DIR="$REPO_ROOT/app/Remarc.xcworkspace/xcshareddata/swiftpm"
cp RemarcPackage/Package.resolved "$PIN_BACKUP"
if [[ -f "$LOCK_DIR/Package.resolved" ]]; then
  cp "$LOCK_DIR/Package.resolved" "$PIN_BACKUP_DIR/workspace.resolved"
fi
restore_locks() {
  cp "$PIN_BACKUP" "$REPO_ROOT/app/RemarcPackage/Package.resolved"
  if [[ -f "$PIN_BACKUP_DIR/workspace.resolved" ]]; then
    cp "$PIN_BACKUP_DIR/workspace.resolved" "$LOCK_DIR/Package.resolved"
  else
    rm -f "$LOCK_DIR/Package.resolved"
  fi
  rm -rf "$PIN_BACKUP_DIR"
}
trap restore_locks EXIT
swift package --package-path RemarcPackage resolve
python3 - "$PIN_BACKUP" RemarcPackage/Package.resolved <<'PY'
import json, sys
original, resolved = [json.load(open(path))['pins'] for path in sys.argv[1:]]
expected = {p['identity']: p['state']['revision'] for p in original if p['identity'] != 'fluidaudio'}
actual = {p['identity']: p['state']['revision'] for p in resolved}
if actual != expected:
    raise SystemExit('Ventura resolution changed pinned dependencies; review Package.resolved before building')
PY
mkdir -p "$LOCK_DIR"
cp RemarcPackage/Package.resolved "$LOCK_DIR/Package.resolved"

CHANNEL=production
APP_NAME=Remarc
if [[ "$CONFIGURATION" = Debug ]]; then
  CHANNEL=development
  APP_NAME="Remarc Dev"
fi
xcodebuild clean build \
  -workspace "$REPO_ROOT/app/Remarc.xcworkspace" \
  -scheme Remarc -configuration "$CONFIGURATION" \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$(pwd)/DerivedData" \
  -xcconfig "$REPO_ROOT/app/Config/Ventura.xcconfig" \
  -onlyUsePackageVersionsFromResolvedFile \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
APP="$REPO_ROOT/app/DerivedData/Build/Products/$CONFIGURATION/$APP_NAME.app"
python3 "$REPO_ROOT/scripts/prepare-app.py" "$APP" --channel "$CHANNEL"
python3 "$REPO_ROOT/scripts/sign-app.py" "$APP" --channel "$CHANNEL"
python3 "$REPO_ROOT/scripts/relaunch-app.py" "$APP"
python3 "$REPO_ROOT/scripts/verify-ventura-app.py" "$APP"
