#!/usr/bin/env bash
# Polls `inspector state` until a jq filter yields a value other than null/false, then prints it.
# Usage: wait-state.sh '<jq filter>' [limit in seconds, default 10]
# Example: wait-state.sh '."chats.details".members'   (quote keys that contain dots)
# Exit: 0 found (elapsed ms on stderr), 1 limit reached or CLI error, 2 usage error.
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "usage: wait-state.sh '<jq filter>' [limit seconds]" >&2
  exit 2
fi

filter="$1"
limit="${2:-10}"
cli="$(dirname "${BASH_SOURCE[0]}")/inspector.sh"

start=$(perl -MTime::HiRes=time -e 'printf "%d", time * 1000')
deadline=$((start + limit * 1000))
polls=0
while :; do
  polls=$((polls + 1))
  state="$("$cli" state)"
  if value="$(jq -ec "$filter" <<<"$state")"; then
    now=$(perl -MTime::HiRes=time -e 'printf "%d", time * 1000')
    echo "ready after $((now - start)) ms ($polls polls)" >&2
    printf '%s\n' "$value"
    exit 0
  fi
  now=$(perl -MTime::HiRes=time -e 'printf "%d", time * 1000')
  if ((now >= deadline)); then
    jq -nc --arg message "$filter still empty after ${limit}s ($polls polls)" \
      '{code: "TIMEOUT", message: $message}' >&2
    exit 1
  fi
done
