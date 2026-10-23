#!/usr/bin/env bash
# Tests for the skill's integrate.sh and remove.sh against throwaway git repos in a temp dir.
# Usage: Tests/SkillScripts/integrate-remove.sh [--no-build] [test name…]
#   --no-build  skip the one test that builds the throwaway app against this package (about 1 min)
# Each repo is a minimal SwiftPM app cloned from a bare "upstream", so `origin/HEAD` names the base
# branch the way it does in a real checkout. Nothing outside the temp dir is touched.
set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
scripts="$repo_root/.claude/skills/inspector/scripts"
skip_build=0
selected=()
for argument in "$@"; do
  case "$argument" in
    --no-build) skip_build=1 ;;
    *) selected+=("$argument") ;;
  esac
done

tmp="$(mktemp -d "${TMPDIR:-/tmp}/inspector-scripts.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
# Throwaway repos get their own git config: no signing, hooks or identity from the user's.
export GIT_CONFIG_GLOBAL="$tmp/gitconfig" GIT_CONFIG_NOSYSTEM=1
git config --file "$GIT_CONFIG_GLOBAL" user.name "Test"
git config --file "$GIT_CONFIG_GLOBAL" user.email "test@example.invalid"
git config --file "$GIT_CONFIG_GLOBAL" init.defaultBranch main
git config --file "$GIT_CONFIG_GLOBAL" advice.detachedHead false

# MARK: - Fixtures

# make_app <dir>: a SwiftPM app on branch `feature/work`, cloned from a bare upstream on `main`.
make_app() {
  local dir="$1" upstream="$1.upstream" seed="$1.seed"
  mkdir -p "$seed/Sources/App"
  cat >"$seed/Package.swift" <<'EOF'
// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "App",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(name: "App", exclude: ["Info.plist"]),
    ]
)
EOF
  cat >"$seed/Sources/App/main.swift" <<'EOF'
print("hello")
EOF
  cat >"$seed/Sources/App/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key>
	<string>App</string>
</dict>
</plist>
EOF
  printf '.build/\n' >"$seed/.gitignore"
  git -C "$seed" init -q
  git -C "$seed" add -A
  git -C "$seed" commit -q -m "Initial app"
  git clone -q --bare "$seed" "$upstream"
  git clone -q "$upstream" "$dir"
  git -C "$dir" checkout -q -b feature/work
  rm -rf "$seed"
}

# make_store <dir> <target path> [env line]: a store folder for one repo, as integrate.sh reads it.
make_store() {
  local dir="$1" target="$2"
  mkdir -p "$dir/$target"
  cat >"$dir/$target/DebugInspector.swift" <<'EOF'
// DEBUG INSPECTOR — the test app's integration.
import InspectorKit

enum DebugInspector {
    static func start() {
        Inspector.shared.state("greeting") { "hello" }
    }
}
EOF
  if [[ $# -ge 3 ]]; then
    printf '%s\n' "$3" >"$dir/$target/.env"
  fi
}

# MARK: - Running and asserting

# run <command…>: runs it, keeping stdout in $out, stderr in $err and the exit code in $status.
run() {
  "$@" >"$tmp/out" 2>"$tmp/err"
  status=$?
  out="$(cat "$tmp/out")"
  err="$(cat "$tmp/err")"
}

failures=0
current=""
fail() {
  echo "  FAIL $current: $*" >&2
  echo "    status: $status" >&2
  echo "    stdout: $out" >&2
  echo "    stderr: $err" >&2
  failures=$((failures + 1))
  return 1
}
expect_status() { [[ "$status" == "$1" ]] || fail "expected exit $1"; }
expect_error() {
  [[ "$status" == 1 ]] || { fail "expected exit 1"; return 1; }
  [[ "$err" == "{\"code\":\"$1\""* ]] || fail "expected one JSON error line with code $1"
}
expect_contains() { [[ "$2" == *"$1"* ]] || fail "expected to contain: $1"; }
expect_not_contains() { [[ "$2" != *"$1"* ]] || fail "expected not to contain: $1"; }
expect_clean_tree() {
  local tree
  tree="$(git -C "$1" status --porcelain --ignored=no)"
  [[ -z "$tree" ]] || fail "expected a clean git status, got: $tree"
}

# MARK: - remove.sh --check

test_check_passes_on_a_clean_branch() {
  make_app "$tmp/app"
  run "$scripts/remove.sh" --check "$tmp/app"
  expect_status 0
  expect_contains '"base":"origin/main"' "$out"
}

test_check_fails_on_a_marker() {
  make_app "$tmp/app"
  printf 'print("debug") // DEBUG INSPECTOR\n' >>"$tmp/app/Sources/App/main.swift"
  run "$scripts/remove.sh" --check "$tmp/app"
  expect_error INTEGRATION_LEFT
  expect_contains '"kind":"marker"' "$err"
  expect_contains 'Sources/App/main.swift:2' "$err"
}

test_check_fails_on_inspectorkit_in_the_diff_against_the_base() {
  make_app "$tmp/app"
  printf '// uses InspectorKit\n' >>"$tmp/app/Sources/App/main.swift"
  git -C "$tmp/app" commit -q -am "Mention it"
  run "$scripts/remove.sh" --check "$tmp/app"
  expect_error INTEGRATION_LEFT
  expect_contains '"kind":"diff"' "$err"
  expect_contains 'Sources/App/main.swift' "$err"
  expect_not_contains '"kind":"marker"' "$err"
}

test_check_fails_on_an_untracked_file_that_imports_inspectorkit() {
  make_app "$tmp/app"
  printf 'import InspectorKit\n' >"$tmp/app/Sources/App/Extra.swift"
  run "$scripts/remove.sh" --check "$tmp/app"
  expect_error INTEGRATION_LEFT
  expect_contains '"kind":"diff"' "$err"
  expect_contains 'Sources/App/Extra.swift' "$err"
}

test_check_ignores_inspectorkit_that_the_base_already_has() {
  make_app "$tmp/app"
  printf '// uses InspectorKit\n' >>"$tmp/app/Sources/App/main.swift"
  git -C "$tmp/app" commit -q -am "Mention it"
  git -C "$tmp/app" push -q origin feature/work:main
  git -C "$tmp/app" fetch -q
  run "$scripts/remove.sh" --check "$tmp/app"
  expect_status 0
}

test_check_fails_on_a_tracked_file_under_dot_inspector() {
  make_app "$tmp/app"
  mkdir "$tmp/app/.inspector"
  printf '{}\n' >"$tmp/app/.inspector/config.json"
  git -C "$tmp/app" add -f .inspector/config.json
  run "$scripts/remove.sh" --check "$tmp/app"
  expect_error INTEGRATION_LEFT
  expect_contains '"kind":"tracked"' "$err"
  expect_contains '.inspector/config.json' "$err"
}

test_check_fails_on_a_package_resolved_changed_by_inspectorkit() {
  make_app "$tmp/app"
  cat >"$tmp/app/Package.resolved" <<'EOF'
{
  "originHash" : "0000",
  "pins" : [
    {
      "identity" : "swift-argument-parser",
      "kind" : "remoteSourceControl",
      "location" : "https://github.com/apple/swift-argument-parser.git",
      "state" : { "revision" : "6a52f3251125d74daf04fcbd5e6f08a75d074382", "version" : "1.8.2" }
    }
  ],
  "version" : 3
}
EOF
  run "$scripts/remove.sh" --check "$tmp/app"
  expect_error INTEGRATION_LEFT
  expect_contains '"kind":"resolved"' "$err"
  expect_contains 'swift-argument-parser' "$err"
}

test_check_takes_the_base_from_the_option() {
  make_app "$tmp/app"
  git -C "$tmp/app" remote remove origin
  run "$scripts/remove.sh" --check "$tmp/app"
  expect_error BASE_NOT_FOUND
  run "$scripts/remove.sh" --check --base main "$tmp/app"
  expect_status 0
  expect_contains '"base":"main"' "$out"
}

test_check_rejects_a_directory_outside_git() {
  mkdir "$tmp/plain"
  run "$scripts/remove.sh" --check "$tmp/plain"
  expect_error NOT_A_REPO
}

test_check_rejects_an_unknown_option_as_usage() {
  run "$scripts/remove.sh" --frobnicate
  expect_status 64
  expect_contains 'Usage:' "$err"
}

# MARK: - Runner

tests=()
if [[ ${#selected[@]} -gt 0 ]]; then
  tests=("${selected[@]}")
else
  while read -r _ _ name; do
    tests+=("$name")
  done < <(declare -F | grep ' test_')
fi

for name in "${tests[@]}"; do
  if [[ $skip_build -eq 1 && "$name" == *_builds* ]]; then
    echo "skip $name"
    continue
  fi
  current="$name"
  before=$failures
  rm -rf "$tmp"/app* "$tmp"/store* "$tmp"/plain "$tmp"/workspace
  status="" out="" err=""
  "$name"
  if [[ $failures -eq $before ]]; then echo "ok   $name"; fi
done

if [[ $failures -gt 0 ]]; then
  echo "$failures failure(s)" >&2
  exit 1
fi
echo "all ${#tests[@]} tests passed"
