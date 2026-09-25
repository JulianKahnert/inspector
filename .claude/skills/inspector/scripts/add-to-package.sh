#!/usr/bin/env bash
# Adds InspectorKit to one target of a Swift package for a debug session, marked for removal.
# Usage: add-to-package.sh <package dir> <target> [--ios-only] [--copy-template]
#   --ios-only       link InspectorKit on iOS only (for packages that also build watchOS, tvOS, …)
#   --copy-template  copy assets/DebugInspector.swift into Sources/<target>/
# Exit: 0 added, 1 failed or already present, 2 usage error.
set -euo pipefail

usage() {
  echo "usage: add-to-package.sh <package dir> <target> [--ios-only] [--copy-template]" >&2
  exit 2
}

[[ $# -ge 2 ]] || usage
package_dir="$(cd "$1" && pwd)"
target="$2"
shift 2
ios_only=0
copy_template=0
for flag in "$@"; do
  case "$flag" in
    --ios-only) ios_only=1 ;;
    --copy-template) copy_template=1 ;;
    *) usage ;;
  esac
done

skill_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
inspector_root="$(cd "$skill_dir/../../.." && pwd)"
# SwiftPM names a local package after its directory; the product reference has to use that name.
identity="$(basename "$inspector_root")"
manifest="$package_dir/Package.swift"

[[ -f "$manifest" ]] || { echo "no Package.swift in $package_dir" >&2; exit 1; }
if grep -q 'InspectorKit' "$manifest"; then
  echo "InspectorKit is already in $manifest" >&2
  exit 1
fi

# A failure after the first edit would leave a half-edited manifest, so restore it on any error.
backup="$(mktemp)"
cp "$manifest" "$backup"
restore_on_failure() {
  local status=$?
  if [[ $status -ne 0 ]]; then
    cp "$backup" "$manifest"
    echo "manifest restored" >&2
  fi
  rm -f "$backup"
}
trap restore_on_failure EXIT

# SwiftPM's own manifest editing keeps the formatting and validates the target name.
swift package --package-path "$package_dir" add-dependency "$inspector_root" --type path >&2
swift package --package-path "$package_dir" add-target-dependency InspectorKit "$target" \
  --package "$identity" >&2

# Mark exactly the two lines SwiftPM added; \Q…\E keeps the path from acting as a regex.
condition=""
[[ $ios_only -eq 1 ]] && condition=', condition: .when(platforms: [.iOS])'
ROOT="$inspector_root" ID="$identity" COND="$condition" perl -pi -e '
  s{^(\s*\.package\(path: "\Q$ENV{ROOT}\E"\)),?$}{$1, // DEBUG INSPECTOR};
  s{^(\s*\.product\(name: "InspectorKit", package: "\Q$ENV{ID}\E")\),?$}{$1$ENV{COND}), // DEBUG INSPECTOR};
' "$manifest"

marked="$(grep -c 'DEBUG INSPECTOR' "$manifest" || true)"
if [[ "$marked" -ne 2 ]]; then
  echo "expected 2 marked lines in $manifest, found $marked; check the manifest by hand" >&2
  exit 1
fi
swift package --package-path "$package_dir" dump-package >/dev/null

if [[ $copy_template -eq 1 ]]; then
  destination="$package_dir/Sources/$target/DebugInspector.swift"
  if [[ ! -d "$(dirname "$destination")" ]]; then
    echo "Sources/$target does not exist (custom target path?); copy assets/DebugInspector.swift by hand" >&2
  elif [[ -e "$destination" ]]; then
    echo "$destination already exists; template not copied" >&2
  else
    cp "$skill_dir/assets/DebugInspector.swift" "$destination"
    echo "template: $destination"
  fi
fi

grep -n 'DEBUG INSPECTOR' "$manifest"
