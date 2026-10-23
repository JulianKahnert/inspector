#!/usr/bin/env bash
# Runs the inspector CLI of the checkout this skill lives in, also through a symlink such as
# `~/.claude/skills/inspector`. Builds the CLI when the binary is missing or older than any of its
# inputs (`Sources/`, `Package.swift`, `Package.resolved`), and signs it after every build so
# Xcode's approval of `de.juliankahnert.inspector` holds.
# Usage: inspector.sh [--app name] <command> [arguments]
# Env:   INSPECTOR_REBUILD=1 forces a build.
#        INSPECTOR_SIGNING_IDENTITY names the identity to sign with (as `codesign -s` takes it);
#        without it, the first "Apple Development" identity in the keychain.
# Test:  bash .claude/skills/inspector/tests/inspector-sh-test.sh
set -euo pipefail

# Sets $inspector_root, the checkout, also when this script is reached through a symlink.
# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
binary="$inspector_root/.build/debug/inspector"
# Xcode approves the parent process of `xcrun mcpbridge` by team ID plus this identifier, so every
# build signed with it keeps the approval.
identifier="de.juliankahnert.inspector"

signing_identity() {
  if [[ -n "${INSPECTOR_SIGNING_IDENTITY:-}" ]]; then
    printf '%s\n' "$INSPECTOR_SIGNING_IDENTITY"
    return
  fi
  # Lines look like `  1) <SHA-1> "Apple Development: <name> (<id>)"`; the hash picks exactly one.
  security find-identity -v -p codesigning | awk '/"Apple Development: / { print $2; exit }'
}

# An mtime check costs a few milliseconds; a no-op `swift build` about 2 s, too much for every call.
# Directories count too: deleting a source file makes its directory newer.
stale() {
  [[ ! -x "$binary" || "${INSPECTOR_REBUILD:-0}" == 1 ]] && return 0
  [[ -n "$(find "$inspector_root/Sources" "$inspector_root/Package.swift" "$inspector_root/Package.resolved" \
    -newer "$binary" -print -quit 2>/dev/null)" ]]
}

if stale; then
  # Build output goes to stderr, so stdout stays one JSON document per call.
  swift build --package-path "$inspector_root" --product inspector >&2 ||
    fail BUILD_FAILED "could not build the inspector CLI; the compiler's output is above" "$(json_str "$inspector_root")"
  # An up-to-date build leaves the binary as it was; date it now, or every call would build again.
  touch "$binary"
fi

# `swift build` and `swift test` leave an ad-hoc signature, which Xcode does not approve.
signature="$(codesign -dv "$binary" 2>&1 || true)"
if ! grep -qx "Identifier=$identifier" <<<"$signature"; then
  identity="$(signing_identity)"
  [[ -n "$identity" ]] ||
    fail NO_SIGNING_IDENTITY 'no "Apple Development" signing identity in the keychain; a human adds one in Xcode > Settings > Accounts'
  codesign --force --sign "$identity" --identifier "$identifier" "$binary" >&2
fi

# The CLI bounds every call itself: APP_NOT_FOUND after 5 s of discovery, TIMEOUT for an app or
# Xcode tool that stops answering.
exec "$binary" "$@"
