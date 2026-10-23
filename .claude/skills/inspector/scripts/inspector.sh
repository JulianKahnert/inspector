#!/usr/bin/env bash
# Runs the inspector CLI, building it first when the binary is missing, and signing it after every
# build so Xcode's approval of `de.juliankahnert.inspector` holds.
# Usage: inspector.sh [--app name] <command> [arguments]
# Env:   INSPECTOR_REBUILD=1 forces a build.
#        INSPECTOR_SIGNING_IDENTITY names the identity to sign with (as `codesign -s` takes it);
#        without it, the first "Apple Development" identity in the keychain.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
binary="$repo_root/.build/debug/inspector"
# Xcode approves the parent process of `xcrun mcpbridge` by team ID plus this identifier, so every
# build signed with it keeps the approval.
identifier="de.juliankahnert.inspector"

# Prints the error as the CLI does: one JSON line on stderr, exit code 1.
fail() {
  printf '{"code":"%s","message":"%s"}\n' "$1" "$2" >&2
  exit 1
}

signing_identity() {
  if [[ -n "${INSPECTOR_SIGNING_IDENTITY:-}" ]]; then
    printf '%s\n' "$INSPECTOR_SIGNING_IDENTITY"
    return
  fi
  # Lines look like `  1) <SHA-1> "Apple Development: <name> (<id>)"`; the hash picks exactly one.
  security find-identity -v -p codesigning | awk '/"Apple Development: / { print $2; exit }'
}

if [[ ! -x "$binary" || "${INSPECTOR_REBUILD:-0}" == 1 ]]; then
  # Build output goes to stderr, so stdout stays one JSON document per call.
  swift build --package-path "$repo_root" --product inspector >&2
fi

# `swift build` replaces the binary with an ad-hoc signed one, which Xcode does not approve.
signature="$(codesign -dv "$binary" 2>&1 || true)"
if ! grep -qx "Identifier=$identifier" <<<"$signature"; then
  identity="$(signing_identity)"
  [[ -n "$identity" ]] ||
    fail NO_SIGNING_IDENTITY 'no \"Apple Development\" signing identity in the keychain; a human adds one in Xcode > Settings > Accounts'
  codesign --force --sign "$identity" --identifier "$identifier" "$binary" >&2
fi

# The CLI bounds every call itself: APP_NOT_FOUND after 5 s of discovery, TIMEOUT for an app or
# Xcode tool that stops answering.
exec "$binary" "$@"
