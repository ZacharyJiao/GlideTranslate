#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C
umask 022

workspace_root="$(cd "$(dirname "$0")/.." && pwd)"
destination="${1:?destination required}"
if [ "$#" -ge 2 ]; then workspace_root="$(cd "$2" && pwd)"; fi
test ! -e "$destination"
/bin/mkdir -p "$destination"

mode_inventory="$(mktemp)"
cleanup_mode_inventory() {
  prior_status=$?
  trap - EXIT
  /bin/rm -f "$mode_inventory"
  exit "$prior_status"
}
trap cleanup_mode_inventory EXIT

while IFS= read -r relative_path; do
  test -n "$relative_path" || continue
  case "$relative_path" in
    .|/*|*/|*//*|./*|*/./*|*/.|..|../*|*/../*|*/..|*[[:cntrl:]]*)
      printf '%s\n' CANDIDATE_PATH_INVALID >&2
      exit 1
      ;;
  esac
  source_path="$workspace_root/$relative_path"
  test -e "$source_path"
  symlink_probe="$(mktemp)"
  if ! /usr/bin/find "$source_path" -type l -print -quit > "$symlink_probe"; then
    /bin/rm -f "$symlink_probe"
    printf '%s\n' CANDIDATE_ENUMERATION_FAILED >&2
    exit 2
  fi
  if [ -s "$symlink_probe" ]; then
    /bin/rm -f "$symlink_probe"
    printf 'CANDIDATE_SYMLINK:%s\n' "$relative_path" >&2
    exit 1
  fi
  /bin/rm -f "$symlink_probe"
  if [ -d "$source_path" ]; then
    /usr/bin/ditto --norsrc "$source_path" "$destination/$relative_path"
  else
    /bin/mkdir -p "$destination/$(dirname "$relative_path")"
    /bin/cp "$source_path" "$destination/$relative_path"
  fi

  if ! /usr/bin/find "$source_path" -type f -print0 > "$mode_inventory"; then
    printf '%s\n' CANDIDATE_ENUMERATION_FAILED >&2
    exit 2
  fi
  while IFS= read -r -d '' copied_source; do
    copied_relative="${copied_source#"$workspace_root"/}"
    copied_destination="$destination/$copied_relative"
    case "$copied_relative" in
      script/*)
        if [ -x "$copied_source" ]; then
          /bin/chmod 755 "$copied_destination"
        else
          /bin/chmod 644 "$copied_destination"
        fi
        ;;
      *) /bin/chmod 644 "$copied_destination" ;;
    esac
  done < "$mode_inventory"
  if [ -d "$destination/$relative_path" ]; then
    /usr/bin/find "$destination/$relative_path" -type d -exec /bin/chmod 755 {} +
  fi
done < "$workspace_root/script/public_paths.txt"

/bin/rm -f "$mode_inventory"
mode_inventory=""
trap - EXIT
