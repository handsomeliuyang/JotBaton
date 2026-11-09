#!/bin/bash
# Local testing uses the deliberately shared development identity.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
exec python3 "$REPO_ROOT/scripts/sign-app.py" "$1" --channel development
