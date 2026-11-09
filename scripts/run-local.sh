#!/bin/bash
# Build, sign, install and launch the independent local testing app.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
XCODE_VERSION="$(xcodebuild -version | head -n 1 | awk '{print $2}')"
if ! python3 - "$XCODE_VERSION" <<'PYTHON'
import sys
raise SystemExit(0 if tuple(map(int, sys.argv[1].split('.'))) >= (26, 2) else 1)
PYTHON
then
  echo "Remarc needs Xcode 26.2+. On Ventura, download the paired Development workflow artifacts instead." >&2
  exit 1
fi
export REMARC_BUILD_CONFIGURATION=Debug
if [[ "$(uname -m)" = x86_64 ]]; then
  bash "$REPO_ROOT/scripts/build-ventura.sh"
else
  bash "$REPO_ROOT/scripts/build-apple-silicon.sh"
fi
APP="$REPO_ROOT/app/DerivedData/Build/Products/Debug/Remarc Dev.app"
python3 "$REPO_ROOT/scripts/install-app.py" "$APP" --channel development
