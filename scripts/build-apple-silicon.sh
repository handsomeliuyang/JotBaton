#!/bin/bash
set -euo pipefail
export REMARC_SIGNING_IN_BUILDER=1
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export REMARC_VENTURA=0
CONFIGURATION="${REMARC_BUILD_CONFIGURATION:-Debug}"
case "$CONFIGURATION" in Debug|Release) ;; *) echo "Unsupported configuration" >&2; exit 1 ;; esac
CHANNEL=production
APP_NAME=JotBaton
if [[ "$CONFIGURATION" = Debug ]]; then CHANNEL=development; APP_NAME="JotBaton Dev"; fi
if [[ "$CONFIGURATION" = Release && "${GITHUB_ACTIONS:-}" != true ]]; then
  echo "Production builds run only in GitHub Actions. Use scripts/dev-preview.sh locally." >&2
  exit 2
fi
cd "$REPO_ROOT/app"
bash "$REPO_ROOT/scripts/resolve-packages.sh" "$REPO_ROOT/app/RemarcPackage"
xcodebuild clean build \
  -workspace "$REPO_ROOT/app/Remarc.xcworkspace" \
  -scheme Remarc -configuration "$CONFIGURATION" \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$(pwd)/DerivedData" \
  -onlyUsePackageVersionsFromResolvedFile \
  -packageCachePath "$REPO_ROOT/app/DerivedData/PackageCache" \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO DEVELOPMENT_TEAM= PROVISIONING_PROFILE_SPECIFIER=
APP="$REPO_ROOT/app/DerivedData/Build/Products/$CONFIGURATION/$APP_NAME.app"
python3 "$REPO_ROOT/scripts/prepare-app.py" "$APP" --channel "$CHANNEL"
python3 "$REPO_ROOT/scripts/sign-app.py" "$APP" --channel "$CHANNEL"
python3 "$REPO_ROOT/scripts/relaunch-app.py" "$APP"
python3 "$REPO_ROOT/scripts/verify-apple-silicon-app.py" "$APP"
