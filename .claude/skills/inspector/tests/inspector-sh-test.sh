#!/usr/bin/env bash
# Tests scripts/inspector.sh and the scripts' own location through a symlink, without a real build:
# a copy of the skill sits in a throwaway checkout, reached through a link like
# `~/.claude/skills/inspector`, and fake `swift`, `codesign` and `security` on PATH record what
# they are asked to do. Covers when the CLI is rebuilt, when it is signed, and with what.
# Usage (from the repo root): bash .claude/skills/inspector/tests/inspector-sh-test.sh
# Without `set -e`: a case that fails must not stop the others.
set -uo pipefail

skill="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
sandbox="$(mktemp -d)"
sandbox="$(cd "$sandbox" && pwd -P)"
trap 'rm -rf "$sandbox"' EXIT

checkout="$sandbox/inspector"
binary="$checkout/.build/debug/inspector"
link="$sandbox/skills/inspector"
elsewhere="$sandbox/elsewhere"
calls="$sandbox/calls"

mkdir -p "$sandbox/bin" "$sandbox/skills" "$elsewhere"

# swift: records the call; `build` writes an ad-hoc signed binary that prints its arguments, unless
# FAKE_BUILD_NOOP=1 (an up-to-date build that leaves the binary alone) or FAKE_BUILD_FAIL=1.
cat >"$sandbox/bin/swift" <<'FAKE'
#!/usr/bin/env bash
echo "swift $*" >>"$CALLS"
[[ "$1" == build ]] || exit 0
if [[ "${FAKE_BUILD_FAIL:-0}" == 1 ]]; then
  echo "error: cannot find 'Foo' in scope" >&2
  exit 1
fi
[[ "${FAKE_BUILD_NOOP:-0}" == 1 ]] && exit 0
binary="$3/.build/debug/inspector"
mkdir -p "$(dirname "$binary")"
printf '#!/usr/bin/env bash\nprintf "ran:%%s\\n" "$*"\n' >"$binary"
chmod +x "$binary"
echo inspector >"$binary.id"
FAKE

# codesign: `-dv <file>` reports the identifier from <file>.id on stderr like the real one;
# `--force --sign <id> --identifier <x> <file>` stores <x>.
cat >"$sandbox/bin/codesign" <<'FAKE'
#!/usr/bin/env bash
echo "codesign $*" >>"$CALLS"
if [[ "$1" == -dv ]]; then
  [[ -f "$2.id" ]] || { echo "$2: code object is not signed at all" >&2; exit 1; }
  printf 'Executable=%s\nIdentifier=%s\nFormat=Mach-O thin (arm64)\n' "$2" "$(cat "$2.id")" >&2
  exit 0
fi
file="${*: -1}"
identifier=""
while [[ $# -gt 0 ]]; do
  [[ "$1" == --identifier ]] && identifier="$2"
  shift
done
echo "$identifier" >"$file.id"
FAKE

# security: the keychain's code-signing identities, $FAKE_IDENTITIES when set.
cat >"$sandbox/bin/security" <<'FAKE'
#!/usr/bin/env bash
if [[ -n "${FAKE_IDENTITIES+set}" ]]; then
  printf '%s' "$FAKE_IDENTITIES"
  exit 0
fi
cat <<'LIST'
  1) 1111111111111111111111111111111111111111 "Developer ID Application: Demo (TEAMA)"
  2) 2222222222222222222222222222222222222222 "Apple Development: Demo (PERSONB)"
  3) 3333333333333333333333333333333333333333 "Apple Development: Demo (PERSONC)"
     3 valid identities found
LIST
FAKE
chmod +x "$sandbox/bin/"*

failures=0
cases=0

# checkout_fresh: a new fake inspector checkout with a copy of this skill, every input dated
# January, and the link pointing at its skill.
checkout_fresh() {
  rm -rf "$checkout" "$link"
  mkdir -p "$checkout/Sources/InspectorKit" "$checkout/Sources/inspector" "$checkout/Tests" \
    "$checkout/.claude/skills"
  cp -R "$skill" "$checkout/.claude/skills/inspector"
  rm -rf "$checkout/.claude/skills/inspector/tests"
  echo '// swift-tools-version: 6.3' >"$checkout/Package.swift"
  echo '{}' >"$checkout/Package.resolved"
  echo 'struct Kit {}' >"$checkout/Sources/InspectorKit/Kit.swift"
  echo 'print("cli")' >"$checkout/Sources/inspector/main.swift"
  echo '// test' >"$checkout/Tests/KitTests.swift"
  find "$checkout" -exec touch -t 202601010000 {} +
  ln -s "$checkout/.claude/skills/inspector" "$link"
}

# binary_built <identifier>: a binary from February, signed with <identifier>.
binary_built() {
  mkdir -p "$(dirname "$binary")"
  printf '#!/usr/bin/env bash\nprintf "ran:%%s\\n" "$*"\n' >"$binary"
  chmod +x "$binary"
  echo "$1" >"$binary.id"
  touch -t 202602010000 "$binary" "$(dirname "$binary")"
}

# newer <path…>: dates the paths in March, after the binary.
newer() { touch -t 202603010000 "$@"; }

# run [VAR=value…] -- <script> [arguments…]: runs a script of the linked skill from $elsewhere;
# sets $out, $err, $code and $log (the fakes' calls, one per line).
run() {
  local -a env=()
  while [[ $# -gt 0 && "$1" != -- ]]; do
    env+=("$1")
    shift
  done
  shift
  local script="$1"
  shift
  rm -f "$calls"
  out="$(cd "$elsewhere" && env PATH="$sandbox/bin:$PATH" CALLS="$calls" ${env[@]+"${env[@]}"} \
    "$link/scripts/$script" "$@" 2>"$sandbox/stderr")"
  code=$?
  err="$(cat "$sandbox/stderr")"
  log="$(cat "$calls" 2>/dev/null || true)"
}

# expect <what> <expected> <actual>
expect() {
  if [[ "$2" == "$3" ]]; then
    return 0
  fi
  failures=$((failures + 1))
  printf 'FAIL %s: %s\n  expected: %s\n  actual:   %s\n' "$current" "$1" "$2" "$3" >&2
}

scenario() {
  current="$1"
  cases=$((cases + 1))
  checkout_fresh
}

lines() { printf '%s\n' "$@"; }

identifier=de.juliankahnert.inspector
build="swift build --package-path $checkout --product inspector"
check="codesign -dv $binary"
sign="codesign --force --sign 2222222222222222222222222222222222222222 --identifier $identifier $binary"

scenario "through the link from another directory, a missing binary is built in the linked checkout, signed and run"
run -- inspector.sh --app RoommateAlbert hello
expect "exit code" 0 "$code"
expect "calls" "$(lines "$build" "$check" "$sign")" "$log"
expect "stdout" "ran:--app RoommateAlbert hello" "$out"

scenario "a signed binary newer than every input runs without a build or a signature"
binary_built "$identifier"
run -- inspector.sh state
expect "exit code" 0 "$code"
expect "calls" "$check" "$log"
expect "stdout" "ran:state" "$out"
expect "stderr" "" "$err"

for input in Sources/InspectorKit/Kit.swift Sources/inspector/main.swift Package.swift Package.resolved; do
  scenario "$input newer than the binary: rebuilt and signed before the call"
  binary_built "$identifier"
  newer "$checkout/$input"
  run -- inspector.sh state
  expect "exit code" 0 "$code"
  expect "calls" "$(lines "$build" "$check" "$sign")" "$log"
  expect "stdout" "ran:state" "$out"
done

scenario "a source file deleted since the build: rebuilt"
binary_built "$identifier"
rm "$checkout/Sources/InspectorKit/Kit.swift"
run -- inspector.sh state
expect "calls" "$(lines "$build" "$check" "$sign")" "$log"

scenario "a newer file outside Sources and the manifests does not rebuild"
binary_built "$identifier"
newer "$checkout/Tests/KitTests.swift" "$checkout/.claude/skills/inspector/SKILL.md"
run -- inspector.sh state
expect "calls" "$check" "$log"

scenario "a build that leaves the binary as it was makes it fresh: the next call builds nothing"
binary_built "$identifier"
newer "$checkout/Sources/InspectorKit/Kit.swift"
run FAKE_BUILD_NOOP=1 -- inspector.sh state
expect "first call" "$(lines "$build" "$check")" "$log"
run FAKE_BUILD_NOOP=1 -- inspector.sh state
expect "second call" "$check" "$log"
expect "stdout" "ran:state" "$out"

scenario "a binary rebuilt outside the script (swift build, swift test) is signed again without a build"
binary_built inspector
newer "$binary"
run -- inspector.sh state
expect "calls" "$(lines "$check" "$sign")" "$log"
expect "stdout" "ran:state" "$out"

scenario "INSPECTOR_SIGNING_IDENTITY names the identity to sign with"
run INSPECTOR_SIGNING_IDENTITY="Apple Development: Someone (X)" -- inspector.sh state
expect "calls" "$(lines "$build" "$check" \
  "codesign --force --sign Apple Development: Someone (X) --identifier $identifier $binary")" "$log"

scenario "INSPECTOR_REBUILD=1 builds a fresh binary"
binary_built "$identifier"
run INSPECTOR_REBUILD=1 -- inspector.sh state
expect "calls" "$(lines "$build" "$check" "$sign")" "$log"

scenario "without an Apple Development identity: NO_SIGNING_IDENTITY, and the unsigned binary never runs"
run FAKE_IDENTITIES=$'  1) 1111111111111111111111111111111111111111 "Developer ID Application: Demo (TEAMA)"\n     1 valid identities found\n' \
  -- inspector.sh state
expect "exit code" 1 "$code"
expect "stdout" "" "$out"
expect "stderr" '{"code":"NO_SIGNING_IDENTITY","message":"no \"Apple Development\" signing identity in the keychain; a human adds one in Xcode > Settings > Accounts"}' "$err"

scenario "a failed build ends in BUILD_FAILED after the compiler's output, and the old binary never runs"
binary_built "$identifier"
newer "$checkout/Sources/inspector/main.swift"
run FAKE_BUILD_FAIL=1 -- inspector.sh state
expect "exit code" 1 "$code"
expect "stdout" "" "$out"
expect "calls" "$build" "$log"
expect "stderr" "$(lines "error: cannot find 'Foo' in scope" \
  "{\"code\":\"BUILD_FAILED\",\"detail\":\"$checkout\",\"message\":\"could not build the inspector CLI; the compiler's output is above\"}")" "$err"

scenario "a failure whose detail holds a newline or a control character is still one JSON line"
plain_checkout="$checkout"
checkout="$sandbox/odd"$'\n\x01'"dir"
binary="$checkout/.build/debug/inspector"
checkout_fresh
run FAKE_BUILD_FAIL=1 -- inspector.sh state
expect "exit code" 1 "$code"
expect "detail" "$checkout" "$(tail -n 1 <<<"$err" | jq -j .detail 2>&1)"
rm -rf "$checkout"
checkout="$plain_checkout"
binary="$checkout/.build/debug/inspector"

scenario "through the link, wait-state.sh reaches the CLI"
binary_built "$identifier"
run -- wait-state.sh '.' 1
expect "exit code" 1 "$code"
expect "polled the CLI" "$check" "$(head -1 <<<"$log")"

scenario "through the link, add-to-package.sh adds the linked checkout as the package"
mkdir -p "$sandbox/app"
echo '// swift-tools-version: 6.3' >"$sandbox/app/Package.swift"
run -- add-to-package.sh "$sandbox/app" App
expect "dependency" "swift package --package-path $sandbox/app add-dependency $checkout --type path" \
  "$(sed -n 1p <<<"$log")"
expect "product" "swift package --package-path $sandbox/app add-target-dependency InspectorKit App --package inspector" \
  "$(sed -n 2p <<<"$log")"

scenario "through the link, remove.sh still recognises the inspector checkout and leaves it alone"
git -C "$checkout" init -q
run -- remove.sh "$checkout"
expect "exit code" 1 "$code"
expect "code" "NOT_AN_APP_REPO" "$(jq -r .code <<<"$err" 2>/dev/null)"

if ((failures > 0)); then
  printf '%d failed expectations in %d cases\n' "$failures" "$cases" >&2
  exit 1
fi
printf 'all %d cases passed\n' "$cases"
