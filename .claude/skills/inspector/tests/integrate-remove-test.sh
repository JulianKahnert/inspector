#!/usr/bin/env bash
# Tests for the skill's integrate.sh and remove.sh against throwaway git repos in a temp dir.
# Usage (from the repo root): bash .claude/skills/inspector/tests/integrate-remove-test.sh [--no-build] [test name…]
#   --no-build  skip the one test that builds the throwaway app against this package (about 1 min)
# Each repo is a minimal SwiftPM app cloned from a bare "upstream", so `origin/HEAD` names the base
# branch the way it does in a real checkout. Nothing outside the temp dir is touched.
set -uo pipefail

scripts="$(cd "$(dirname "${BASH_SOURCE[0]}")/../scripts" && pwd)"
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
        .executableTarget(
            name: "App",
            exclude: ["Info.plist"]
        ),
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

# MARK: - integrate.sh

test_integrate_places_the_store_file_at_the_path_it_has_in_the_store() {
  make_app "$tmp/app"
  make_store "$tmp/store/app" Sources/App 'VALUE=42'
  run "$scripts/integrate.sh" "$tmp/app" --from "$tmp/store/app"
  expect_status 0
  cmp -s "$tmp/store/app/Sources/App/DebugInspector.swift" "$tmp/app/Sources/App/DebugInspector.swift" ||
    fail "DebugInspector.swift is not the store's"
  expect_contains '"file":"Sources/App/DebugInspector.swift"' "$out"
  expect_contains '"target":"App"' "$out"
}

test_integrate_adds_the_dependency_marked() {
  make_app "$tmp/app"
  make_store "$tmp/store/app" Sources/App
  run "$scripts/integrate.sh" "$tmp/app" --from "$tmp/store/app"
  expect_status 0
  expect_contains '"dependency":"Package.swift"' "$out"
  expect_contains '.product(name: "InspectorKit"' "$(grep 'DEBUG INSPECTOR' "$tmp/app/Package.swift")"
  expect_contains '.package(path:' "$(grep 'DEBUG INSPECTOR' "$tmp/app/Package.swift")"
}

test_integrate_adds_the_two_plist_keys_marked() {
  make_app "$tmp/app"
  make_store "$tmp/store/app" Sources/App
  run "$scripts/integrate.sh" "$tmp/app" --from "$tmp/store/app"
  expect_status 0
  local plist="$tmp/app/Sources/App/Info.plist"
  expect_contains '"plist":"Sources/App/Info.plist"' "$out"
  plutil -lint -s "$plist" || fail "Info.plist does not lint"
  [[ "$(plutil -extract NSBonjourServices.0 raw "$plist")" == "_inspector._tcp" ]] || fail "no _inspector._tcp"
  plutil -extract NSLocalNetworkUsageDescription raw "$plist" >/dev/null || fail "no usage description"
  [[ "$(grep -c '<!-- DEBUG INSPECTOR -->' "$plist")" == 2 ]] || fail "expected two plist markers"
}

test_integrate_adds_to_an_existing_bonjour_list() {
  make_app "$tmp/app"
  local plist="$tmp/app/Sources/App/Info.plist"
  perl -0pi -e 's{</dict>\n</plist>}{\t<key>NSBonjourServices</key>\n\t<array>\n\t\t<string>_other._tcp</string>\n\t</array>\n</dict>\n</plist>}' "$plist"
  git -C "$tmp/app" commit -q -am "Use Bonjour"
  make_store "$tmp/store/app" Sources/App
  run "$scripts/integrate.sh" "$tmp/app" --from "$tmp/store/app"
  expect_status 0
  plutil -lint -s "$plist" || fail "Info.plist does not lint"
  [[ "$(plutil -extract NSBonjourServices.0 raw "$plist")" == "_inspector._tcp" ]] || fail "no _inspector._tcp"
  [[ "$(plutil -extract NSBonjourServices.1 raw "$plist")" == "_other._tcp" ]] || fail "lost _other._tcp"
  run "$scripts/remove.sh" "$tmp/app"
  expect_status 0
  expect_clean_tree "$tmp/app"
}

test_integrate_copies_the_env_and_excludes_the_folder() {
  make_app "$tmp/app"
  make_store "$tmp/store/app" Sources/App 'VALUE=42'
  run "$scripts/integrate.sh" "$tmp/app" --from "$tmp/store/app"
  expect_status 0
  [[ "$(cat "$tmp/app/.inspector/.env")" == "VALUE=42" ]] || fail ".env not copied"
  expect_contains '"env":".inspector/.env"' "$out"
  expect_contains '/.inspector/' "$(cat "$tmp/app/.git/info/exclude")"
  expect_not_contains '.inspector' "$(git -C "$tmp/app" status --porcelain)"
}

test_integrate_without_from_copies_the_template() {
  make_app "$tmp/app"
  run "$scripts/integrate.sh" "$tmp/app" --into Sources/App
  expect_status 0
  cmp -s "$scripts/../assets/DebugInspector.swift" "$tmp/app/Sources/App/DebugInspector.swift" ||
    fail "DebugInspector.swift is not the template"
  expect_contains '"env":null' "$out"
}

test_integrate_needs_from_or_into() {
  make_app "$tmp/app"
  run "$scripts/integrate.sh" "$tmp/app"
  expect_status 64
  expect_contains 'Usage:' "$err"
}

test_integrate_rejects_a_store_without_the_file() {
  make_app "$tmp/app"
  mkdir -p "$tmp/store/app/Sources/App"
  run "$scripts/integrate.sh" "$tmp/app" --from "$tmp/store/app"
  expect_error STORE_INVALID
}

test_integrate_rejects_a_store_with_two_files() {
  make_app "$tmp/app"
  make_store "$tmp/store/app" Sources/App
  make_store "$tmp/store/app" Sources/Other
  run "$scripts/integrate.sh" "$tmp/app" --from "$tmp/store/app"
  expect_error STORE_INVALID
}

test_integrate_rejects_a_target_the_repo_lacks() {
  make_app "$tmp/app"
  make_store "$tmp/store/app" Sources/Missing
  run "$scripts/integrate.sh" "$tmp/app" --from "$tmp/store/app"
  expect_error TARGET_DIR_MISSING
  expect_clean_tree "$tmp/app"
}

test_integrate_refuses_a_second_run() {
  make_app "$tmp/app"
  make_store "$tmp/store/app" Sources/App
  run "$scripts/integrate.sh" "$tmp/app" --from "$tmp/store/app"
  run "$scripts/integrate.sh" "$tmp/app" --from "$tmp/store/app"
  expect_error ALREADY_INTEGRATED
}

test_integrate_rolls_back_when_a_step_fails() {
  make_app "$tmp/app"
  printf 'not a plist\n' >"$tmp/app/notes.txt"
  git -C "$tmp/app" add notes.txt
  git -C "$tmp/app" commit -q -m "Notes"
  make_store "$tmp/store/app" Sources/App
  run "$scripts/integrate.sh" "$tmp/app" --from "$tmp/store/app" --plist notes.txt
  expect_error PLIST_INVALID
  expect_clean_tree "$tmp/app"
  [[ ! -e "$tmp/app/.inspector" ]] || fail ".inspector/ left behind"
  expect_not_contains 'inspector' "$(cat "$tmp/app/.git/info/exclude")"
}

# make_project_app <dir>: an app target in an Xcode project (no manifest above it) and a local
# wrapper package next to it, the way an app links its packages through one local package.
make_project_app() {
  local dir="$1"
  make_app "$dir"
  git -C "$dir" mv Package.swift Wrapper.swift
  mkdir -p "$dir/App.xcodeproj" "$dir/Wrapper/Sources/Wrapper"
  printf '// !$*UTF8*$!\n{\n\tobjects = {\n\t};\n}\n' >"$dir/App.xcodeproj/project.pbxproj"
  git -C "$dir" mv Wrapper.swift Wrapper/Package.swift
  perl -pi -e 's/name: "App",/name: "Wrapper",/g; s/^\s*exclude: \["Info.plist"\]\n//' "$dir/Wrapper/Package.swift"
  printf 'public enum Wrapper {}\n' >"$dir/Wrapper/Sources/Wrapper/Wrapper.swift"
  git -C "$dir" add -A
  git -C "$dir" commit -q -m "Move the app into an Xcode project"
}

test_integrate_stops_for_a_project_target_with_the_one_manual_step() {
  make_project_app "$tmp/app"
  make_store "$tmp/store/app" Sources/App
  run "$scripts/integrate.sh" "$tmp/app" --from "$tmp/store/app"
  expect_error NEEDS_PROJECT_DEPENDENCY
  expect_contains 'Add Local' "$err"
  expect_clean_tree "$tmp/app"
}

test_integrate_goes_through_a_wrapper_package_for_a_project_target() {
  make_project_app "$tmp/app"
  make_store "$tmp/store/app" Sources/App
  run "$scripts/integrate.sh" "$tmp/app" --from "$tmp/store/app" --package Wrapper --package-target Wrapper
  expect_status 0
  expect_contains '"dependency":"Wrapper/Package.swift"' "$out"
  expect_contains 'InspectorKit' "$(grep 'DEBUG INSPECTOR' "$tmp/app/Wrapper/Package.swift")"
  run "$scripts/remove.sh" "$tmp/app"
  expect_status 0
  expect_clean_tree "$tmp/app"
}

test_integrate_takes_a_project_dependency_added_by_hand() {
  make_project_app "$tmp/app"
  perl -pi -e 's/objects = \{/objects = {\n\t\tAAAA \/* InspectorKit *\/ = {isa = XCSwiftPackageProductDependency; productName = InspectorKit; };/' \
    "$tmp/app/App.xcodeproj/project.pbxproj"
  make_store "$tmp/store/app" Sources/App
  run "$scripts/integrate.sh" "$tmp/app" --from "$tmp/store/app"
  expect_status 0
  expect_contains '"dependency":"App.xcodeproj/project.pbxproj"' "$out"
  run "$scripts/remove.sh" "$tmp/app"
  expect_status 0
  expect_clean_tree "$tmp/app"
}

# MARK: - remove.sh

test_round_trip_leaves_no_diff_and_no_exclude_entry() {
  make_app "$tmp/app"
  make_store "$tmp/store/app" Sources/App 'VALUE=42'
  run "$scripts/integrate.sh" "$tmp/app" --from "$tmp/store/app"
  expect_status 0
  printf 'DebugInspector.start() // DEBUG INSPECTOR\n' >>"$tmp/app/Sources/App/main.swift"
  run "$scripts/remove.sh" --check "$tmp/app"
  expect_error INTEGRATION_LEFT
  run "$scripts/remove.sh" "$tmp/app"
  expect_status 0
  expect_contains '"deleted":["Sources/App/DebugInspector.swift"]' "$out"
  expect_contains 'Sources/App/main.swift:2' "$out"
  run "$scripts/remove.sh" --check "$tmp/app"
  expect_status 0
  expect_clean_tree "$tmp/app"
  [[ ! -e "$tmp/app/.inspector" ]] || fail ".inspector/ left behind"
  ! grep -q -v '^#' "$tmp/app/.git/info/exclude" || fail "exclude entry left behind"
}

test_round_trip_builds_against_this_package() {
  make_app "$tmp/app"
  make_store "$tmp/store/app" Sources/App
  run "$scripts/integrate.sh" "$tmp/app" --from "$tmp/store/app"
  expect_status 0
  printf 'DebugInspector.start() // DEBUG INSPECTOR\n' >>"$tmp/app/Sources/App/main.swift"
  run swift build --package-path "$tmp/app"
  expect_status 0
  run "$scripts/remove.sh" --check "$tmp/app"
  expect_error INTEGRATION_LEFT
  expect_contains '"kind":"resolved"' "$err"
  run "$scripts/remove.sh" "$tmp/app"
  expect_status 0
  run "$scripts/remove.sh" --check "$tmp/app"
  expect_status 0
  expect_clean_tree "$tmp/app"
}

test_remove_runs_over_every_repo_below_the_workspace_root() {
  mkdir "$tmp/workspace"
  make_app "$tmp/workspace/one"
  make_app "$tmp/workspace/two"
  make_store "$tmp/store/app" Sources/App
  run "$scripts/integrate.sh" "$tmp/workspace/one" --from "$tmp/store/app"
  run "$scripts/integrate.sh" "$tmp/workspace/two" --from "$tmp/store/app"
  cd "$tmp/workspace" || return
  run "$scripts/remove.sh"
  cd - >/dev/null || return
  expect_status 0
  expect_clean_tree "$tmp/workspace/one"
  expect_clean_tree "$tmp/workspace/two"
}

test_remove_takes_out_marked_lines_without_a_record() {
  make_app "$tmp/app"
  make_store "$tmp/store/app" Sources/App
  run "$scripts/integrate.sh" "$tmp/app" --from "$tmp/store/app"
  printf 'DebugInspector.start() // DEBUG INSPECTOR\n' >>"$tmp/app/Sources/App/main.swift"
  rm -rf "$tmp/app/.inspector"
  run "$scripts/remove.sh" "$tmp/app"
  expect_status 0
  [[ ! -e "$tmp/app/Sources/App/DebugInspector.swift" ]] || fail "file left behind"
  git -C "$tmp/app" diff --quiet HEAD -- Sources/App/Info.plist Sources/App/main.swift ||
    fail "Info.plist or main.swift still differ: $(git -C "$tmp/app" diff HEAD)"
  expect_contains 'no record from integrate.sh' "$out"
  run "$scripts/remove.sh" --check "$tmp/app"
  expect_status 0
}

test_remove_keeps_a_tracked_file_with_the_marker_on_its_first_line() {
  make_app "$tmp/app"
  local main="$tmp/app/Sources/App/main.swift"
  { printf 'import InspectorKit // DEBUG INSPECTOR\n'; git -C "$tmp/app" show HEAD:Sources/App/main.swift; } >"$main.new"
  mv "$main.new" "$main"
  run "$scripts/remove.sh" --check "$tmp/app"
  expect_error INTEGRATION_LEFT
  expect_contains 'Sources/App/main.swift:1' "$err"
  run "$scripts/remove.sh" "$tmp/app"
  expect_status 0
  [[ -f "$main" ]] || fail "tracked main.swift was deleted"
  expect_contains '"deleted":[]' "$out"
  expect_contains 'Sources/App/main.swift:1' "$out"
  run "$scripts/remove.sh" --check "$tmp/app"
  expect_status 0
  expect_clean_tree "$tmp/app"
}

test_remove_deletes_an_untracked_file_with_the_marker_on_its_first_line() {
  make_app "$tmp/app"
  printf '// DEBUG INSPECTOR\nimport InspectorKit\n' >"$tmp/app/Sources/App/Extra.swift"
  run "$scripts/remove.sh" "$tmp/app"
  expect_status 0
  [[ ! -e "$tmp/app/Sources/App/Extra.swift" ]] || fail "untracked Extra.swift left behind"
  expect_contains '"deleted":["Sources/App/Extra.swift"]' "$out"
  run "$scripts/remove.sh" --check "$tmp/app"
  expect_status 0
  expect_clean_tree "$tmp/app"
}

test_remove_keeps_the_exclude_entry_while_another_worktree_is_integrated() {
  make_app "$tmp/app"
  git -C "$tmp/app" worktree add -q -b other "$tmp/app-other"
  make_store "$tmp/store/app" Sources/App
  run "$scripts/integrate.sh" "$tmp/app" --from "$tmp/store/app"
  run "$scripts/integrate.sh" "$tmp/app-other" --from "$tmp/store/app"
  run "$scripts/remove.sh" "$tmp/app"
  expect_status 0
  expect_not_contains '.inspector' "$(git -C "$tmp/app-other" status --porcelain)"
  run "$scripts/remove.sh" "$tmp/app-other"
  expect_clean_tree "$tmp/app-other"
  ! grep -q -v '^#' "$tmp/app/.git/info/exclude" || fail "exclude entry left behind"
}

# init_binding <repo>: what `inspector init` leaves: its marked exclude entry and `.inspector/`.
init_binding() {
  local exclude
  exclude="$(git -C "$1" rev-parse --path-format=absolute --git-path info/exclude)"
  mkdir -p "$1/.inspector"
  printf '{"session":"inspector-app-1"}\n' >"$1/.inspector/config.json"
  printf '# DEBUG INSPECTOR\n/.inspector/\n' >>"$exclude"
}

test_round_trip_after_init_leaves_no_exclude_entry() {
  make_app "$tmp/app"
  init_binding "$tmp/app"
  make_store "$tmp/store/app" Sources/App
  run "$scripts/integrate.sh" "$tmp/app" --from "$tmp/store/app"
  expect_status 0
  run "$scripts/remove.sh" "$tmp/app"
  expect_status 0
  expect_clean_tree "$tmp/app"
  expect_not_contains 'inspector' "$(cat "$tmp/app/.git/info/exclude")"
}

test_remove_keeps_the_exclude_entry_while_another_worktree_has_a_session() {
  make_app "$tmp/app"
  git -C "$tmp/app" worktree add -q -b other "$tmp/app-other"
  init_binding "$tmp/app-other"
  make_store "$tmp/store/app" Sources/App
  run "$scripts/integrate.sh" "$tmp/app" --from "$tmp/store/app"
  run "$scripts/remove.sh" "$tmp/app"
  expect_status 0
  expect_contains 'kept the .inspector/ exclude entry' "$out"
  expect_not_contains '.inspector' "$(git -C "$tmp/app-other" status --porcelain)"
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
