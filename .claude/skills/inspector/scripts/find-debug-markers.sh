#!/usr/bin/env bash
# Lists every `DEBUG INSPECTOR` marker below the given directories, so the integration can be
# removed completely: files that are entirely inspector hooks first, then the marked lines.
# Usage: find-debug-markers.sh <dir> [dir…]
# Exit: 0 markers found, 1 none found, 2 usage error.
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "usage: find-debug-markers.sh <dir> [dir…]" >&2
  exit 2
fi

matches="$(grep -rn --exclude-dir=.build --exclude-dir=.git --exclude-dir=DerivedData \
  --exclude-dir=Pods 'DEBUG INSPECTOR' "$@" || true)"
if [[ -z "$matches" ]]; then
  echo "no DEBUG INSPECTOR markers" >&2
  exit 1
fi

echo "# files to delete (the template's header marks the whole file)"
grep -E '^[^:]+:1:// DEBUG INSPECTOR' <<<"$matches" | cut -d: -f1 | sort -u || true
echo
echo "# marked lines to remove"
grep -vE '^[^:]+:1:// DEBUG INSPECTOR' <<<"$matches" || true
