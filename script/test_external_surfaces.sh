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
"$workspace_root/script/test_classify_release_uris.sh"

accepted="$fixture_root/accepted"
/bin/mkdir -p "$accepted"
printf '%s\n' '{"login":"public-user","email":"12345+public@users.noreply.github.com","url":"https://api.github.com/users/public-user","ssh_url":"git@github.com:example/repository.git"}' > "$accepted/metadata.json"
printf '%s\n' public > "$accepted/12345+public@users.noreply.github.com"
printf '%s\n' public > "$accepted/maintainer@example.com"
printf '%s\n' \
  'Authorization:'" Basic ***" \
  '/'"Users/runner/work/example/repository" \
  '/'"opt/homebrew/bin/example-tool" \
  > "$accepted/run-123.log"
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
private_run_root="$fixture_root/private-runner-path"
/bin/mkdir -p "$private_run_root"
printf '%s\n' '/'"Users/private-user/work/repository" \
  > "$private_run_root/run-999.log"
private_run_status=0
"$checker" "$private_run_root" > "$fixture_root/private-runner-path.stdout" \
  2> "$fixture_root/private-runner-path.stderr" || private_run_status=$?
test "$private_run_status" -ne 0
rg -q '^PROHIBITED_ABSOLUTE_PATH:' \
  "$fixture_root/private-runner-path.stderr"
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

release_payload_root="$fixture_root/release-payload"
release_main_path="GlideTranslate.app/Contents/MacOS/GlideTranslate"
/bin/mkdir -p "$release_payload_root/GlideTranslate.app/Contents/MacOS" \
  "$release_payload_root/GlideTranslate.app/Contents/Resources"
loopback_scheme='http:'"//"
loopback_host='127.'"0.0.1"
allowed_loopback="$loopback_scheme$loopback_host:11434"
printf '%s\n' "$allowed_loopback" \
  > "$release_payload_root/$release_main_path"
release_status=0
"$checker" --release-payload "$release_payload_root" \
  > "$fixture_root/release-accepted.stdout" \
  2> "$fixture_root/release-accepted.stderr" || release_status=$?
test "$release_status" -eq 0
test "$(/bin/cat "$fixture_root/release-accepted.stdout")" = EXTERNAL_SURFACE_SCAN_PASSED
test ! -s "$fixture_root/release-accepted.stderr"

# The exact loopback exception is scoped to the extracted main executable;
# arbitrary-scheme local endpoints in resources must still be rejected.
resource_scheme='ftp:'"//"
printf '%s\n' "$resource_scheme$loopback_host:11434" \
  > "$release_payload_root/GlideTranslate.app/Contents/Resources/config.txt"
resource_path_status=0
"$checker" --release-payload "$release_payload_root" \
  > "$fixture_root/release-resource.stdout" \
  2> "$fixture_root/release-resource.stderr" || resource_path_status=$?
test "$resource_path_status" -ne 0
rg -q '^PROHIBITED_PRIVATE_ENDPOINT:' "$fixture_root/release-resource.stderr"
test ! -s "$fixture_root/release-resource.stdout"
/bin/rm -f "$release_payload_root/GlideTranslate.app/Contents/Resources/config.txt"

# The opaque diagnostic exception is restricted to the exact main executable
# context and cannot mask a legacy loopback integer or resource-file token.
printf '%s\n' 'radr://2130706433' \
  > "$release_payload_root/$release_main_path"
radr_main_status=0
"$checker" --release-payload "$release_payload_root" \
  > "$fixture_root/release-radr-main.stdout" \
  2> "$fixture_root/release-radr-main.stderr" || radr_main_status=$?
test "$radr_main_status" -ne 0
rg -q '^PROHIBITED_PRIVATE_ENDPOINT:' "$fixture_root/release-radr-main.stderr"
test ! -s "$fixture_root/release-radr-main.stdout"

printf '%s\n' 'radr://5614542' \
  > "$release_payload_root/GlideTranslate.app/Contents/Resources/radr.txt"
radr_resource_status=0
"$checker" --release-payload "$release_payload_root" \
  > "$fixture_root/release-radr-resource.stdout" \
  2> "$fixture_root/release-radr-resource.stderr" || radr_resource_status=$?
test "$radr_resource_status" -ne 0
rg -q '^PROHIBITED_PRIVATE_ENDPOINT:' "$fixture_root/release-radr-resource.stderr"
test ! -s "$fixture_root/release-radr-resource.stdout"
/bin/rm -f "$release_payload_root/$release_main_path" \
  "$release_payload_root/GlideTranslate.app/Contents/Resources/radr.txt"

printf '%s\n' "$allowed_loopback" 'radr://5614542' \
  > "$release_payload_root/$release_main_path"

uri_classifier_injection="$fixture_root/uri-classifier-injection"
printf '%s\n' '#!/usr/bin/env bash' \
  'printf "%s\\n" "PASS" "URI_OUTPUT_INJECTION"' \
  > "$uri_classifier_injection"
/bin/chmod 755 "$uri_classifier_injection"
injection_status=0
RELEASE_URI_CLASSIFIER="$uri_classifier_injection" \
  "$checker" --release-payload "$release_payload_root" \
  > "$fixture_root/release-injection.stdout" \
  2> "$fixture_root/release-injection.stderr" || injection_status=$?
test "$injection_status" -eq 2
test "$(/bin/cat "$fixture_root/release-injection.stderr")" = UNVERIFIABLE_SURFACE_SCAN
test ! -s "$fixture_root/release-injection.stdout"
! rg -Fq URI_OUTPUT_INJECTION "$fixture_root/release-injection.stdout" \
  "$fixture_root/release-injection.stderr"

uri_classifier_failure="$fixture_root/uri-classifier-failure"
printf '%s\n' '#!/usr/bin/env bash' 'exit 23' > "$uri_classifier_failure"
/bin/chmod 755 "$uri_classifier_failure"
classifier_failure_status=0
RELEASE_URI_CLASSIFIER="$uri_classifier_failure" \
  "$checker" --release-payload "$release_payload_root" \
  > "$fixture_root/release-classifier-failure.stdout" \
  2> "$fixture_root/release-classifier-failure.stderr" \
  || classifier_failure_status=$?
test "$classifier_failure_status" -eq 2
test "$(/bin/cat "$fixture_root/release-classifier-failure.stderr")" = UNVERIFIABLE_SURFACE_SCAN
test ! -s "$fixture_root/release-classifier-failure.stdout"

uri_classifier_symlink="$fixture_root/uri-classifier-symlink"
/bin/ln -s "$checker" "$uri_classifier_symlink"
symlink_classifier_status=0
RELEASE_URI_CLASSIFIER="$uri_classifier_symlink" \
  "$checker" --release-payload "$release_payload_root" \
  > "$fixture_root/release-classifier-symlink.stdout" \
  2> "$fixture_root/release-classifier-symlink.stderr" \
  || symlink_classifier_status=$?
test "$symlink_classifier_status" -eq 2
test "$(/bin/cat "$fixture_root/release-classifier-symlink.stderr")" = UNVERIFIABLE_SURFACE_SCAN
test ! -s "$fixture_root/release-classifier-symlink.stdout"

assert_release_rejected() {
  name="$1"
  value="$2"
  relative_path="${3:-$release_main_path}"
  root="$fixture_root/release-$name"
  /bin/mkdir -p "$root/GlideTranslate.app/Contents/MacOS" \
    "$root/GlideTranslate.app/Contents/Resources"
  printf '%s\n' "$value" > "$root/$relative_path"
  status=0
  "$checker" --release-payload "$root" \
    > "$fixture_root/release-$name.stdout" \
    2> "$fixture_root/release-$name.stderr" || status=$?
  test "$status" -ne 0
  rg -q '^(PROHIBITED_PRIVATE_ENDPOINT|UNVERIFIABLE_SURFACE_URI):' \
    "$fixture_root/release-$name.stderr"
  test ! -s "$fixture_root/release-$name.stdout"
}

assert_release_rejected wrong-port \
  "$loopback_scheme$loopback_host:11435"
assert_release_rejected wrong-scheme \
  'https:'"//$loopback_host:11434"
assert_release_rejected localhost \
  'http:'"//localhost:11434"
assert_release_rejected wrong-path "$allowed_loopback" \
  GlideTranslate.app/Contents/Resources/config.txt
credential_endpoint="$loopback_scheme"'user:pass@'"$loopback_host:11434"
assert_release_rejected credentials "$credential_endpoint"
lan_host='192.'"168.1.10"
assert_release_rejected lan \
  "$loopback_scheme$lan_host:11434"
mixed_value="$allowed_loopback $loopback_scheme$loopback_host:11435"
assert_release_rejected mixed "$mixed_value"

assert_release_rejected prefix-suffix "$allowed_loopback"'suffix'
assert_release_rejected path-suffix "$allowed_loopback"'/api/tags'
assert_release_rejected query-suffix "$allowed_loopback"'?token=private'
assert_release_rejected fragment-suffix "$allowed_loopback"'#private'
assert_release_rejected host-suffix "$allowed_loopback"'.example'
assert_release_rejected shorthand "$loopback_scheme"'127.1:11434'
assert_release_rejected integer "$loopback_scheme"'2130706433:11434'
assert_release_rejected hexadecimal "$loopback_scheme"'0x7f000001:11434'
assert_release_rejected octal "$loopback_scheme"'017700000001:11434'
assert_release_rejected mapped-ipv4 "$loopback_scheme"'[::ffff:127.0.0.1]:11434'
assert_release_rejected mapped-hex "$loopback_scheme"'[::ffff:7f00:1]:11434'
assert_release_rejected expanded-ipv6 "$loopback_scheme"'[0:0:0:0:0:0:0:1]:11434'
assert_release_rejected ipv6-loopback "$loopback_scheme"'[::1]:11434'

assert_release_binary_allowed() {
  name="$1"
  value="$2"
  root="$fixture_root/release-$name"
  /bin/mkdir -p "$root/GlideTranslate.app/Contents/MacOS" \
    "$root/GlideTranslate.app/Contents/Resources"
  printf '%s\0' "$value" > "$root/$release_main_path"
  status=0
  "$checker" --release-payload "$root" \
    > "$fixture_root/release-$name.stdout" \
    2> "$fixture_root/release-$name.stderr" || status=$?
  test "$status" -eq 0
  test "$(/bin/cat "$fixture_root/release-$name.stdout")" = EXTERNAL_SURFACE_SCAN_PASSED
  test ! -s "$fixture_root/release-$name.stderr"
}

assert_release_binary_allowed nul-delimited "$allowed_loopback"

multiple_allowed_root="$fixture_root/release-multiple-allowed"
/bin/mkdir -p "$multiple_allowed_root/GlideTranslate.app/Contents/MacOS" \
  "$multiple_allowed_root/GlideTranslate.app/Contents/Resources"
printf '%s %s' "$allowed_loopback" "$allowed_loopback" \
  > "$multiple_allowed_root/$release_main_path"
multiple_allowed_status=0
"$checker" --release-payload "$multiple_allowed_root" \
  > "$fixture_root/release-multiple-allowed.stdout" \
  2> "$fixture_root/release-multiple-allowed.stderr" || multiple_allowed_status=$?
test "$multiple_allowed_status" -eq 0
test "$(/bin/cat "$fixture_root/release-multiple-allowed.stdout")" = EXTERNAL_SURFACE_SCAN_PASSED
test ! -s "$fixture_root/release-multiple-allowed.stderr"

mixed_nul_root="$fixture_root/release-mixed-nul"
/bin/mkdir -p "$mixed_nul_root/GlideTranslate.app/Contents/MacOS" \
  "$mixed_nul_root/GlideTranslate.app/Contents/Resources"
printf '%s\0%s\0' "$allowed_loopback" "$loopback_scheme$loopback_host:11435" \
  > "$mixed_nul_root/$release_main_path"
mixed_nul_status=0
"$checker" --release-payload "$mixed_nul_root" \
  > "$fixture_root/release-mixed-nul.stdout" \
  2> "$fixture_root/release-mixed-nul.stderr" || mixed_nul_status=$?
test "$mixed_nul_status" -ne 0
rg -q '^(PROHIBITED_PRIVATE_ENDPOINT|UNVERIFIABLE_SURFACE_TYPE):' \
  "$fixture_root/release-mixed-nul.stderr"
test ! -s "$fixture_root/release-mixed-nul.stdout"

generic_release_status=0
"$checker" "$release_payload_root" \
  > "$fixture_root/release-generic.stdout" \
  2> "$fixture_root/release-generic.stderr" || generic_release_status=$?
test "$generic_release_status" -ne 0
rg -q '^PROHIBITED_PRIVATE_ENDPOINT:' \
  "$fixture_root/release-generic.stderr"
test ! -s "$fixture_root/release-generic.stdout"

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

surface_root_symlink="$fixture_root/surface-root-symlink"
/bin/ln -s "$accepted" "$surface_root_symlink"
surface_root_symlink_status=0
"$checker" "$surface_root_symlink" \
  > "$fixture_root/surface-root-symlink.stdout" \
  2> "$fixture_root/surface-root-symlink.stderr" \
  || surface_root_symlink_status=$?
test "$surface_root_symlink_status" -eq 2
test "$(/bin/cat "$fixture_root/surface-root-symlink.stderr")" = UNVERIFIABLE_SURFACE_ROOT
test ! -s "$fixture_root/surface-root-symlink.stdout"

wrong_arity_status=0
"$checker" --release-payload "$release_payload_root" extra \
  > "$fixture_root/wrong-arity.stdout" \
  2> "$fixture_root/wrong-arity.stderr" || wrong_arity_status=$?
test "$wrong_arity_status" -eq 2
test "$(/bin/cat "$fixture_root/wrong-arity.stderr")" = UNVERIFIABLE_SURFACE_ROOT
test ! -s "$fixture_root/wrong-arity.stdout"

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
