#!/usr/bin/env bash
# Runs the inspector CLI, building it first when the binary is missing.
# Usage: inspector.sh [--app name] <apps|hello|catalog|state [path]|send <path> [json]>
# Env:   INSPECTOR_REBUILD=1 forces a build.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
binary="$repo_root/.build/debug/inspector"

if [[ ! -x "$binary" || "${INSPECTOR_REBUILD:-0}" == 1 ]]; then
  # Build output goes to stderr, so stdout stays one JSON document per call.
  swift build --package-path "$repo_root" --product inspector >&2
fi

# The CLI bounds every call itself: APP_NOT_FOUND after 5 s of discovery, TIMEOUT for an app that
# stops answering.
exec "$binary" "$@"
