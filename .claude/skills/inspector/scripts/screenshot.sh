#!/usr/bin/env bash
# Makes the small copy of a screenshot an agent reads instead of the full-resolution original,
# which stays on disk for a human: longest edge at most 1000 pixels, written beside the original
# as `<name>-small.png`. `capture` and every gesture make that copy themselves; this script is for
# a PNG from elsewhere (`xcrun simctl io <udid> screenshot`, `screencapture`), or for one contact
# sheet of several screenshots side by side, in argument order.
# Usage: screenshot.sh <png…>
#        screenshot.sh --sheet <out.png> <png…>
# Env:   INSPECTOR_SCREENSHOT_MAX overrides the longest edge (default 1000).
# Errors: one JSON line with `code` on stderr and exit 1, like the CLI; usage errors exit 64.
# Tests:  bash .claude/skills/inspector/tests/screenshot-test.sh (from the repo root)
set -euo pipefail

# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

usage='usage: screenshot.sh [--sheet <out.png>] <png…>'
help="$usage

Writes a copy of each PNG beside it, <name>-small.png, at most ${INSPECTOR_SCREENSHOT_MAX:-1000} pixels on its
longest edge, and prints {\"screenshots\":[{\"screenshot\",\"screenshotFull\"}]}: read
\`screenshot\`, leave \`screenshotFull\` to a human. A PNG that small already is its own copy.

  --sheet <out.png>  one contact sheet of all PNGs instead, in argument order, at most
                     ${INSPECTOR_SCREENSHOT_MAX:-1000} pixels on its longest edge; prints {\"sheet\"}"

max="${INSPECTOR_SCREENSHOT_MAX:-1000}"
sheet=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h | --help)
      printf '%s\n' "$help"
      exit 0
      ;;
    --sheet)
      [[ $# -ge 2 && -n "$2" ]] || usage_error "--sheet needs the output path"
      sheet="$2"
      shift 2
      ;;
    --)
      shift
      break
      ;;
    -*) usage_error "unknown option $1" ;;
    *) break ;;
  esac
done
[[ $# -gt 0 ]] || usage_error "no PNG given"
[[ "$max" =~ ^[1-9][0-9]*$ ]] || usage_error "INSPECTOR_SCREENSHOT_MAX must be a positive number, not $max"

# pixel_size <path>: prints `<width> <height>`, or fails with IMAGE_UNREADABLE.
pixel_size() {
  local width height
  width="$(sips -g pixelWidth "$1" 2>/dev/null | awk '/pixelWidth:/ { print $2 }')"
  height="$(sips -g pixelHeight "$1" 2>/dev/null | awk '/pixelHeight:/ { print $2 }')"
  # sips prints `<nil>` for a file it cannot read as an image.
  [[ "$width" =~ ^[0-9]+$ && "$height" =~ ^[0-9]+$ ]] || fail IMAGE_UNREADABLE "not an image sips can read" "$(json_str "$1")"
  printf '%s %s\n' "$width" "$height"
}

for image in "$@"; do
  [[ -f "$image" ]] || fail IMAGE_UNREADABLE "no such file" "$(json_str "$image")"
  pixel_size "$image" >/dev/null
done

if [[ -n "$sheet" ]]; then
  # CoreGraphics through the Swift interpreter: sips scales, but cannot place images side by side.
  swift "$skill_dir/scripts/lib/contact-sheet.swift" "$max" "$sheet" "$@" >&2 ||
    fail SHEET_FAILED "could not write the contact sheet; the Swift output is above" "$(json_str "$sheet")"
  printf '{"sheet":%s}\n' "$(json_str "$(standardize "$sheet")")"
  exit 0
fi

entries=()
for image in "$@"; do
  read -r width height < <(pixel_size "$image")
  full="$(standardize "$image")"
  if ((width <= max && height <= max)); then
    entries+=("{\"screenshot\":$(json_str "$full")}")
    continue
  fi
  small="${full%.*}-small.png"
  # -Z scales the longest edge to $max and keeps the aspect ratio; -s format writes a PNG from any input.
  sips -Z "$max" -s format png "$full" --out "$small" >/dev/null 2>&1 ||
    fail IMAGE_UNREADABLE "sips could not write the small copy" "$(json_str "$small")"
  entries+=("{\"screenshot\":$(json_str "$small"),\"screenshotFull\":$(json_str "$full")}")
done
joined="$(printf ',%s' "${entries[@]}")"
printf '{"screenshots":[%s]}\n' "${joined:1}"
