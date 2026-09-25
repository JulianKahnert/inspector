#!/usr/bin/env bash
# Saves a PNG of the booted iOS simulator and prints its path.
# Usage: screenshot.sh [output.png] [simulator UDID]
# Without a UDID exactly one simulator may be booted; with several, the booted list is printed.
set -euo pipefail

output="${1:-${TMPDIR:-/tmp}/inspector-$(date +%Y%m%d-%H%M%S).png}"
device="${2:-}"

if [[ -z "$device" ]]; then
  booted="$(xcrun simctl list devices booted | grep -E '\(Booted\)' || true)"
  count="$(grep -c . <<<"$booted" || true)"
  if [[ "$count" -eq 0 ]]; then
    echo "no simulator is booted" >&2
    exit 1
  fi
  if [[ "$count" -gt 1 ]]; then
    echo "several simulators are booted; pass one UDID:" >&2
    echo "$booted" >&2
    exit 1
  fi
  device=booted
fi

# simctl reports display and file-type notes on stderr; show them only when the capture fails.
if ! log="$(xcrun simctl io "$device" screenshot "$output" 2>&1)"; then
  echo "$log" >&2
  exit 1
fi
printf '%s\n' "$output"
