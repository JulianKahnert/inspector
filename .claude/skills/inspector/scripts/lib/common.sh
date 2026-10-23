#!/usr/bin/env bash
# Shared by the skill's scripts; sourced, never run. Works with the bash 3.2 macOS ships.
# Output follows the CLI: one JSON document on stdout, a failure as one JSON line with `code` on
# stderr and exit 1, a usage error as message plus usage on stderr and exit 64.

# -P: reached through a symlink such as `~/.claude/skills/inspector`, `..` has to climb the checkout.
skill_dir="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
inspector_root="$(cd "$skill_dir/../../.." && pwd)"
# shellcheck disable=SC2034 # used by the scripts that source this file
marker='DEBUG INSPECTOR'

# json_str <text>: the text as a JSON string literal, escaped as jq escapes it.
json_str() {
  local s="$1" code character
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\t'/\\t}"
  s="${s//$'\b'/\\b}"
  s="${s//$'\f'/\\f}"
  # Every other control character; a bash string cannot hold NUL. `printf -v` forks nothing.
  for code in 01 02 03 04 05 06 07 0b 0e 0f 10 11 12 13 14 15 16 17 18 19 1a 1b 1c 1d 1e 1f 7f; do
    printf -v character '%b' "\\x$code"
    s="${s//$character/\\u00$code}"
  done
  printf '"%s"' "$s"
}

# json_strings [text…]: a JSON array of strings.
json_strings() {
  local separator="" item
  printf '['
  for item in "$@"; do
    printf '%s' "$separator"
    json_str "$item"
    separator=","
  done
  printf ']'
}

# fail <code> <message> [detail JSON]: the CLI's error line, then exit 1.
fail() {
  local detail=""
  [[ $# -ge 3 && -n "$3" ]] && detail=",\"detail\":$3"
  printf '{"code":%s%s,"message":%s}\n' "$(json_str "$1")" "$detail" "$(json_str "$2")" >&2
  exit 1
}

# usage_error <message>: needs $usage; exit 64 like the CLI's argument errors.
usage_error() {
  # shellcheck disable=SC2154 # each script sets $usage
  printf 'Error: %s\n%s\n' "$1" "$usage" >&2
  exit 64
}

# standardize <path>: absolute, without `.` and `..` components, like the CLI's standardized URL.
standardize() {
  local path="$1" part
  local -a parts=() components
  [[ "$path" == /* ]] || path="$(pwd -P)/$path"
  IFS=/ read -ra components <<<"$path"
  for part in "${components[@]}"; do
    case "$part" in
      '' | .) ;;
      ..) [[ ${#parts[@]} -gt 0 ]] && unset 'parts[${#parts[@]}-1]' ;;
      *) parts+=("$part") ;;
    esac
  done
  local IFS=/
  printf '/%s\n' "${parts[*]-}"
}

# locate_inspector_folder: sets $folder to `INSPECTOR_DIR` when it is set, otherwise to the first
# `.inspector/` from the working directory up to the repository root (the first directory with a
# `.git`), or fails with NO_CONFIG and the path expected: the lookup the CLI does.
locate_inspector_folder() {
  if [[ -n "${INSPECTOR_DIR:-}" ]]; then
    folder="$(standardize "$INSPECTOR_DIR")"
    [[ -d "$folder" ]] || no_inspector_folder "$folder"
    return
  fi
  local start dir
  start="$(pwd -P)"
  dir="$start"
  while :; do
    if [[ -d "$dir/.inspector" ]]; then
      folder="$dir/.inspector"
      return
    fi
    [[ ! -e "$dir/.git" ]] || no_inspector_folder "$dir/.inspector"
    [[ "$dir" != / ]] || no_inspector_folder "${start%/}/.inspector"
    dir="$(dirname "$dir")"
  done
}

# no_inspector_folder <expected path>: the CLI's NO_CONFIG failure.
no_inspector_folder() {
  # shellcheck disable=SC2016 # the backticks are literal code spans, as in the CLI's message
  fail NO_CONFIG 'no `.inspector/` folder; run `inspector init`' "$(json_str "$1")"
}

# repo_root <dir>: the repository's top-level directory, or nothing for a directory outside git.
repo_root() {
  [[ -d "$1" ]] || return 1
  git -C "$1" rev-parse --show-toplevel 2>/dev/null
}

# require_app_repo <dir>: prints the top level, or fails with NOT_A_REPO. Call it as
# `root="$(require_app_repo "$dir")" || exit 1`: the failure exits only the subshell.
require_app_repo() {
  local root
  root="$(repo_root "$1")" || fail NOT_A_REPO "not inside a git repository: $1" "$(json_str "$1")"
  [[ -n "$root" ]] || fail NOT_A_REPO "not inside a git repository: $1" "$(json_str "$1")"
  # The skill's own template carries the marker; running the scripts here would delete it.
  [[ "$(cd "$root" && pwd -P)" != "$(cd "$inspector_root" && pwd -P)" ]] ||
    fail NOT_AN_APP_REPO "this is the inspector repository itself, not an app: $root" "$(json_str "$root")"
  printf '%s\n' "$root"
}

# pins_from_stdin: the package identities pinned in a Package.resolved on stdin, lowercased and
# sorted, one per line.
pins_from_stdin() {
  { grep -o '"identity"[[:space:]]*:[[:space:]]*"[^"]*"' || true; } |
    sed 's/.*"\([^"]*\)"$/\1/' | tr '[:upper:]' '[:lower:]' | sort -u
}

# pin_identities <Package.resolved>: pins_from_stdin for a file; nothing for a missing one.
pin_identities() {
  [[ -f "$1" ]] || return 0
  pins_from_stdin <"$1"
}

# inspector_pins: identities InspectorKit's package brings into an app's Package.resolved.
inspector_pins() {
  pin_identities "$inspector_root/Package.resolved"
}

# resolved_files <root>: every Package.resolved git would commit, relative to the root.
resolved_files() {
  git -C "$1" ls-files -co --exclude-standard -- 'Package.resolved' '*/Package.resolved' | sort -u
}

# exclude_file <root>: the repository's info/exclude, shared by all of its worktrees.
exclude_file() {
  git -C "$1" rev-parse --path-format=absolute --git-path info/exclude
}
