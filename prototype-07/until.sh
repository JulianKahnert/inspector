#!/usr/bin/env bash
# Usage: until.sh '<jq filter>' [limit s]  -> polls loop.sh state; prints matched value
set -uo pipefail
S="$(dirname "${BASH_SOURCE[0]}")"
ms(){ perl -MTime::HiRes=time -e 'printf "%d", time*1000'; }
t0=$(ms); polls=0
while :; do
  polls=$((polls+1))
  st="$("$S/loop.sh" "poll" state 2>/dev/null)"
  if v="$(jq -ec "$1" <<<"$st" 2>/dev/null)"; then echo "until '$1': $(( $(ms)-t0 )) ms, $polls polls" >&2; printf '%s\n' "$v"; exit 0; fi
  (( $(ms)-t0 > ${2:-5}*1000 )) && { echo "until '$1': TIMEOUT after $polls polls; last state:" >&2; jq -c . <<<"$st" >&2; exit 1; }
done
