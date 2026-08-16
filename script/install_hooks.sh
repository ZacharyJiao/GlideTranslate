#!/usr/bin/env bash
set -euo pipefail
repository="${1:?repository path required}"
source_root="${2:-$repository}"
git_dir="$(git -C "$repository" rev-parse --absolute-git-dir)"
hooks_dir="$git_dir/hooks"
/bin/mkdir -p "$hooks_dir"
for hook_name in pre-commit pre-push; do
  source_path="$source_root/script/hooks/$hook_name"
  destination_path="$hooks_dir/$hook_name"
  test -f "$source_path"
  /bin/cp "$source_path" "$destination_path"
  chmod 0755 "$destination_path"
  shasum -a 256 "$source_path" > "$hooks_dir/$hook_name.sha256"
done
