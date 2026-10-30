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
# Paths are relative to the repository. Answer: one JSON document on stdout. Failure: one JSON
# line with `code` on stderr, exit 1, and nothing left changed. Usage error: exit 64.
set -euo pipefail
scripts_dir="$(dirname "${BASH_SOURCE[0]}")"
# shellcheck source=lib/common.sh
source "$scripts_dir/lib/common.sh"
# shellcheck source=lib/removal.sh
source "$scripts_dir/lib/removal.sh"

usage='Usage: integrate.sh <repo dir> --from <store dir> [--plist <path>] [--package <dir>] [--package-target <name>] [--ios-only]
       integrate.sh <repo dir> --into <target path> [--plist <path>] [--package <dir>] [--package-target <name>] [--ios-only]'

repo_dir=""
from=""
into=""
plist_option=""
package_option=""
package_target=""
ios_only=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --from | --into | --plist | --package | --package-target)
      [[ $# -ge 2 ]] || usage_error "$1 needs a value"
      case "$1" in
        --from) from="$2" ;;
        --into) into="$2" ;;
        --plist) plist_option="$2" ;;
        --package) package_option="$2" ;;
        --package-target) package_target="$2" ;;
      esac
      shift
      ;;
    --ios-only) ios_only=1 ;;
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

notes=()
[[ -z "${notes_dependency:-}" ]] || notes+=("$notes_dependency")
[[ -n "$plist" ]] ||
  notes+=("no Info.plist in $target_path: an iOS app needs NSBonjourServices and NSLocalNetworkUsageDescription, pass --plist")

json_or_null() { if [[ -n "$1" ]]; then json_str "$1"; else printf 'null'; fi; }
printf '{"dependency":%s,"env":%s,"file":%s,"next":%s,"notes":%s,"plist":%s,"repo":%s,"target":%s}\n' \
  "$(json_or_null "$dependency")" "$(json_or_null "$env_path")" "$(json_str "$file_path")" \
  "$(json_str "Call the integration from the app's entry point on one line that ends in // DEBUG INSPECTOR, then build. remove.sh takes everything out again.")" \
  "$(json_strings ${notes[@]+"${notes[@]}"})" "$(json_or_null "$plist")" "$(json_str "$root")" \
  "$(json_or_null "$package_target")"
