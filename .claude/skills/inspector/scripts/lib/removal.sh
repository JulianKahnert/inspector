#!/usr/bin/env bash
# shellcheck disable=SC2154 # marker and the helpers come from common.sh, sourced first
# remove_integration, shared by remove.sh and by integrate.sh's rollback; sourced after common.sh.
#
# integrate.sh leaves a record in .inspector/integration/: `record` holds one tab-separated line
# per change (`exclude`, `file <path>`, `patch <path> <patch file>`, `resolved <path> <copy>`),
# next to the patches and the copies it names. Reversing a patch undoes exactly what the edit added,
# also the lines SwiftPM adds without a marker (`dependencies: [`, a comma). Without a record, or
# when a file changed so its patch no longer applies, the markers are the fallback.

# status_snapshot <root>: one sorted line per path `git status` lists: path, status, content hash.
status_snapshot() {
  local root="$1" entry path hash
  while IFS= read -r -d '' entry; do
    path="${entry:3}"
    hash=-
    [[ ! -f "$root/$path" ]] || hash="$(git -C "$root" hash-object --no-filters -- "$path")"
    printf '%s\t%s\t%s\n' "$path" "${entry:0:2}" "$hash"
  done < <(git -C "$root" status --porcelain=v1 -z --untracked-files=all --no-renames --ignore-submodules=all)
}

# unexpected_file <root>: where remove.sh notes the paths it changed outside the integration, for
# --check; in the worktree's git directory, so removing `.inspector/` keeps it.
unexpected_file() {
  git -C "$1" rev-parse --path-format=absolute --git-path inspector-unexpected
}

# remove_integration <root>: undoes the integration in one repository and sets `removal_json`
# to what it did, and `removal_unexpected` to the paths it changed outside the integration.
remove_integration() {
  local root="$1"
  local state="$root/.inspector/integration"
  local record="$state/record"
  local deleted=() restored=() lines=() notes=() touched=()
  local kind path extra before
  before="$(mktemp)"
  status_snapshot "$root" | LC_ALL=C sort >"$before"

  # 1. Patches and copied files, as recorded.
  if [[ -f "$record" ]]; then
    while IFS=$'\t' read -r kind path extra; do
      [[ -z "$path" ]] || touched+=("$path")
      case "$kind" in
        patch)
          if git -C "$root" apply -R --check "$state/$extra" 2>/dev/null; then
            git -C "$root" apply -R "$state/$extra"
            restored+=("$path")
          else
            notes+=("$path changed after integrate.sh; only its marked lines were removed")
          fi
          ;;
        file)
          if [[ -e "$root/$path" ]]; then
            rm -f "$root/$path"
            deleted+=("$path")
          fi
          ;;
      esac
    done <"$record"
  else
    notes+=("no record from integrate.sh; removed the marked files and lines only")
  fi

  # 2. Package.resolved files that gained only InspectorKit's pins go back to how they were.
  local file previous current added dropped
  while IFS= read -r file; do
    [[ -n "$file" && -f "$root/$file" ]] || continue
    previous="$(mktemp)"
    if [[ -f "$record" ]]; then
      extra="$(awk -F'\t' -v p="$file" '$1 == "resolved" && $2 == p { print $3 }' "$record")"
      if [[ -n "$extra" ]]; then cp "$state/$extra" "$previous"; else rm -f "$previous"; fi
    elif ! git -C "$root" show "HEAD:$file" >"$previous" 2>/dev/null; then
      rm -f "$previous"
    fi
    current="$(pin_identities "$root/$file")"
    added="$(comm -23 <(printf '%s\n' "$current" | sed '/^$/d') <(pin_identities "$previous"))"
    dropped="$(comm -13 <(printf '%s\n' "$current" | sed '/^$/d') <(pin_identities "$previous"))"
    if [[ -n "$added" ]]; then
      if [[ -z "$dropped" && -z "$(comm -23 <(printf '%s\n' "$added") <(inspector_pins))" ]]; then
        if [[ -f "$previous" ]]; then
          cp "$previous" "$root/$file"
          restored+=("$file")
        else
          rm -f "$root/$file"
          deleted+=("$file")
        fi
      elif [[ -n "$(comm -12 <(printf '%s\n' "$added") <(inspector_pins))" ]]; then
        notes+=("$file has other new pins too and was left as it is; remove InspectorKit's pins by hand")
      fi
    fi
    rm -f "$previous"
  done < <({
    resolved_files "$root"
    [[ -f "$record" ]] && awk -F'\t' '$1 == "resolved" { print $2 }' "$record"
  } | sort -u)

  # 3. Files that are integration as a whole: not in HEAD, the marker on their first line. A file
  #    in HEAD only loses its marked lines, also when the first one is marked (a sorted import).
  while IFS= read -r file; do
    git -C "$root" cat-file -e "HEAD:$file" 2>/dev/null && continue
    if head -n 1 "$root/$file" | grep -q "$marker"; then
      rm -f "$root/$file"
      deleted+=("$file")
    fi
  done < <(git -C "$root" grep --untracked -l -I -e "$marker" || true)

  # 4. Marked lines left anywhere else. In a plist the marker is a comment line before the key and
  #    value, or before a single value it added to an existing array; both go with it.
  local number
  while IFS= read -r file; do
    touched+=("$file")
    while IFS= read -r number; do
      lines+=("$file:$number")
    done < <(grep -n "$marker" "$root/$file" | cut -d: -f1)
    perl -0pi -e '
      s{^[ \t]*<!-- DEBUG INSPECTOR -->[ \t]*\n(?:[ \t]*<key>[^\n]*</key>[ \t]*\n)?(?:[ \t]*<(array|dict)>.*?</\1>[ \t]*\n|[ \t]*<[^\n]*\n)}{}gms;
      s{^[^\n]*DEBUG INSPECTOR[^\n]*(?:\n|\z)}{}gm;
    ' "$root/$file"
  done < <(git -C "$root" grep --untracked -l -I -e "$marker" || true)

  # 5. The exclude entry, integrate.sh's or init's (both write the same marked pair), unless another
  #    worktree of the repository still has a .inspector/ folder: an integration or a session.
  local exclude other keep=0
  exclude="$(exclude_file "$root")"
  while IFS= read -r other; do
    [[ "$(cd "$other" 2>/dev/null && pwd -P)" == "$(cd "$root" && pwd -P)" ]] && continue
    [[ -d "$other/.inspector" ]] && keep=1
  done < <(git -C "$root" worktree list --porcelain | sed -n 's/^worktree //p')
  if [[ $keep -eq 0 && -f "$exclude" ]]; then
    perl -0pi -e 's{^# DEBUG INSPECTOR\n/\.inspector/\n}{}gm' "$exclude"
  fi
  [[ $keep -eq 0 ]] || notes+=("kept the .inspector/ exclude entry: another worktree of this repository has a .inspector/ folder")

  # 6. The session binding goes with the integration.
  rm -rf "$root/.inspector"

  # 7. Every path whose git status changed has to be one the integration touched.
  local after allowed
  after="$(mktemp)"
  allowed="$(mktemp)"
  status_snapshot "$root" | LC_ALL=C sort >"$after"
  printf '%s\n' ${deleted[@]+"${deleted[@]}"} ${restored[@]+"${restored[@]}"} ${touched[@]+"${touched[@]}"} |
    sed '/^$/d' | LC_ALL=C sort -u >"$allowed"
  removal_unexpected=()
  while IFS= read -r path; do
    removal_unexpected+=("$path")
  done < <(LC_ALL=C comm -3 "$before" "$after" | sed 's/^\t//' | cut -f1 | LC_ALL=C sort -u |
    grep -v '^\.inspector/' | LC_ALL=C comm -23 - "$allowed")
  rm -f "$before" "$after" "$allowed"
  if [[ ${#removal_unexpected[@]} -gt 0 ]]; then
    printf '%s\n' "${removal_unexpected[@]}" >>"$(unexpected_file "$root")"
  fi

  removal_json="{\"deleted\":$(json_strings ${deleted[@]+"${deleted[@]}"}),"
  removal_json+="\"lines\":$(json_strings ${lines[@]+"${lines[@]}"}),"
  removal_json+="\"notes\":$(json_strings ${notes[@]+"${notes[@]}"}),"
  removal_json+="\"repo\":$(json_str "$root"),"
  removal_json+="\"restored\":$(json_strings ${restored[@]+"${restored[@]}"})}"
}
