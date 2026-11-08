#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export REMARC_VENTURA=0
cd "$REPO_ROOT/app"

xcodebuild clean build \
  -workspace "$REPO_ROOT/app/Remarc.xcworkspace" \
  -scheme Remarc -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$(pwd)/DerivedData" \
  -onlyUsePackageVersionsFromResolvedFile \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= PROVISIONING_PROFILE_SPECIFIER=

APP="$REPO_ROOT/app/DerivedData/Build/Products/Release/Remarc.app"
/usr/libexec/PlistBuddy -c 'Add :RemarcManualUpdates bool true' "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :RemarcSourceCommit string $(git -C "$REPO_ROOT" rev-parse HEAD)" "$APP/Contents/Info.plist"

# Sign nested code from the inside out, then the app with local-use entitlements.
# A Developer ID certificate is required for notarized public distribution.
python3 - "$APP" "$REPO_ROOT/app/Config/Ventura.entitlements" <<'PY'
import subprocess
import sys
from pathlib import Path

app = Path(sys.argv[1])
for path in sorted(app.rglob('*'), key=lambda p: len(p.parts), reverse=True):
    if path.is_symlink():
        continue
    is_bundle = path.is_dir() and path.suffix in ('.app', '.framework', '.xpc')
    is_code = path.is_file() and 'Mach-O' in subprocess.check_output(['file', '-b', str(path)], text=True)
    if is_bundle or is_code:
        subprocess.run(['codesign', '--force', '--sign', '-', '--timestamp=none', str(path)], check=True)
subprocess.run(['codesign', '--force', '--sign', '-', '--timestamp=none',
                '--entitlements', sys.argv[2], str(app)], check=True)
PY

# Relaunch after every successful app build on the Apple Silicon build host.
pkill -x Remarc || true
sleep 0.5
open "$APP"
python3 "$REPO_ROOT/scripts/verify-apple-silicon-app.py" "$APP"
codesign --verify --deep --strict "$APP"
sleep 3
pgrep -x Remarc >/dev/null
