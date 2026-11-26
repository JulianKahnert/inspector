#!/usr/bin/env bash
# Tests scripts/route.sh against a fake CLI (INSPECTOR): recording a call log, parsing a route
# (quotes, comments, blank lines), @retry, @has, @lacks, `||` fallbacks, stopping at the first line
# that does not pass, --from/--to, and the routes folder (list, record --save, play by name, the
# store of an ephemeral integration).
# Usage (from the repo root): bash .claude/skills/inspector/tests/route-test.sh
# Without `set -e`: a case that fails must not stop the others.
set -uo pipefail

skill="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
route_sh="$skill/scripts/route.sh"
sandbox="$(mktemp -d)"
trap 'rm -rf "$sandbox"' EXIT
calls="$sandbox/calls"

# The fake CLI: records its arguments one per line, joined by `|`, and answers from $sandbox/rules:
# each line `<args joined by |><TAB><exit><TAB><answer>`; the first line whose args equal the call
# wins. A rule with exit `fail:N` fails the first N times, then passes. No rule: exit 0, `{}`.
cat >"$sandbox/fake" <<'FAKE'
#!/usr/bin/env bash
key="$(IFS='|'; echo "$*")"
echo "$key" >>"$CALLS"
while IFS=$'\t' read -r args code answer; do
  [[ "$args" == "$key" ]] || continue
  if [[ "$code" == fail:* ]]; then
    count_file="$RULES.$(echo "$key" | cksum | cut -d' ' -f1)"
    seen=$(( $(cat "$count_file" 2>/dev/null || echo 0) + 1 ))
    echo "$seen" >"$count_file"
    if (( seen <= ${code#fail:} )); then echo "error: not yet" >&2; exit 1; fi
    code=0
  fi
  [[ "$code" == 0 ]] || echo "error: $answer" >&2
  [[ "$code" == 0 ]] && echo "$answer"
  exit "$code"
done <"$RULES"
echo '{}'
FAKE
chmod +x "$sandbox/fake"
export INSPECTOR="$sandbox/fake" CALLS="$calls" RULES="$sandbox/rules"

failures=0
cases=0

# play_case <route text> <rules text>: plays it; sets $out, $err, $code and resets $calls.
play_case() {
  printf '%s\n' "$1" >"$sandbox/route"
  printf '%s' "$2" >"$RULES"
  rm -f "$calls" "$RULES".*
  : >"$calls"
  out="$(zsh "$route_sh" play "$sandbox/route" "${@:3}" 2>"$sandbox/err")"
  code=$?
  err="$(cat "$sandbox/err")"
}

check() {
  local name="$1" condition="$2"
  cases=$((cases + 1))
  if eval "$condition"; then
    echo "ok   $name"
  else
    failures=$((failures + 1))
    echo "FAIL $name"
    echo "     condition: $condition"
    echo "     exit $code; calls:"; sed 's/^/       /' "$calls"
    echo "     stderr:"; sed 's/^/       /' <<<"$err"
  fi
}

play_case $'# a comment\n\ntap --target \'Sign in\'\n  # indented comment\ntype \'a b\\u{000A}\' --until \'{"x":1}\'' ''
check "parses quotes, skips comments and blank lines" \
  '[[ $code == 0 && "$(cat "$calls")" == $'"'"'tap|--target|Sign in\ntype|a b\\u{000A}|--until|{"x":1}'"'"' ]]'

play_case $'tap 1 2\ntap 3 4\ntap 5 6' $'tap|3|4\t1\tboom\n'
check "stops at the first failing line" \
  '[[ $code == 1 && "$(wc -l <"$calls" | tr -d " ")" == 2 && "$err" == *"line 2 failed"*"tap 3 4"* && "$err" == *boom* ]]'

play_case $'send ui.tap \'"OK"\' || tap --target OK' $'send|ui.tap|"OK"\t1\tno action\n'
check "|| runs the fallback when the first call fails" \
  '[[ $code == 0 && "$(cat "$calls")" == $'"'"'send|ui.tap|"OK"\ntap|--target|OK'"'"' ]]'

play_case $'send ui.tap \'"OK"\' || tap --target OK' ''
check "|| skips the fallback when the first call passes" \
  '[[ $code == 0 && "$(cat "$calls")" == '"'"'send|ui.tap|"OK"'"'"' ]]'

play_case $'@retry 5 tap 1 2' $'tap|1|2\tfail:2\t\n'
check "@retry repeats until the call passes" \
  '[[ $code == 0 && "$(wc -l <"$calls" | tr -d " ")" == 3 ]]'

play_case $'@retry 0.3 tap 1 2' $'tap|1|2\t1\tnever\n'
check "@retry gives up after its seconds" \
  '[[ $code == 1 && "$(wc -l <"$calls" | tr -d " ")" -ge 2 && "$err" == *"line 1 failed"* ]]'

play_case $'@has Go tap 1 2' $'tap|1|2|--targets\t0\t{"targets":[{"label":"Go"}]}\n'
check "@has adds --targets and passes when the name is there" \
  '[[ $code == 0 && "$(cat "$calls")" == "tap|1|2|--targets" ]]'

play_case $'@has Go tap 1 2' $'tap|1|2|--targets\t0\t{"targets":[{"label":"Back"}]}\n'
check "@has fails when the name is missing" '[[ $code == 1 ]]'

play_case $'@retry 5 @lacks Continue tap --target Continue' \
  $'tap|--target|Continue|--targets\t0\t{"targets":[{"identifier":"Continue"}]}\n'
check "@lacks fails while the name is still there" '[[ $code == 1 ]]'

play_case $'@lacks X tap 1 2' $'tap|1|2|--targets\t0\t{"targets":[{"label":"Y"}]}\n'
check "@lacks passes once the name is gone" '[[ $code == 0 ]]'

play_case $'tap 1 1\ntap 2 2\ntap 3 3\ntap 4 4' '' --from 2 --to 3
check "--from/--to play only that part" \
  '[[ $code == 0 && "$(cat "$calls")" == $'"'"'tap|2|2\ntap|3|3'"'"' ]]'

play_case $'tap 1 1' $'tap|1|1\t0\t{"answer":7}\n'
check "prints the last answer" '[[ $code == 0 && "$out" == "{\"answer\":7}" ]]'

play_case $'@bogus 1 tap 1 1' ''
check "an unknown option is a usage error" '[[ $code == 64 && "$err" == *"unknown option @bogus"* ]]'

# record
cat >"$sandbox/calls.jsonl" <<'LOG'
{"at":1,"args":["state"],"exit":0}
{"at":2,"args":["tap","--target","Sign in","--targets"],"exit":0}
{"at":3,"args":["tap","9","9"],"exit":1}
{"at":4,"args":["type","a@b.c\\u{000A}"],"exit":0}
{"at":5,"args":["send","ui.tap","\"OK\""],"exit":0,"caller":"harness"}
{"at":6,"args":["wait","{\"tabs\":{}}","--timeout","9"],"exit":0}
LOG
code=0
out="$(zsh "$route_sh" record "$sandbox/calls.jsonl" 2>"$sandbox/err")" || code=$?
err="$(cat "$sandbox/err")"; : >"$calls"
cat >"$sandbox/expected" <<'EXPECTED'
tap --target 'Sign in'
type 'a@b.c\u{000A}'
wait '{"tabs":{}}' --timeout 9
EXPECTED
check "record keeps passing changes, drops reads, failures, harness calls and --targets" \
  '[[ $code == 0 && "$(sed 1d <<<"$out")" == "$(cat "$sandbox/expected")" ]]'

# A recorded route plays back as recorded.
sed 1d <<<"$out" >"$sandbox/recorded"
play_case "$(cat "$sandbox/recorded")" ''
check "a recorded route plays back with the same arguments" \
  '[[ $code == 0 && "$(cat "$calls")" == $'"'"'tap|--target|Sign in\ntype|a@b.c\\u{000A}\nwait|{"tabs":{}}|--timeout|9'"'"' ]]'

# The routes folder.
# run_route <args…>: runs route.sh in $sandbox/repo; sets $out, $err, $code and resets $calls.
run_route() {
  : >"$calls"; : >"$RULES"
  code=0
  out="$(cd "$sandbox/repo" && zsh "$route_sh" "$@" 2>"$sandbox/err")" || code=$?
  err="$(cat "$sandbox/err")"
}
mkdir -p "$sandbox/repo/.inspector"
git -C "$sandbox/repo" init -q
cp "$sandbox/calls.jsonl" "$sandbox/repo/.inspector/calls.jsonl"

run_route record --save home
check "record --save writes <name>.route to .inspector/routes without an integration" \
  '[[ $code == 0 && "$out" == */.inspector/routes/home.route && "$(sed 1d "$sandbox/repo/.inspector/routes/home.route")" == "$(cat "$sandbox/expected")" ]]'

run_route record --save home
check "record --save never overwrites a route" '[[ $code == 1 && "$err" == *"exists"* ]]'

run_route list
check "list names each saved route with its steps" '[[ $code == 0 && "$out" == *$'"'"'home\t3 steps'"'"'* ]]'

run_route play home
check "play takes a bare name from the routes folder" \
  '[[ $code == 0 && "$(cat "$calls")" == $'"'"'tap|--target|Sign in\ntype|a@b.c\\u{000A}\nwait|{"tabs":{}}|--timeout|9'"'"' ]]'

run_route play nowhere
check "play names the folder when a route is missing" '[[ $code == 1 && "$err" == *"no route \`nowhere\`"*".inspector/routes"* ]]'

# An ephemeral integration: integrate.sh records its store; routes live there, outside the repo.
mkdir -p "$sandbox/store/App" "$sandbox/repo/.inspector/integration"
printf 'file\tApp/DebugInspector.swift\nstore\t%s\n' "$sandbox/store" >"$sandbox/repo/.inspector/integration/record"
run_route record --save settings
check "with an integration's store, record --save writes into the store's routes" \
  '[[ $code == 0 && "$out" == "$sandbox/store/routes/settings.route" && -f "$sandbox/store/routes/settings.route" ]]'

run_route list
check "list shows the store's routes" '[[ "$out" == "# $sandbox/store/routes"* && "$out" == *settings* && "$out" != *home* ]]'

# An older record without a store line: the store's default folder named after the repository.
printf 'file\tApp/DebugInspector.swift\n' >"$sandbox/repo/.inspector/integration/record"
mkdir -p "$sandbox/stores/repo/routes"
printf 'tap 1 1\n' >"$sandbox/stores/repo/routes/old.route"
INSPECTOR_STORE="$sandbox/stores" run_route play old
check "an older record falls back to the store folder named after the repository" '[[ $code == 0 && "$(cat "$calls")" == "tap|1|1" ]]'

INSPECTOR_ROUTES="$sandbox/elsewhere" run_route list
check "INSPECTOR_ROUTES overrides the folder" '[[ "$out" == "# $sandbox/elsewhere" ]]'

echo "$((cases - failures)) of $cases passed"
(( failures == 0 ))
