#!/usr/bin/env bash
set -euo pipefail
repository="${1:?repository path required}"
source_root="${2:-$repository}"
git_dir="$(git -C "$repository" rev-parse --absolute-git-dir)"
for hook_name in pre-commit pre-push; do
  source_path="$source_root/script/hooks/$hook_name"
  installed_path="$git_dir/hooks/$hook_name"
  test ! -L "$installed_path"
  test -x "$installed_path"
  expected="$(shasum -a 256 "$source_path" | /usr/bin/awk '{print $1}')"
  actual="$(shasum -a 256 "$installed_path" | /usr/bin/awk '{print $1}')"
  test "$expected" = "$actual"
done
