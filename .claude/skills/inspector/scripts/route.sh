#!/bin/zsh
# Records a route from the calls a session made and plays it back without anyone deciding in
# between: a known way to a screen (sign-in, a menu, a sheet) costs one call instead of one turn
# per step.
#
# Usage: route.sh record [<calls.jsonl>]   the route as text on stdout
#        route.sh play <route> [--from <n>] [--to <n>]
#
# record reads the call log `scripts/inspector.sh` writes to `.inspector/calls.jsonl` (or the one
# given) and keeps every call that changed the app and succeeded: tap, swipe, type, send, wait.
# Reads (state, capture, catalog, init, …), failed calls and `--targets` are left out. The result
# is a draft: harden it once (SKILL.md, *Routes*) before you rely on it.
#
# A route is text, one call per line, written as you would pass it to `scripts/inspector.sh`;
# `#` starts a comment. Words before the call that start with `@` tell play how to run it:
#   @retry <s>     repeat the call until it passes, at most <s> seconds (for UI drawn by another
#                  process, which no `--until` can see)
#   @has <name>    passes only when the answer's targets have <name> as label or identifier
#   @lacks <name>  passes only when they no longer have it
# `||` between two calls on one line: the second runs when the first fails, e.g. an in-app
# activation with a gesture as fallback. A line passes when one of its calls passes.
#
# play runs the lines in order, stops at the first line that does not pass and prints its number,
# the line and the last error (exit 1); otherwise it prints the answer of the last call. Each line's
# time goes to stderr. --from/--to play only part of the route (1-based, inclusive), e.g. to the
# screen you debug.
# Env: INSPECTOR, the command to call (default: the CLI binary this skill builds, without the
#      wrapper's build check per call); INSPECTOR_EARLY defaults to 1 here.
emulate -L zsh
setopt pipefail no_unset extended_glob
zmodload zsh/datetime zsh/mathfunc

usage="usage: ${0:t} record [<calls.jsonl>] | play <route> [--from <n>] [--to <n>]"
die() { print -u2 -- "$*"; exit 64 }

scripts=${0:A:h}
log_dir=${INSPECTOR_DIR:-$PWD/.inspector}

record() {
  local file=${1:-$log_dir/calls.jsonl}
  [[ -r $file ]] || die "no call log at $file"
  print "# recorded $(date '+%Y-%m-%d %H:%M') from $file"
  jq -r 'select(.exit == 0 and (.caller // "") != "harness")
         | select(.args[0] | IN("tap", "swipe", "type", "send", "wait"))
         | .args | map(select(. != "--targets"))
         | map(if test("^[A-Za-z0-9._:/@=+-]+$") then . else @sh end) | join(" ")' "$file"
}

# Sets $answer and $error of one call, its words in $@; returns its exit code.
call() {
  local out=$(mktemp -t route) err=$(mktemp -t route) code
  "${inspector[@]}" "$@" >$out 2>$err
  code=$?
  answer=$(<$out) error=$(<$err)
  rm -f $out $err
  return $code
}

# targets_have <name>: the last answer's targets have it as label or identifier.
targets_have() {
  jq -e --arg n "$1" '[.targets[]? | .label, .identifier] | index($n)' <<<$answer >/dev/null 2>&1
}

play() {
  local route=$1; shift
  [[ -r $route ]] || die "no route at $route"
  local from=1 to=0
  while (( $# )); do
    case $1 in
      --from) from=$2; shift 2 ;;
      --to) to=$2; shift 2 ;;
      *) die $usage ;;
    esac
  done
  export INSPECTOR_EARLY=${INSPECTOR_EARLY:-1}
  if [[ -n ${INSPECTOR:-} ]]; then
    inspector=(${=INSPECTOR})
  else
    # One call through the wrapper builds and signs the CLI if needed; then the binary directly.
    "$scripts/inspector.sh" --help >/dev/null 2>&1
    inspector=("$scripts/../../../../.build/debug/inspector")
  fi

  local n=0 line answer="" error="" started=$EPOCHREALTIME w a
  local -a words alts alt args
  local retry has lacks step_start deadline passed
  while IFS= read -r line || [[ -n $line ]]; do
    line=${line%%[[:space:]]#}
    [[ -z ${line##[[:space:]]#} || $line == [[:space:]]#\#* ]] && continue
    (( ++n < from )) && continue
    (( to > 0 && n > to )) && break
    words=("${(@Q)${(z)line}}") retry=0 has="" lacks=""
    while [[ ${words[1]:-} == @* ]]; do
      case ${words[1]} in
        @retry) retry=${words[2]} ;;
        @has) has=${words[2]} ;;
        @lacks) lacks=${words[2]} ;;
        *) die "line $n: unknown option ${words[1]}" ;;
      esac
      words=("${(@)words[3,-1]}")
    done
    # The alternatives, split at `||`.
    alts=() alt=()
    for w in "${words[@]}"; do
      if [[ $w == '||' ]]; then alts+=("${(j:\x1f:)alt}"); alt=(); else alt+=("$w"); fi
    done
    alts+=("${(j:\x1f:)alt}")

    step_start=$EPOCHREALTIME deadline=$(( EPOCHREALTIME + retry )) passed=0
    while true; do
      for a in "${alts[@]}"; do
        args=("${(@s:\x1f:)a}")
        [[ -n $has$lacks && ${args[(Ie)--targets]} == 0 && ${args[1]} == (tap|swipe|type) ]] && args+=(--targets)
        call "${args[@]}" || continue
        [[ -n $has ]] && ! targets_have $has && continue
        [[ -n $lacks ]] && targets_have $lacks && continue
        passed=1; break
      done
      (( passed || EPOCHREALTIME >= deadline )) && break
    done
    if (( ! passed )); then
      print -ru2 -- "route: line $n failed after $(( int((EPOCHREALTIME - step_start) * 1000) )) ms: $line"
      [[ -n $error ]] && print -ru2 -- $error
      exit 1
    fi
    print -ru2 -- "route: $n $(( int((EPOCHREALTIME - step_start) * 1000) )) ms  $line"
  done <$route
  print -ru2 -- "route: $n lines in $(( int((EPOCHREALTIME - started) * 1000) )) ms"
  print -r -- $answer
}

case ${1:-} in
  record) shift; record "$@" ;;
  play) shift; (( $# )) || die $usage; play "$@" ;;
  *) die $usage ;;
esac
