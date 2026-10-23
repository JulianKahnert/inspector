#!/usr/bin/env bash
# Prints the app's error and fault log entries since the last inspector step, from the simulator's
# unified log. Needs no Xcode session: it reads `udid` and `logSubsystem` from `.inspector/config.json`
# and the window start from `lastStep.at` in `.inspector/run.json`.
# Usage: logs.sh [--all] [--since <seconds>]
# Errors: one JSON line with `code` on stderr and exit 1, like the CLI; usage errors exit 64.
# Tests:  bash .claude/skills/inspector/tests/logs-test.sh (from the repo root, no simulator needed)
# shellcheck disable=SC2016  # backticks in the messages are literal code spans, as in the CLI's
set -euo pipefail

# fail <code> <message> <detail>: the CLI's error shape, keys sorted.
fail() {
  jq -nSc --arg code "$1" --arg message "$2" --arg detail "$3" \
    '{code: $code, message: $message, detail: $detail}' >&2
  exit 1
}

no_config() {
  fail NO_CONFIG 'no `.inspector/` folder; run `inspector init`' "$1"
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

# `INSPECTOR_DIR` when it is set, otherwise the first `.inspector/` from the working directory up
# to the repository root (the first directory with a `.git`): the same lookup the CLI does.
locate_folder() {
  if [[ -n "${INSPECTOR_DIR:-}" ]]; then
    folder="$(standardize "$INSPECTOR_DIR")"
    [[ -d "$folder" ]] || no_config "$folder"
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
    if [[ -e "$dir/.git" ]]; then
      no_config "$dir/.inspector"
    fi
    if [[ "$dir" == / ]]; then
      no_config "${start%/}/.inspector"
    fi
    dir="$(dirname "$dir")"
  done
}

usage='usage: logs.sh [--all] [--since <seconds>]'
help="$usage

Prints the app's log entries of severity error and fault since the last inspector step
(lastStep in .inspector/run.json), from the simulator in .inspector/config.json, filtered
to its logSubsystem, in the compact style: timestamp, type, process, [subsystem:category], message.

  --all              every severity, info and debug included
  --since <seconds>  the last <seconds> instead of the window since the last step"

usage_error() {
  printf 'error: %s\n%s\n' "$1" "$usage" >&2
  exit 64
}

all=0
since=
while [[ $# -gt 0 ]]; do
  case "$1" in
    --all) all=1 ;;
    --since)
      [[ "${2:-}" =~ ^[1-9][0-9]*$ ]] || usage_error '--since needs a whole number of seconds'
      since="$2"
      shift
      ;;
    -h | --help)
      printf '%s\n' "$help"
      exit 0
      ;;
    *) usage_error "unknown option: $1" ;;
  esac
  shift
done

locate_folder
config="$folder/config.json"
udid=
subsystem=
if [[ -e "$config" ]]; then
  udid="$(jq -r '.udid // empty' "$config" 2>&1)" || fail BAD_REQUEST "could not read \`$config\`" "$udid"
  subsystem="$(jq -r '.logSubsystem // empty' "$config")"
fi
missing=()
[[ -n "$udid" ]] || missing+=('`udid`')
[[ -n "$subsystem" ]] || missing+=('`logSubsystem`')
if [[ ${#missing[@]} -gt 0 ]]; then
  list="$(printf '%s, ' "${missing[@]}")"
  fail NO_CONFIG "no ${list%, } in \`config.json\`; run \`inspector init\`" "$config"
fi
# The value goes into an NSPredicate string, so it has to be a plain reverse-DNS name.
[[ "$subsystem" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] ||
  fail BAD_REQUEST "\`logSubsystem\` in \`config.json\` is no reverse-DNS name" "$subsystem"

if [[ -n "$since" ]]; then
  window=(--last "${since}s")
else
  run="$folder/run.json"
  at=
  if [[ -e "$run" ]]; then
    at="$(jq -r '.lastStep.at // empty' "$run" 2>&1)" || fail BAD_REQUEST "could not read \`$run\`" "$at"
  fi
  [[ -n "$at" ]] || fail BAD_REQUEST 'no `lastStep` in `run.json`; pass `--since <seconds>`' "$run"
  # `at` is UTC with milliseconds (`2026-10-19T08:53:20.250Z`); `log show` takes whole seconds with
  # an offset, so the window starts up to a second early, never late.
  [[ "$at" =~ ^([0-9]{4}-[0-9]{2}-[0-9]{2})T([0-9]{2}:[0-9]{2}:[0-9]{2})(\.[0-9]+)?Z$ ]] ||
    fail BAD_REQUEST '`lastStep.at` in `run.json` is no UTC timestamp' "$at"
  window=(--start "${BASH_REMATCH[1]} ${BASH_REMATCH[2]}+0000")
fi

# `com.example.app` takes the app's own subsystem and those below it; `com.example.` is a prefix.
if [[ "$subsystem" == *. ]]; then
  predicate="(subsystem BEGINSWITH \"$subsystem\")"
else
  predicate="(subsystem == \"$subsystem\" OR subsystem BEGINSWITH \"$subsystem.\")"
fi
severities=()
if ((all)); then
  severities=(--info --debug)
else
  predicate+=" AND (messageType == error OR messageType == fault)"
fi

# The entries stream to stdout; simctl's own complaint (simulator shut down, unknown UDID) is
# caught on the way and turned into the CLI's error shape.
if ! complaint="$(xcrun simctl spawn "$udid" log show --style compact ${severities[@]+"${severities[@]}"} \
  "${window[@]}" --predicate "$predicate" 2>&1 >&3)"; then
  fail BAD_REQUEST "\`log show\` failed on simulator \`$udid\`" "${complaint%$'\n'}"
fi 3>&1
