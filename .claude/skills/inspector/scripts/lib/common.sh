#!/usr/bin/env bash
# Shared by integrate.sh and remove.sh; sourced, never run. Works with the bash 3.2 macOS ships.
# Output follows the CLI: one JSON document on stdout, a failure as one JSON line with `code` on
# stderr and exit 1, a usage error as message plus usage on stderr and exit 64.

skill_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
inspector_root="$(cd "$skill_dir/../../.." && pwd)"
# shellcheck disable=SC2034 # used by the scripts that source this file
marker='DEBUG INSPECTOR'

# json_str <text>: the text as a JSON string literal.
json_str() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\t'/\\t}"
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
