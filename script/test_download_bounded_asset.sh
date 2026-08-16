#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

workspace_root="$(cd "$(dirname "$0")/.." && pwd)"
helper="$workspace_root/script/download_bounded_asset.sh"
fixture_root="$(mktemp -d)"
cleanup() {
  prior_status=$?
  trap - EXIT INT TERM HUP
  /bin/rm -rf "$fixture_root" >/dev/null 2>&1 || true
  exit "$prior_status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

test -x "$helper"

printf '' | "$helper" 4 "$fixture_root/zero.bin"
test "$(/usr/bin/stat -f '%z' "$fixture_root/zero.bin")" -eq 0

printf 'ABCD' | "$helper" 4 "$fixture_root/exact.bin"
test "$(/usr/bin/stat -f '%z' "$fixture_root/exact.bin")" -eq 4

limit_status=0
printf 'ABCDE' | "$helper" 4 "$fixture_root/over.bin" \
  > "$fixture_root/over.stdout" 2> "$fixture_root/over.stderr" \
  || limit_status=$?
test "$limit_status" -ne 0
test "$(/bin/cat "$fixture_root/over.stderr")" = DOWNLOAD_LIMIT_EXCEEDED
test ! -e "$fixture_root/over.bin"

printf 'existing' > "$fixture_root/existing.bin"
existing_status=0
printf 'new' | "$helper" 4 "$fixture_root/existing.bin" \
  > "$fixture_root/existing.stdout" 2> "$fixture_root/existing.stderr" \
  || existing_status=$?
test "$existing_status" -ne 0
test "$(/bin/cat "$fixture_root/existing.stderr")" = DOWNLOAD_DESTINATION_EXISTS
test "$(/bin/cat "$fixture_root/existing.bin")" = existing

/bin/ln -s missing-target "$fixture_root/dangling.bin"
dangling_status=0
printf 'new' | "$helper" 4 "$fixture_root/dangling.bin" \
  > "$fixture_root/dangling.stdout" 2> "$fixture_root/dangling.stderr" \
  || dangling_status=$?
test "$dangling_status" -ne 0
test "$(/bin/cat "$fixture_root/dangling.stderr")" = DOWNLOAD_DESTINATION_EXISTS
test -L "$fixture_root/dangling.bin"

printf '\000A\000B' | "$helper" 4 "$fixture_root/nul.bin"
test "$(/usr/bin/stat -f '%z' "$fixture_root/nul.bin")" -eq 4
test "$(/usr/bin/od -An -tu1 "$fixture_root/nul.bin" | /usr/bin/tr -s ' ' | /usr/bin/xargs)" = '0 65 0 66'

set +e
(printf 'AB'; exit 17) | "$helper" 4 "$fixture_root/upstream.bin"
pipeline_status=("${PIPESTATUS[@]}")
set -e
test "${pipeline_status[0]}" -eq 17
test "${pipeline_status[1]}" -eq 0
test -f "$fixture_root/upstream.bin"

race_fifo="$fixture_root/race.fifo"
/usr/bin/mkfifo "$race_fifo"
exec 8<> "$race_fifo"
"$helper" 4 "$fixture_root/race.bin" < "$race_fifo" 8>&- \
  > "$fixture_root/race.stdout" 2> "$fixture_root/race.stderr" &
race_pid=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do
  partial_match="$(find "$fixture_root" -maxdepth 1 -name 'race.bin.partial.*' -print -quit)"
  test -n "$partial_match" && break
  /bin/sleep 0.02
done
printf '%s\n' retained > "$fixture_root/race.bin"
printf 'AB' >&8
exec 8>&-
race_status=0
wait "$race_pid" || race_status=$?
test "$race_status" -ne 0
test "$(/bin/cat "$fixture_root/race.bin")" = retained
test "$(/bin/cat "$fixture_root/race.stderr")" = DOWNLOAD_WRITE_FAILED

/usr/bin/python3 - "$helper" "$fixture_root" <<'PY'
import glob, os, signal, subprocess, sys, time
helper, root = sys.argv[1:]
for name, number, expected in (
    ("INT", signal.SIGINT, 130),
    ("TERM", signal.SIGTERM, 143),
    ("HUP", signal.SIGHUP, 129),
):
    destination = os.path.join(root, "signal-" + name + ".bin")
    process = subprocess.Popen(
        [helper, "4", destination],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    for _ in range(50):
        if glob.glob(destination + ".partial.*"):
            break
        time.sleep(0.01)
    else:
        raise SystemExit("signal partial not created")
    os.kill(process.pid, number)
    stdout, stderr = process.communicate(timeout=2)
    if process.returncode != expected or stdout or stderr:
        raise SystemExit("signal contract mismatch")
    if os.path.lexists(destination) or glob.glob(destination + ".partial.*"):
        raise SystemExit("signal cleanup mismatch")
PY

printf '%s\n' DOWNLOAD_BOUNDED_ASSET_TESTS_PASSED
