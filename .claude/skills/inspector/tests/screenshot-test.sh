#!/usr/bin/env bash
# Tests scripts/screenshot.sh on PNGs it generates with sips: the small copy beside the original,
# a PNG small enough already, the contact sheet, and the errors. Needs no simulator.
# Usage (from the repo root): bash .claude/skills/inspector/tests/screenshot-test.sh
# Without `set -e`: a case that fails must not stop the others.
set -uo pipefail

script="$(cd "$(dirname "${BASH_SOURCE[0]}")/../scripts" && pwd)/screenshot.sh"
sandbox="$(mktemp -d)"
sandbox="$(cd "$sandbox" && pwd -P)"
trap 'rm -rf "$sandbox"' EXIT

failures=0
cases=0

# png <path> <width> <height>: a PNG of that size, scaled from an icon macOS ships.
icon=/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/GenericApplicationIcon.icns
png() {
  sips -s format png -z "$3" "$2" "$icon" --out "$1" >/dev/null
}

# size <path>: `<width>x<height>`.
size() {
  printf '%sx%s' "$(sips -g pixelWidth "$1" | awk '/pixelWidth:/ { print $2 }')" \
    "$(sips -g pixelHeight "$1" | awk '/pixelHeight:/ { print $2 }')"
}

# run [VAR=value…] -- [screenshot.sh arguments…]: runs it in the sandbox, sets $out, $err, $code.
run() {
  local -a env=()
  while [[ $# -gt 0 && "$1" != -- ]]; do
    env+=("$1")
    shift
  done
  shift
  out="$(cd "$sandbox" && env ${env[@]+"${env[@]}"} bash "$script" "$@" 2>"$sandbox/stderr")"
  code=$?
  err="$(cat "$sandbox/stderr")"
}

# expect <what> <expected> <actual>
expect() {
  if [[ "$2" == "$3" ]]; then
    return 0
  fi
  failures=$((failures + 1))
  printf 'FAIL %s: %s\n  expected: %s\n  actual:   %s\n' "$current" "$1" "$2" "$3" >&2
}

# scenario <name>
scenario() {
  current="$1"
  cases=$((cases + 1))
  rm -rf "${sandbox:?}"/*.png
}

scenario "a large PNG gets a small copy beside it, the original stays as it was"
png "$sandbox/screen.png" 1206 2622
run -- screen.png
expect "exit code" 0 "$code"
expect "stdout" "{\"screenshots\":[{\"screenshot\":\"$sandbox/screen-small.png\",\"screenshotFull\":\"$sandbox/screen.png\"}]}" "$out"
expect "small size" "460x1000" "$(size "$sandbox/screen-small.png")"
expect "original size" "1206x2622" "$(size "$sandbox/screen.png")"

scenario "a PNG no larger than the limit is its own copy"
png "$sandbox/tiny.png" 400 300
run -- tiny.png
expect "exit code" 0 "$code"
expect "stdout" "{\"screenshots\":[{\"screenshot\":\"$sandbox/tiny.png\"}]}" "$out"
expect "no copy" "no" "$([[ -e "$sandbox/tiny-small.png" ]] && echo yes || echo no)"

scenario "several PNGs answer one entry each, in order; INSPECTOR_SCREENSHOT_MAX sets the limit"
png "$sandbox/a.png" 1000 2000
png "$sandbox/b.png" 300 200
run INSPECTOR_SCREENSHOT_MAX=500 -- a.png b.png
expect "exit code" 0 "$code"
expect "screenshots" "$sandbox/a-small.png $sandbox/b.png" "$(jq -r '[.screenshots[].screenshot] | join(" ")' <<<"$out")"
expect "small size" "250x500" "$(size "$sandbox/a-small.png")"

scenario "--sheet draws the PNGs side by side into one image at most 1000 pixels on its longest edge"
png "$sandbox/a.png" 1206 2622
png "$sandbox/b.png" 1206 2622
run -- --sheet sheet.png a.png b.png
expect "exit code" 0 "$code"
expect "stdout" "{\"sheet\":\"$sandbox/sheet.png\"}" "$out"
# Two cells and three gaps of 2 % of the longer edge, scaled to a height of 1000.
expect "sheet size" "942x1000" "$(size "$sandbox/sheet.png")"

scenario "a missing file fails with IMAGE_UNREADABLE and its path"
run -- missing.png
expect "exit code" 1 "$code"
expect "stderr" '{"code":"IMAGE_UNREADABLE","detail":"missing.png","message":"no such file"}' "$err"

scenario "a file that is no image fails with IMAGE_UNREADABLE"
printf 'text' >"$sandbox/note.png"
run -- note.png
expect "exit code" 1 "$code"
expect "stderr" '{"code":"IMAGE_UNREADABLE","detail":"note.png","message":"not an image sips can read"}' "$err"

scenario "no PNG is a usage error"
run --
expect "exit code" 64 "$code"
run -- --sheet
expect "exit code without the sheet path" 64 "$code"

if ((failures > 0)); then
  printf '%d of %d cases had failures\n' "$failures" "$cases" >&2
  exit 1
fi
printf 'all %d cases passed\n' "$cases"
