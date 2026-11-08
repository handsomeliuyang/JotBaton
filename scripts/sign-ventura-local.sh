#!/bin/bash
# Compatibility entry point for the Intel installation tools.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [[ $# -ne 1 || ! -d "$1/Contents" ]]; then
  echo "Usage: $0 /absolute/path/Remarc.app" >&2
  exit 1
fi
python3 "$REPO_ROOT/scripts/verify-ventura-app.py" "$1"
exec bash "$REPO_ROOT/scripts/sign-local.sh" "$1"
