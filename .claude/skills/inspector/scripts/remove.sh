#!/usr/bin/env bash
# Takes an ephemeral debug integration out of app repositories, or checks that none is left.
# Usage: remove.sh [<repo dir>…]
#        remove.sh --check [--base <ref>] [<repo dir>…]
# Without a repo dir: the repository around the working directory, or else every repository
# directly below it (a workspace root holding several checkouts).
# Answer: one JSON document on stdout. Failure: one JSON line with `code` on stderr, exit 1.
# Usage error: exit 64.
set -euo pipefail
# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

usage='Usage: remove.sh [<repo dir>…]
       remove.sh --check [--base <ref>] [<repo dir>…]'

check=0
base=""
dirs=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --check) check=1 ;;
    --base)
      [[ $# -ge 2 ]] || usage_error "--base needs a branch or commit"
      base="$2"
      shift
      ;;
    -h | --help)
      printf '%s\n' "$usage"
      exit 0
      ;;
    -*) usage_error "unknown option $1" ;;
    *) dirs+=("$1") ;;
  esac
  shift
done
[[ $check -eq 1 || -z "$base" ]] || usage_error "--base only goes with --check"

if [[ ${#dirs[@]} -eq 0 ]]; then
  if here="$(repo_root .)" && [[ -n "$here" ]]; then
    dirs=("$here")
  else
    for candidate in ./*/; do
      candidate="${candidate%/}"
      [[ -d "$candidate" ]] || continue
      top="$(repo_root "$candidate" || true)"
      [[ -n "$top" && "$(cd "$top" && pwd -P)" == "$(cd "$candidate" && pwd -P)" ]] && dirs+=("$top")
    done
    [[ ${#dirs[@]} -gt 0 ]] || fail NOT_A_REPO "no git repository here or directly below $(pwd)" "$(json_str "$(pwd)")"
  fi
fi

roots=()
for dir in "${dirs[@]}"; do
  root="$(require_app_repo "$dir")" || exit 1
  roots+=("$root")
done

# shellcheck source=lib/removal.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/removal.sh"

# MARK: - --check

# base_ref <root>: --base, else the default branch of the current branch's remote, else origin's.
base_ref() {
  local root="$1" upstream remote
  if [[ -n "$base" ]]; then
    git -C "$root" rev-parse -q --verify "$base^{commit}" >/dev/null || return 1
    printf '%s\n' "$base"
    return 0
  fi
  upstream="$(git -C "$root" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null || true)"
  for remote in "${upstream%%/*}" origin; do
    [[ -n "$remote" ]] || continue
    if git -C "$root" symbolic-ref -q --short "refs/remotes/$remote/HEAD" 2>/dev/null; then
      return 0
    fi
  done
  return 1
}

findings=""
finding_count=0
damage_count=0
# add_finding <kind> <root> <where>
add_finding() {
  [[ -z "$findings" ]] || findings+=","
  findings+="{\"kind\":$(json_str "$1"),\"repo\":$(json_str "$2"),\"where\":$(json_str "$3")}"
  finding_count=$((finding_count + 1))
}

# check_repo <root> <merge base>: adds a finding for every trace of the integration, and for every
# change remove.sh must not have made.
check_repo() {
  local root="$1" merge_base="$2" line path file new hits unexpected kept
  # 1. Any marker, in tracked files and in untracked ones git would pick up.
  while IFS= read -r line; do
    add_finding marker "$root" "$line"
  done < <(git -C "$root" grep --untracked -n -I -e "$marker" | cut -d: -f1,2 || true)

  # 2. InspectorKit on an added line against the base, or in an untracked file.
  while IFS= read -r path; do
    add_finding diff "$root" "$path"
  done < <(git -C "$root" diff --no-color --no-ext-diff --unified=0 --src-prefix=a/ --dst-prefix=b/ \
    "$merge_base" -- . |
    awk '/^\+\+\+ / { file = substr($0, 7); next } /^\+/ && /InspectorKit/ { print file }' | sort -u)
  while IFS= read -r -d '' path; do
    if grep -q -I InspectorKit "$root/$path" 2>/dev/null; then
      add_finding diff "$root" "$path (untracked)"
    fi
  done < <(git -C "$root" ls-files -z -o --exclude-standard)

  # 3. Anything under .inspector/ in the index.
  while IFS= read -r path; do
    add_finding tracked "$root" "$path"
  done < <(git -C "$root" ls-files -- .inspector)

  # 4. A Package.resolved that gained a pin InspectorKit's package brings.
  while IFS= read -r file; do
    new="$(comm -23 <(pin_identities "$root/$file") \
      <(git -C "$root" show "$merge_base:$file" 2>/dev/null | pins_from_stdin))"
    hits="$(comm -12 <(printf '%s\n' "$new" | sed '/^$/d') <(inspector_pins) | paste -sd, -)"
    [[ -z "$hits" ]] || add_finding resolved "$root" "$file: $hits"
  done < <(resolved_files "$root")

  # 5. A tracked file deleted in the working tree but not staged: no integration step deletes one.
  while IFS= read -r path; do
    add_finding deleted "$root" "$path"
    damage_count=$((damage_count + 1))
  done < <(git -C "$root" ls-files --deleted)

  # 6. Paths remove.sh changed outside the integration, until they match the index again.
  unexpected="$(unexpected_file "$root")"
  [[ -f "$unexpected" ]] || return 0
  kept=""
  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    [[ -n "$(git -C "$root" status --porcelain --untracked-files=all -- ":(literal)$path")" ]] || continue
    kept+="$path"$'\n'
    git -C "$root" ls-files --deleted -- ":(literal)$path" | grep -q . && continue
    add_finding unexpected "$root" "$path"
    damage_count=$((damage_count + 1))
  done < <(sort -u "$unexpected")
  if [[ -n "$kept" ]]; then printf '%s' "$kept" >"$unexpected"; else rm -f "$unexpected"; fi
}

run_check() {
  local root ref merge_base answers="" separator=""
  for root in "${roots[@]}"; do
    ref="$(base_ref "$root")" ||
      fail BASE_NOT_FOUND "no base branch for $root: pass --base <branch>, or set the remote's default with git remote set-head origin --auto" \
        "$(json_str "$root")"
    merge_base="$(git -C "$root" merge-base HEAD "$ref")" ||
      fail BASE_NOT_FOUND "HEAD and $ref share no commit in $root" "$(json_str "$root")"
    check_repo "$root" "$merge_base"
    answers+="$separator{\"base\":$(json_str "$ref"),\"repo\":$(json_str "$root")}"
    separator=","
  done
  if [[ $finding_count -gt $damage_count ]]; then
    fail INTEGRATION_LEFT "the debug integration is still in $((finding_count - damage_count)) place(s); run remove.sh" "[$findings]"
  fi
  if [[ $damage_count -gt 0 ]]; then
    fail UNEXPECTED_CHANGE "$damage_count file(s) deleted or changed outside the integration; restore each with git checkout -- <path>, or git rm a deletion you meant" "[$findings]"
  fi
  printf '{"clean":true,"repos":[%s]}\n' "$answers"
}

if [[ $check -eq 1 ]]; then
  run_check
  exit 0
fi

# MARK: - Removal

answers=""
separator=""
unexpected=()
for root in "${roots[@]}"; do
  remove_integration "$root"
  answers+="$separator$removal_json"
  separator=","
  for path in ${removal_unexpected[@]+"${removal_unexpected[@]}"}; do
    unexpected+=("$root/$path")
  done
done
if [[ ${#unexpected[@]} -gt 0 ]]; then
  fail UNEXPECTED_CHANGE "remove.sh changed ${#unexpected[@]} file(s) outside the integration; restore each with git checkout -- <path>" \
    "{\"repos\":[$answers],\"unexpected\":$(json_strings "${unexpected[@]}")}"
fi
printf '{"repos":[%s]}\n' "$answers"
