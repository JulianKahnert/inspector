#!/usr/bin/env bash
# Adds an ephemeral debug integration to an app repository, for remove.sh to take out again.
# Usage: integrate.sh <repo dir> --from <store dir> [options]
#        integrate.sh <repo dir> --into <target path> [options]
#   --from <dir>             the repository's folder in the store,
#                            ~/.claude/inspector/integrations/<repo>; the one DebugInspector.swift
#                            below it goes to the same path in the repository, its .env to
#                            .inspector/.env
#   --into <path>            without a store: copy the skill's template into this target directory
#   --plist <path>           the Info.plist to add the two keys to (default: <target>/Info.plist)
#   --package <dir>          add InspectorKit to this local package instead of the manifest above
#   --package-target <name>  the target in that package (default: from the Sources/<name> path)
#   --ios-only               link InspectorKit on iOS only
#   --check-build            then build, to prove the integration compiles against this checkout
#                            and the package versions it pins; a stored file can be older or newer
#                            than the checkout's code. Costs one build of the app scheme.
#   --scheme <name>          the scheme to build (default: the one shared scheme, or the one named
#                            like the workspace or project)
#   --workspace <path>       the .xcworkspace or .xcodeproj to build, when the repository has several
#   --destination <spec>     xcodebuild's -destination (default: generic/platform=iOS Simulator)
# Paths are relative to the repository. Answer: one JSON document on stdout. Failure: one JSON
# line with `code` on stderr, exit 1, and nothing left changed; a failed --check-build is the
# exception and leaves the integration in place, for remove.sh. Usage error: exit 64.
set -euo pipefail
scripts_dir="$(dirname "${BASH_SOURCE[0]}")"
# shellcheck source=lib/common.sh
source "$scripts_dir/lib/common.sh"
# shellcheck source=lib/removal.sh
source "$scripts_dir/lib/removal.sh"

usage='Usage: integrate.sh <repo dir> --from <store dir> [--plist <path>] [--package <dir>] [--package-target <name>] [--ios-only]
                      [--check-build [--scheme <name>] [--workspace <path>] [--destination <spec>]]
       integrate.sh <repo dir> --into <target path> [same options]'

repo_dir=""
from=""
into=""
plist_option=""
package_option=""
package_target=""
ios_only=0
check_build=0
scheme_option=""
workspace_option=""
destination_option=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --from | --into | --plist | --package | --package-target | --scheme | --workspace | --destination)
      [[ $# -ge 2 ]] || usage_error "$1 needs a value"
      case "$1" in
        --from) from="$2" ;;
        --into) into="$2" ;;
        --plist) plist_option="$2" ;;
        --package) package_option="$2" ;;
        --package-target) package_target="$2" ;;
        --scheme) scheme_option="$2" ;;
        --workspace) workspace_option="$2" ;;
        --destination) destination_option="$2" ;;
      esac
      shift
      ;;
    --ios-only) ios_only=1 ;;
    --check-build) check_build=1 ;;
    -h | --help)
      printf '%s\n' "$usage"
      exit 0
      ;;
    -*) usage_error "unknown option $1" ;;
    *)
      [[ -z "$repo_dir" ]] || usage_error "one repo dir only"
      repo_dir="$1"
      ;;
  esac
  shift
done
[[ -n "$repo_dir" ]] || usage_error "missing <repo dir>"
[[ -n "$from" || -n "$into" ]] || usage_error "pass --from <store dir>, or --into <target path> for the template"
[[ -z "$from" || -z "$into" ]] || usage_error "--from and --into exclude each other"
[[ -z "$package_option" || -n "$package_target" ]] || usage_error "--package needs --package-target"
[[ $check_build -eq 1 || -z "$scheme_option$workspace_option$destination_option" ]] ||
  usage_error "--scheme, --workspace and --destination only go with --check-build"

root="$(require_app_repo "$repo_dir")" || exit 1
state="$root/.inspector/integration"
[[ ! -e "$state" ]] || fail ALREADY_INTEGRATED "$root is integrated already; run remove.sh first" "$(json_str "$root")"

# repo_path <path>: a path relative to the repository, or fail with a usage error.
repo_path() {
  local path="${1#./}"
  path="${path%/}"
  [[ "$path" != /* && "/$path/" != */../* ]] || usage_error "$1 has to be a path inside the repository"
  printf '%s\n' "$path"
}

json_or_null() { if [[ -n "$1" ]]; then json_str "$1"; else printf 'null'; fi; }

# MARK: - Plan: work out every change before making the first one

env_file=""
if [[ -n "$from" ]]; then
  [[ -d "$from" ]] || fail STORE_INVALID "no store folder at $from" "$(json_str "$from")"
  store="$(cd "$from" && pwd)"
  sources=()
  while IFS= read -r -d '' found; do
    sources+=("$found")
  done < <(find "$store" -name .git -prune -o -type f -name DebugInspector.swift -print0)
  [[ ${#sources[@]} -gt 0 ]] ||
    fail STORE_INVALID "no DebugInspector.swift below $store; it goes under the path it has in the repository" "$(json_str "$store")"
  [[ ${#sources[@]} -eq 1 ]] ||
    fail STORE_INVALID "several DebugInspector.swift below $store; keep one per repository" "$(json_strings "${sources[@]}")"
  source_file="${sources[0]}"
  target_path="$(dirname "${source_file#"$store"/}")"
  [[ "$target_path" != "." ]] ||
    fail STORE_INVALID "DebugInspector.swift lies directly in $store; put it under the path it has in the repository" "$(json_str "$source_file")"
  [[ ! -f "$(dirname "$source_file")/.env" ]] || env_file="$(dirname "$source_file")/.env"
else
  target_path="$(repo_path "$into")"
  source_file="$skill_dir/assets/DebugInspector.swift"
fi
target_dir="$root/$target_path"
[[ -d "$target_dir" ]] || fail TARGET_DIR_MISSING "$root has no directory $target_path" "$(json_str "$target_path")"
file_path="$target_path/DebugInspector.swift"
[[ ! -e "$root/$file_path" ]] || fail ALREADY_INTEGRATED "$file_path exists already" "$(json_str "$file_path")"

# The dependency: the given local package, else the manifest above the target, else an Xcode
# project whose diff already adds InspectorKit (added by hand in Xcode).
package_dir=""
project_files=()
if [[ -n "$package_option" ]]; then
  package_dir="$(repo_path "$package_option")"
  # `.` is the repository itself; "$root/." would record the manifest as ./Package.swift, a path
  # git apply cannot reverse.
  if [[ -z "$package_dir" || "$package_dir" == "." ]]; then package_dir="$root"; else package_dir="$root/$package_dir"; fi
  [[ -f "$package_dir/Package.swift" ]] ||
    fail PACKAGE_NOT_FOUND "no Package.swift in $package_option" "$(json_str "$package_option")"
else
  dir="$target_dir"
  while :; do
    if [[ -f "$dir/Package.swift" ]]; then
      package_dir="$dir"
      break
    fi
    [[ "$dir" != "$root" ]] || break
    dir="$(dirname "$dir")"
  done
  if [[ -n "$package_dir" && -z "$package_target" ]]; then
    inside="${target_dir#"$package_dir"/}"
    [[ "$inside" == Sources/* ]] ||
      fail TARGET_UNKNOWN "$target_path is not under Sources/<target> of its package; pass --package-target" "$(json_str "$target_path")"
    package_target="${inside#Sources/}"
    package_target="${package_target%%/*}"
  fi
  if [[ -z "$package_dir" ]]; then
    while IFS= read -r project; do
      if git -C "$root" diff --no-color HEAD -- "$project" | grep -q '^+.*InspectorKit'; then
        project_files+=("$project")
      fi
    done < <(git -C "$root" diff --name-only HEAD -- '*.pbxproj')
    [[ ${#project_files[@]} -gt 0 ]] ||
      fail NEEDS_PROJECT_DEPENDENCY "$target_path belongs to an Xcode project target, and a script cannot edit a project file safely. One step by hand: in Xcode, File > Add Package Dependencies > Add Local, choose $inspector_root and add the InspectorKit product to that target; then run integrate.sh again. Or pass --package <a local package the app links> --package-target <its target>." \
        "$(json_str "$target_path")"
  fi
fi

plist=""
if [[ -n "$plist_option" ]]; then
  plist="$(repo_path "$plist_option")"
  [[ -f "$root/$plist" ]] || fail PLIST_NOT_FOUND "no file $plist" "$(json_str "$plist")"
elif [[ -f "$target_dir/Info.plist" ]]; then
  plist="$target_path/Info.plist"
fi

# The build for --check-build: xcodebuild on the one workspace, else the one project (the lookup
# `inspector init` does), else SwiftPM on the package around the target.
build_dir=""
build_command=()
if [[ $check_build -eq 1 ]]; then
  # build_unknown <message> [names…]: what to build is unclear; fail before changing anything.
  build_unknown() {
    local message="$1"
    shift
    fail BUILD_UNKNOWN "$message" "$(json_strings "$@")"
  }
  skip_dirs=(\( -name '.*' -o -name Pods -o -name Carthage -o -name DerivedData -o -name node_modules -o -name build \) -prune)
  containers=()
  if [[ -n "$workspace_option" ]]; then
    container="$(repo_path "$workspace_option")"
    [[ -d "$root/$container" && ("$container" == *.xcworkspace || "$container" == *.xcodeproj) ]] ||
      build_unknown "no .xcworkspace or .xcodeproj at $workspace_option" "$workspace_option"
    containers=("$container")
  else
    workspaces=()
    projects=()
    while IFS= read -r -d '' found; do
      found="${found#"$root"/}"
      if [[ "$found" == *.xcworkspace ]]; then workspaces+=("$found"); else projects+=("$found"); fi
    done < <(find "$root" -mindepth 1 -maxdepth 4 "${skip_dirs[@]}" -o \
      \( -name '*.xcworkspace' -o -name '*.xcodeproj' \) -type d -print0 -prune)
    if [[ ${#workspaces[@]} -gt 0 ]]; then
      containers=("${workspaces[@]}")
    elif [[ ${#projects[@]} -gt 0 ]]; then
      containers=("${projects[@]}")
    fi
    [[ ${#containers[@]} -le 1 ]] ||
      build_unknown "several Xcode workspaces or projects in $root; pass --workspace <path>" "${containers[@]}"
  fi
  destination="${destination_option:-generic/platform=iOS Simulator}"
  if [[ ${#containers[@]} -eq 1 ]]; then
    container="${containers[0]}"
    scheme="$scheme_option"
    if [[ -z "$scheme" ]]; then
      # The shared schemes in the repository; one Xcode generates without sharing it needs --scheme.
      schemes=()
      while IFS= read -r name; do
        schemes+=("$name")
      done < <(find "$root" -mindepth 1 -maxdepth 7 "${skip_dirs[@]}" -o \
        -path '*/xcshareddata/xcschemes/*.xcscheme' -print | sed 's|.*/||; s|\.xcscheme$||' | sort -u)
      base="$(basename "$container")"
      base="${base%.*}"
      if [[ ${#schemes[@]} -eq 1 ]]; then
        scheme="${schemes[0]}"
      else
        for name in ${schemes[@]+"${schemes[@]}"}; do
          [[ "$name" != "$base" ]] || scheme="$name"
        done
      fi
      [[ -n "$scheme" ]] ||
        build_unknown "cannot tell which scheme builds the app in $container; pass --scheme <name> (xcodebuild -list names them)" \
          ${schemes[@]+"${schemes[@]}"}
    fi
    kind=-project
    [[ "$container" != *.xcworkspace ]] || kind=-workspace
    build_dir="$root"
    build_command=(xcodebuild "$kind" "$container" -scheme "$scheme" -destination "$destination" build)
  else
    build_dir="${package_dir:-$root}"
    [[ -f "$build_dir/Package.swift" ]] ||
      build_unknown "no Xcode workspace, project or Package.swift to build in $root; pass --workspace <path>"
    if [[ -n "$scheme_option" ]]; then
      # A package that builds only for iOS: xcodebuild builds it for the destination.
      build_command=(xcodebuild -scheme "$scheme_option" -destination "$destination" build)
    elif [[ -n "$package_target" ]]; then
      build_command=(swift build --target "$package_target")
    else
      build_command=(swift build)
    fi
  fi
fi

# MARK: - Apply, rolling everything back on any failure

mkdir -p "$state/patches" "$state/copies"
record="$state/record"
: >"$record"

# abort <code> <message> [detail]: undo what was done so far, then fail.
abort() {
  trap - ERR
  remove_integration "$root" >/dev/null 2>&1 || true
  fail "$@"
}
trap 'abort INTEGRATE_FAILED "integrate.sh failed at line $LINENO; nothing was left changed" "$(json_str "$root")"' ERR

# save_patch <copy of the original> <path in the repo> <patch name>: records the edit as a patch.
save_patch() {
  local status=0
  diff -u --label "a/$2" --label "b/$2" "$1" "$root/$2" >"$state/patches/$3" || status=$?
  [[ $status -le 1 ]] || abort INTEGRATE_FAILED "could not record the change to $2" "$(json_str "$2")"
  [[ $status -eq 0 ]] || printf 'patch\t%s\tpatches/%s\n' "$2" "$3" >>"$record"
}

# 1. Keep .inspector/ out of git, unless something ignores it already.
if ! git -C "$root" check-ignore -q .inspector/record; then
  exclude="$(exclude_file "$root")"
  mkdir -p "$(dirname "$exclude")"
  if [[ -s "$exclude" && -n "$(tail -c 1 "$exclude")" ]]; then printf '\n' >>"$exclude"; fi
  printf '# DEBUG INSPECTOR\n/.inspector/\n' >>"$exclude"
  printf 'exclude\n' >>"$record"
fi

# 2. Every Package.resolved as it is now, so remove.sh can drop the pins a build adds.
count=0
while IFS= read -r resolved; do
  count=$((count + 1))
  cp "$root/$resolved" "$state/copies/resolved-$count"
  printf 'resolved\t%s\tcopies/resolved-%s\n' "$resolved" "$count" >>"$record"
done < <(resolved_files "$root")

# 3. The integration file.
cp "$source_file" "$root/$file_path"
printf 'file\t%s\n' "$file_path" >>"$record"

# 4. The dependency.
dependency=""
if [[ -n "$package_dir" ]]; then
  manifest="${package_dir#"$root"/}/Package.swift"
  [[ "$package_dir" != "$root" ]] || manifest="Package.swift"
  if grep -q InspectorKit "$package_dir/Package.swift"; then
    notes_dependency="$manifest has InspectorKit already and was left as it is"
  else
    cp "$package_dir/Package.swift" "$state/copies/manifest"
    flags=()
    [[ $ios_only -eq 0 ]] || flags+=(--ios-only)
    output="$("$scripts_dir/add-to-package.sh" "$package_dir" "$package_target" ${flags[@]+"${flags[@]}"} 2>&1)" ||
      abort DEPENDENCY_FAILED "could not add InspectorKit to target $package_target in $manifest" "$(json_str "$output")"
    save_patch "$state/copies/manifest" "$manifest" manifest.patch
    dependency="$manifest"
  fi
else
  count=0
  for project in "${project_files[@]}"; do
    count=$((count + 1))
    git -C "$root" diff --no-color --no-ext-diff --src-prefix=a/ --dst-prefix=b/ HEAD -- "$project" \
      >"$state/patches/project-$count.patch"
    printf 'patch\t%s\tpatches/project-%s.patch\n' "$project" "$count" >>"$record"
  done
  dependency="${project_files[0]}"
fi

# 5. The two Info.plist keys, each after a marker comment.
if [[ -n "$plist" ]]; then
  [[ "$(head -c 6 "$root/$plist")" != "bplist" ]] ||
    abort PLIST_INVALID "$plist is a binary plist; convert it with plutil -convert xml1 first" "$(json_str "$plist")"
  cp "$root/$plist" "$state/copies/plist"
  perl -0 -e '
    local $/; my $text = <STDIN>;
    my ($indent) = $text =~ /^([ \t]+)<key>/m; $indent //= "\t";
    my $m = "<!-- DEBUG INSPECTOR -->";
    if ($text =~ /<key>NSBonjourServices<\/key>/) {
      if ($text !~ /_inspector\._tcp/) {
        $text =~ s{(<key>NSBonjourServices</key>[ \t]*\n[ \t]*<array>[ \t]*\n)([ \t]*)}{$1$2$m\n$2<string>_inspector._tcp</string>\n$2} or exit 2;
      }
    } else {
      $text =~ s{\n(</dict>\s*</plist>\s*)\z}{\n$indent$m\n$indent<key>NSBonjourServices</key>\n$indent<array>\n$indent$indent<string>_inspector._tcp</string>\n$indent</array>\n$1} or exit 2;
    }
    if ($text !~ /<key>NSLocalNetworkUsageDescription<\/key>/) {
      $text =~ s{\n(</dict>\s*</plist>\s*)\z}{\n$indent$m\n$indent<key>NSLocalNetworkUsageDescription</key>\n$indent<string>Lets the inspector CLI read and drive this debug build.</string>\n$1} or exit 2;
    }
    print $text;
  ' <"$state/copies/plist" >"$state/copies/plist.new" ||
    abort PLIST_INVALID "$plist is not an XML property list with a top-level dict" "$(json_str "$plist")"
  cp "$state/copies/plist.new" "$root/$plist"
  plutil -lint -s "$root/$plist" >/dev/null 2>&1 ||
    abort PLIST_INVALID "$plist does not lint after adding the keys" "$(json_str "$plist")"
  save_patch "$state/copies/plist" "$plist" plist.patch
fi

# 6. The values for ${NAME} in send payloads.
env_path=""
if [[ -n "$env_file" ]]; then
  cp "$env_file" "$root/.inspector/.env"
  chmod 600 "$root/.inspector/.env"
  env_path=".inspector/.env"
fi
trap - ERR

# 7. --check-build: build, and name what of the integration does not compile against this checkout.
build_json="null"
if [[ $check_build -eq 1 ]]; then
  log=".inspector/integration/build.log"
  command_text="${build_command[*]}"
  started=$SECONDS
  if (cd "$build_dir" && "${build_command[@]}") >"$root/$log" 2>&1; then
    build_json="{\"command\":$(json_str "$command_text"),\"log\":$(json_str "$log"),\"seconds\":$((SECONDS - started))}"
  else
    # Every compiler error once, as `path:line:col: message`: without the colours swift build
    # prints even into a file, and once although xcodebuild repeats them.
    all_errors=()
    while IFS= read -r line; do
      all_errors+=("$line")
    done < <(sed $'s/\x1b\\[[0-9;]*m//g' "$root/$log" | grep -E '^/.+:[0-9]+:[0-9]+: error: ' |
      sed 's/: error: /: /' | awk '!seen[$0]++')
    # The integration's own files: the one it copied, and the manifest it edited.
    own=("$file_path")
    [[ "$dependency" != *.swift ]] || own+=("$dependency")
    errors=()
    files=()
    for line in ${all_errors[@]+"${all_errors[@]}"}; do
      for path in "${own[@]}"; do
        case "${line%%:*}" in
          */"$path")
            errors+=("$path:${line#*.swift:}")
            [[ " ${files[*]-} " == *" $path "* ]] || files+=("$path")
            ;;
        esac
      done
    done
    if [[ ${#errors[@]} -eq 0 ]]; then
      first=()
      if [[ ${#all_errors[@]} -gt 0 ]]; then first=("${all_errors[@]:0:10}"); else first=("$(tail -n 20 "$root/$log")"); fi
      fail CHECK_BUILD_FAILED "the build failed, but not in the integration's files: this checkout does not build as it is, or its packages did not resolve. The integration stays in place; fix the build, or remove.sh. Output: $log" \
        "{\"command\":$(json_str "$command_text"),\"errors\":$(json_strings ${first[@]+"${first[@]}"}),\"log\":$(json_str "$log")}"
    fi
    # The names the compiler could not resolve, as `Name` or `Type.member`.
    symbols=()
    while IFS= read -r symbol; do
      symbols+=("$symbol")
    done < <(printf '%s\n' "${errors[@]}" | perl -ne '
      if (/type \x27([^\x27]+)\x27 has no member \x27([^\x27]+)\x27/) { print "$1.$2\n" }
      elsif (/case \x27([^\x27]+)\x27 not found in type \x27([^\x27]+)\x27/) { print "$2.$1\n" }
      elsif (/(?:cannot find|cannot find type|no such module|has no member|has no member named) \x27([^\x27]+)\x27/) { print "$1\n" }
    ' | awk '!seen[$0]++')
    detail="{\"command\":$(json_str "$command_text"),\"errors\":$(json_strings "${errors[@]}"),\"files\":$(json_strings "${files[@]}"),\"log\":$(json_str "$log"),\"store\":$(json_or_null "${from:+$source_file}"),\"symbols\":$(json_strings ${symbols[@]+"${symbols[@]}"})}"
    names=""
    [[ ${#symbols[@]} -eq 0 ]] || names=" (unresolved: $(printf '%s, ' "${symbols[@]}" | sed 's/, $//'))"
    if printf '%s\n' "${errors[@]}" | grep -q "no such module 'InspectorKit'"; then
      fail INSPECTORKIT_UNLINKED "${files[*]} cannot import InspectorKit: the dependency does not reach the target that builds it. Pass --package/--package-target for a package the app target links, or add InspectorKit in Xcode. The integration stays in place; remove.sh takes it out." "$detail"
    elif [[ -n "$from" ]]; then
      fail INTEGRATION_STALE "the stored integration does not compile against this checkout${names}: ${files[*]} uses code that this checkout or the package versions it pins lack, or has changed. The store's copy is stale for this checkout: adapt $file_path in the repository to what the checkout has, build again, then copy it back to ${source_file}. The integration stays in place; remove.sh takes it out." "$detail"
    else
      fail INTEGRATION_STALE "the integration does not compile against this checkout${names}: fill the template's placeholders in $file_path with what this checkout has, then build again. The integration stays in place; remove.sh takes it out." "$detail"
    fi
  fi
fi

notes=()
[[ -z "${notes_dependency:-}" ]] || notes+=("$notes_dependency")
[[ -n "$plist" ]] ||
  notes+=("no Info.plist in $target_path: an iOS app needs NSBonjourServices and NSLocalNetworkUsageDescription, pass --plist")

printf '{"build":%s,"dependency":%s,"env":%s,"file":%s,"next":%s,"notes":%s,"plist":%s,"repo":%s,"target":%s}\n' \
  "$build_json" "$(json_or_null "$dependency")" "$(json_or_null "$env_path")" "$(json_str "$file_path")" \
  "$(json_str "Call the integration from the app's entry point on one line that ends in // DEBUG INSPECTOR, then build. remove.sh takes everything out again.")" \
  "$(json_strings ${notes[@]+"${notes[@]}"})" "$(json_or_null "$plist")" "$(json_str "$root")" \
  "$(json_or_null "$package_target")"
