#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

workspace_root="$(cd "$(dirname "$0")/.." && pwd)"
checker="$workspace_root/script/check_external_surfaces.sh"
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

test -x "$checker"

accepted="$fixture_root/accepted"
/bin/mkdir -p "$accepted"
printf '%s\n' '{"login":"public-user","email":"12345+public@users.noreply.github.com","url":"https://api.github.com/users/public-user","ssh_url":"git@github.com:example/repository.git"}' > "$accepted/metadata.json"
printf '%s\n' public > "$accepted/12345+public@users.noreply.github.com"
printf '%s\n' public > "$accepted/maintainer@example.com"
printf '%s\n' 'Authorization:'" Basic ***" > "$accepted/run-123.log"
GT_PUBLIC_LOGIN_ALLOWLIST=maintainer@example.com "$checker" "$accepted"

assert_rejected() {
  name="$1"
  category="$2"
  value="$3"
  root="$fixture_root/$name"
  /bin/mkdir -p "$root"
  printf '%s\n' "$value" > "$root/surface.json"
  probe_status=0
  "$checker" "$root" > "$fixture_root/$name.stdout" \
    2> "$fixture_root/$name.stderr" || probe_status=$?
  test "$probe_status" -ne 0
  rg -q "^${category}:" "$fixture_root/$name.stderr"
  test ! -s "$fixture_root/$name.stdout"
  ! rg -Fq "$value" "$fixture_root/$name.stderr"
}

user_marker='/'"Users/private-user/project"
assert_rejected absolute-path PROHIBITED_ABSOLUTE_PATH "$user_marker"
assert_rejected agent-path PROHIBITED_AGENT_SURFACE '.codex/private-state'
printf -v private_ipv4 '%s.%s.%s.%s' 172 20 0 8
assert_rejected private-endpoint PROHIBITED_PRIVATE_ENDPOINT \
  "http://$private_ipv4/internal"
credential_marker='Authorization:'" Bearer synthetic-value"
assert_rejected credential PROHIBITED_CREDENTIAL_CONTENT \
  "$credential_marker"
private_key_marker='BEGIN PRI'"VATE KEY"
assert_rejected private-key PROHIBITED_CREDENTIAL_CONTENT \
  "$private_key_marker"
assert_rejected content-marker PROHIBITED_CONTENT_MARKER \
  'GT_PRIVATE_USER_CONTENT'
assert_rejected identity PROHIBITED_PUBLIC_IDENTITY \
  'private-person@example.com'
assert_rejected loopback PROHIBITED_PRIVATE_ENDPOINT \
  'http://localhost:11434/private'
private_tmp_marker='/'"private/tmp/private-build"
assert_rejected private-tmp PROHIBITED_ABSOLUTE_PATH "$private_tmp_marker"

assert_path_rejected() {
  name="$1"
  category="$2"
  relative="$3"
  root="$fixture_root/$name"
  /bin/mkdir -p "$root/$(/usr/bin/dirname "$relative")"
  printf '%s\n' public > "$root/$relative"
  probe_status=0
  "$checker" "$root" > "$fixture_root/$name.stdout" \
    2> "$fixture_root/$name.stderr" || probe_status=$?
  test "$probe_status" -ne 0
  rg -q "^${category}:surface-[0-9a-f]{12}:file-[0-9a-f]{12}$" \
    "$fixture_root/$name.stderr"
  test ! -s "$fixture_root/$name.stdout"
  ! rg -Fq "$relative" "$fixture_root/$name.stderr"
}

assert_path_rejected root-agent PROHIBITED_AGENT_SURFACE AGENTS.md
assert_path_rejected uppercase-key PROHIBITED_CREDENTIAL_SURFACE SECRET.KEY
assert_path_rejected runtime-path PROHIBITED_RUNTIME_SURFACE runtime/session.json
assert_path_rejected model-path PROHIBITED_MODEL_SURFACE models/model.gguf
assert_path_rejected sensitive-filename PROHIBITED_PUBLIC_IDENTITY \
  private-person@example.com

symlink_root="$fixture_root/symlink"
/bin/mkdir -p "$symlink_root"
/bin/ln -s /tmp "$symlink_root/link"
probe_status=0
"$checker" "$symlink_root" > "$fixture_root/symlink.stdout" \
  2> "$fixture_root/symlink.stderr" || probe_status=$?
test "$probe_status" -ne 0
rg -q '^PROHIBITED_SURFACE_SYMLINK:' "$fixture_root/symlink.stderr"

fifo_root="$fixture_root/fifo"
/bin/mkdir -p "$fifo_root"
/usr/bin/mkfifo "$fifo_root/private.pipe"
probe_status=0
"$checker" "$fifo_root" > "$fixture_root/fifo.stdout" \
  2> "$fixture_root/fifo.stderr" || probe_status=$?
test "$probe_status" -ne 0
rg -q '^PROHIBITED_SURFACE_SPECIAL_FILE:' "$fixture_root/fifo.stderr"
test ! -s "$fixture_root/fifo.stdout"

data_root="$fixture_root/arbitrary-data"
/bin/mkdir -p "$data_root"
printf '\000\001\002\003\004\005\006\007\010\016\017\020' > "$data_root/payload.bin"
probe_status=0
"$checker" "$data_root" > "$fixture_root/arbitrary-data.stdout" \
  2> "$fixture_root/arbitrary-data.stderr" || probe_status=$?
test "$probe_status" -ne 0
rg -q '^UNVERIFIABLE_SURFACE_TYPE:' "$fixture_root/arbitrary-data.stderr"
test ! -s "$fixture_root/arbitrary-data.stdout"

oversized_root="$fixture_root/oversized"
/bin/mkdir -p "$oversized_root"
/usr/bin/truncate -s 67108865 "$oversized_root/large.bin"
probe_status=0
"$checker" "$oversized_root" > "$fixture_root/oversized.stdout" \
  2> "$fixture_root/oversized.stderr" || probe_status=$?
test "$probe_status" -ne 0
rg -q '^OVERSIZED_SURFACE:' "$fixture_root/oversized.stderr"

assert_operational_failure() {
  name="$1"
  category="$2"
  expression="$3"
  replacement="$4"
  broken="$fixture_root/checker-$name.sh"
  /usr/bin/sed "s#$expression#$replacement#" "$checker" > "$broken"
  /bin/chmod +x "$broken"
  probe_status=0
  "$broken" "$accepted" > "$fixture_root/operational-$name.stdout" \
    2> "$fixture_root/operational-$name.stderr" || probe_status=$?
  test "$probe_status" -eq 2
  test "$(/bin/cat "$fixture_root/operational-$name.stderr")" = "$category"
  test ! -s "$fixture_root/operational-$name.stdout"
}

assert_operational_failure find UNVERIFIABLE_SURFACE_ENUMERATION \
  '/usr/bin/find "$surface_root"' '/usr/bin/false "$surface_root"'
assert_operational_failure stat UNVERIFIABLE_SURFACE_METADATA \
  '/usr/bin/stat -f' '/usr/bin/false -f'
assert_operational_failure file UNVERIFIABLE_SURFACE_TYPE \
  '/usr/bin/file -b' '/usr/bin/false -b'
assert_operational_failure rg UNVERIFIABLE_SURFACE_SCAN \
  'LC_ALL=C rg' "LC_ALL=C /bin/sh -c 'exit 7'"

printf '%s\n' EXTERNAL_SURFACE_TESTS_PASSED
