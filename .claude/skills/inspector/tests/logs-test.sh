#!/usr/bin/env bash
# Tests scripts/logs.sh without a simulator: a fake `xcrun` on PATH records its arguments and
# prints a canned log, so the lookup of `.inspector/`, the predicate, the window and the options
# are checked as the command line `log show` would get.
# Usage (from the repo root): bash .claude/skills/inspector/tests/logs-test.sh
# Without `set -e`: a case that fails must not stop the others.
# shellcheck disable=SC2016  # backticks in the expected messages are literal, as in the CLI's
set -uo pipefail

script="$(cd "$(dirname "${BASH_SOURCE[0]}")/../scripts" && pwd)/logs.sh"
sandbox="$(mktemp -d)"
sandbox="$(cd "$sandbox" && pwd -P)"
trap 'rm -rf "$sandbox"' EXIT

# The fake records one argument per line and answers with $FAKE_OUTPUT, $FAKE_ERROR, $FAKE_EXIT.
mkdir -p "$sandbox/bin"
cat >"$sandbox/bin/xcrun" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$XCRUN_ARGS"
printf '%s' "${FAKE_OUTPUT:-}"
printf '%s' "${FAKE_ERROR:-}" >&2
exit "${FAKE_EXIT:-0}"
FAKE
chmod +x "$sandbox/bin/xcrun"

failures=0
cases=0

# run <dir> [VAR=value…] -- [logs.sh arguments…]: runs logs.sh in <dir>, sets $out, $err, $code
# and $args (what xcrun got, one per line; empty when it was not called).
run() {
  local dir="$1"
  shift
  local -a env=()
  while [[ $# -gt 0 && "$1" != -- ]]; do
    env+=("$1")
    shift
  done
  shift
  rm -f "$sandbox/args"
  out="$(cd "$dir" && env PATH="$sandbox/bin:$PATH" XCRUN_ARGS="$sandbox/args" ${env[@]+"${env[@]}"} \
    bash "$script" "$@" 2>"$sandbox/stderr")"
  code=$?
  err="$(cat "$sandbox/stderr")"
  args="$(cat "$sandbox/args" 2>/dev/null || true)"
}

# expect <what> <expected> <actual>
expect() {
  if [[ "$2" == "$3" ]]; then
    return 0
  fi
  failures=$((failures + 1))
  printf 'FAIL %s: %s\n  expected: %s\n  actual:   %s\n' "$current" "$1" "$2" "$3" >&2
}

# scenario <name>: starts a case with a fresh repository at $repo.
scenario() {
  current="$1"
  cases=$((cases + 1))
  repo="$sandbox/repo-$cases"
  mkdir -p "$repo/.git"
}

# inspector_folder <dir> <config json> [run json]
inspector_folder() {
  mkdir -p "$1/.inspector"
  printf '%s\n' "$2" >"$1/.inspector/config.json"
  if [[ $# -ge 3 ]]; then
    printf '%s\n' "$3" >"$1/.inspector/run.json"
  fi
}

lines() { printf '%s\n' "$@"; }

no_config() {
  printf '{"code":"NO_CONFIG","detail":"%s","message":"no `.inspector/` folder; run `inspector init`"}' "$1"
}

scenario "without .inspector/ it fails with NO_CONFIG and the expected path in the repository root"
mkdir -p "$repo/Sources/App"
run "$repo/Sources/App" --
expect "exit code" 1 "$code"
expect "stderr" "$(no_config "$repo/.inspector")" "$err"
expect "stdout" "" "$out"
expect "xcrun calls" "" "$args"

config='{"bundleId":"com.example.app","logSubsystem":"com.example.app","udid":"SIM-UDID"}'
step='{"lastStep":{"arguments":["send","counter.set","42"],"at":"2026-10-19T08:53:20.250Z","command":"send"}}'
log=$'Timestamp               Ty Process[PID:TID]\n2026-10-19 10:53:21.004 E  App[42:1a] [com.example.app:Sync] request failed\n'

scenario "from a subdirectory it reads the app's errors and faults since lastStep, compact"
inspector_folder "$repo" "$config" "$step"
mkdir -p "$repo/Sources/App"
run "$repo/Sources/App" FAKE_OUTPUT="$log" --
expect "exit code" 0 "$code"
expect "xcrun arguments" "$(lines simctl spawn SIM-UDID log show --style compact \
  --start '2026-10-19 08:53:20+0000' \
  --predicate '(subsystem == "com.example.app" OR subsystem BEGINSWITH "com.example.app.") AND (messageType == error OR messageType == fault)')" "$args"
expect "stdout" "${log%$'\n'}" "$out"
expect "stderr" "" "$err"

scenario "the search stops at the repository root, a folder above it does not count"
inspector_folder "$sandbox" "$config" "$step"
run "$repo" --
rm -rf "$sandbox/.inspector"
expect "exit code" 1 "$code"
expect "stderr" "$(no_config "$repo/.inspector")" "$err"

scenario "INSPECTOR_DIR names the folder for one call, relative to the working directory"
inspector_folder "$sandbox/elsewhere" '{"logSubsystem":"com.example.other","udid":"OTHER-UDID"}' "$step"
run "$repo" INSPECTOR_DIR=../elsewhere/.inspector --
expect "exit code" 0 "$code"
expect "device" "OTHER-UDID" "$(sed -n 3p <<<"$args")"

scenario "an INSPECTOR_DIR that names nothing fails with NO_CONFIG and that path"
inspector_folder "$repo" "$config" "$step"
run "$repo" INSPECTOR_DIR="$sandbox/gone" --
expect "exit code" 1 "$code"
expect "stderr" "$(no_config "$sandbox/gone")" "$err"
expect "xcrun calls" "" "$args"

scenario "--all takes every severity, info and debug included"
inspector_folder "$repo" "$config" "$step"
run "$repo" -- --all
expect "exit code" 0 "$code"
expect "xcrun arguments" "$(lines simctl spawn SIM-UDID log show --style compact --info --debug \
  --start '2026-10-19 08:53:20+0000' \
  --predicate '(subsystem == "com.example.app" OR subsystem BEGINSWITH "com.example.app.")')" "$args"

scenario "--since <seconds> sets the window instead of lastStep, also without run.json"
inspector_folder "$repo" "$config"
run "$repo" -- --since 90
expect "exit code" 0 "$code"
expect "xcrun arguments" "$(lines simctl spawn SIM-UDID log show --style compact --last 90s \
  --predicate '(subsystem == "com.example.app" OR subsystem BEGINSWITH "com.example.app.") AND (messageType == error OR messageType == fault)')" "$args"

scenario "--since and --all combine, in either order"
inspector_folder "$repo" "$config"
run "$repo" -- --since 5 --all
expect "exit code" 0 "$code"
expect "xcrun arguments" "$(lines simctl spawn SIM-UDID log show --style compact --info --debug --last 5s \
  --predicate '(subsystem == "com.example.app" OR subsystem BEGINSWITH "com.example.app.")')" "$args"

usage='usage: logs.sh [--all] [--since <seconds>]'
for bad in "--verbose|unknown option: --verbose" "--since|--since needs a whole number of seconds" \
  "--since 1.5|--since needs a whole number of seconds" "--since 0|--since needs a whole number of seconds" \
  "--since -3|--since needs a whole number of seconds" "extra|unknown option: extra"; do
  scenario "a usage error exits 64 before anything else: ${bad%%|*}"
  read -ra bad_args <<<"${bad%%|*}"
  run "$repo" -- "${bad_args[@]}"
  expect "exit code" 64 "$code"
  expect "stderr" "$(lines "error: ${bad#*|}" "$usage")" "$err"
  expect "stdout" "" "$out"
  expect "xcrun calls" "" "$args"
done

scenario "a config without udid fails with NO_CONFIG, naming the field and the file"
inspector_folder "$repo" '{"logSubsystem":"com.example.app"}' "$step"
run "$repo" --
expect "exit code" 1 "$code"
expect "stderr" "{\"code\":\"NO_CONFIG\",\"detail\":\"$repo/.inspector/config.json\",\"message\":\"no \`udid\` in \`config.json\`; run \`inspector init\`\"}" "$err"
expect "xcrun calls" "" "$args"

scenario "a folder without config.json fails with NO_CONFIG, naming both fields"
mkdir -p "$repo/.inspector"
run "$repo" --
expect "exit code" 1 "$code"
expect "stderr" "{\"code\":\"NO_CONFIG\",\"detail\":\"$repo/.inspector/config.json\",\"message\":\"no \`udid\`, \`logSubsystem\` in \`config.json\`; run \`inspector init\`\"}" "$err"

scenario "a config that is not JSON fails with BAD_REQUEST, like the CLI"
inspector_folder "$repo" 'udid=SIM' "$step"
run "$repo" --
expect "exit code" 1 "$code"
expect "code" "BAD_REQUEST" "$(jq -r .code <<<"$err")"
expect "message" "could not read \`$repo/.inspector/config.json\`" "$(jq -r .message <<<"$err")"
expect "xcrun calls" "" "$args"

scenario "without lastStep and without --since it fails with BAD_REQUEST and points to --since"
inspector_folder "$repo" "$config"
run "$repo" --
expect "exit code" 1 "$code"
expect "stderr" "{\"code\":\"BAD_REQUEST\",\"detail\":\"$repo/.inspector/run.json\",\"message\":\"no \`lastStep\` in \`run.json\`; pass \`--since <seconds>\`\"}" "$err"
expect "xcrun calls" "" "$args"

scenario "a lastStep.at that is not a UTC timestamp fails with BAD_REQUEST"
inspector_folder "$repo" "$config" '{"lastStep":{"at":"yesterday"}}'
run "$repo" --
expect "exit code" 1 "$code"
expect "code" "BAD_REQUEST" "$(jq -r .code <<<"$err")"
expect "detail" "yesterday" "$(jq -r .detail <<<"$err")"
expect "xcrun calls" "" "$args"

scenario "a logSubsystem ending in a dot is a prefix"
inspector_folder "$repo" '{"logSubsystem":"com.example.","udid":"SIM-UDID"}' "$step"
run "$repo" --
expect "exit code" 0 "$code"
expect "predicate" '(subsystem BEGINSWITH "com.example.") AND (messageType == error OR messageType == fault)' \
  "$(tail -1 <<<"$args")"

scenario "a logSubsystem that is no reverse-DNS name never reaches the predicate"
inspector_folder "$repo" '{"logSubsystem":"x\" OR 1 == 1 OR \"","udid":"SIM-UDID"}' "$step"
run "$repo" --
expect "exit code" 1 "$code"
expect "code" "BAD_REQUEST" "$(jq -r .code <<<"$err")"
expect "xcrun calls" "" "$args"

scenario "a failing simctl ends in BAD_REQUEST with its message as detail"
inspector_folder "$repo" "$config" "$step"
run "$repo" FAKE_EXIT=149 FAKE_ERROR=$'Unable to lookup in current state: Shutdown\n' --
expect "exit code" 1 "$code"
expect "stderr" '{"code":"BAD_REQUEST","detail":"Unable to lookup in current state: Shutdown","message":"`log show` failed on simulator `SIM-UDID`"}' "$err"

scenario "--help prints the usage on stdout and exits 0"
run "$repo" -- --help
expect "exit code" 0 "$code"
expect "first line" "$usage" "$(head -1 <<<"$out")"
expect "xcrun calls" "" "$args"

if ((failures > 0)); then
  printf '%d failed expectations in %d cases\n' "$failures" "$cases" >&2
  exit 1
fi
printf 'all %d cases passed\n' "$cases"
