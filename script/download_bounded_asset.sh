#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

max_bytes="${1:?maximum bytes required}"
destination="${2:?destination required}"
case "$max_bytes" in ''|*[!0-9]*) printf '%s\n' DOWNLOAD_LIMIT_INVALID >&2; exit 1 ;; esac
test "$max_bytes" -le 9223372036854775806 || {
  printf '%s\n' DOWNLOAD_LIMIT_INVALID >&2
  exit 1
}
test ! -e "$destination" && test ! -L "$destination" || {
  printf '%s\n' DOWNLOAD_DESTINATION_EXISTS >&2
  exit 1
}
destination_parent="$(dirname "$destination")"
test -d "$destination_parent" || {
  printf '%s\n' DOWNLOAD_DESTINATION_INVALID >&2
  exit 1
}
partial="$(/usr/bin/mktemp "$destination.partial.XXXXXX")" || {
  printf '%s\n' DOWNLOAD_WRITE_FAILED >&2
  exit 1
}
committed=0
reader_pid=""
cleanup_partial() {
  prior_status=$?
  trap - EXIT INT TERM HUP
  if [ "$committed" -eq 0 ]; then
    /bin/rm -f "$partial" >/dev/null 2>&1 || true
  fi
  exit "$prior_status"
}
stop_reader_and_exit() {
  signal_status="$1"
  trap - EXIT INT TERM HUP
  if [ -n "$reader_pid" ] && kill -0 "$reader_pid" 2>/dev/null; then
    kill -TERM "$reader_pid" 2>/dev/null || true
    wait "$reader_pid" 2>/dev/null || true
  fi
  /bin/rm -f "$partial" >/dev/null 2>&1 || true
  exit "$signal_status"
}
trap cleanup_partial EXIT
trap 'stop_reader_and_exit 130' INT
trap 'stop_reader_and_exit 143' TERM
trap 'stop_reader_and_exit 129' HUP

read_limit=$((max_bytes + 1))
exec 3<&0
/usr/bin/head -c "$read_limit" <&3 > "$partial" &
reader_pid=$!
reader_status=0
wait "$reader_pid" || reader_status=$?
reader_pid=""
exec 3<&-
if [ "$reader_status" -ne 0 ]; then
  printf '%s\n' DOWNLOAD_WRITE_FAILED >&2
  exit 1
fi
size="$(/usr/bin/stat -f '%z' "$partial")" || {
  printf '%s\n' DOWNLOAD_WRITE_FAILED >&2
  exit 1
}
case "$size" in ''|*[!0-9]*) printf '%s\n' DOWNLOAD_WRITE_FAILED >&2; exit 1 ;; esac
if [ "$size" -gt "$max_bytes" ]; then
  printf '%s\n' DOWNLOAD_LIMIT_EXCEEDED >&2
  exit 1
fi
if ! /bin/ln "$partial" "$destination" 2>/dev/null; then
  printf '%s\n' DOWNLOAD_WRITE_FAILED >&2
  exit 1
fi
committed=1
if ! /bin/rm -f "$partial"; then
  printf '%s\n' DOWNLOAD_WRITE_FAILED >&2
  exit 1
fi
