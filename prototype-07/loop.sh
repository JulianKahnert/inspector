#!/usr/bin/env bash
# Throwaway timing harness for ticket 07. Usage: loop.sh <label> <inspector args...>
# Prints "<label>: <ms> ms, <bytes> B" on stderr, the JSON on stdout, appends to timings.csv.
set -uo pipefail
S="$(dirname "${BASH_SOURCE[0]}")"
BIN="${INSPECTOR_BIN:-$HOME/GIT/inspector/.build/debug/inspector}"
label="$1"; shift
ms(){ perl -MTime::HiRes=time -e 'printf "%d", time*1000'; }
t0=$(ms)
out="$("$BIN" --app RoommateAlbert "$@" 2>"$S/last.err")"; rc=$?
t1=$(ms)
printf '%s,%s,%d,%d,%d\n' "$(date +%T)" "$label" "$((t1-t0))" "${#out}" "$rc" >> "$S/timings.csv"
echo "$label: $((t1-t0)) ms, ${#out} B, rc=$rc" >&2
[[ $rc -ne 0 ]] && cat "$S/last.err" >&2
printf '%s\n' "$out"
