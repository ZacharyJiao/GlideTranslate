#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

workspace_root="$(cd "$(dirname "$0")/.." && pwd)"
classifier="$workspace_root/script/classify_release_uris.py"
fixture_parent="$(mktemp -d)"
fixture_cleanup_enabled=0

cleanup() {
  prior_status=$?
  trap - EXIT INT TERM HUP
  cleanup_status=0
  if [ "$fixture_cleanup_enabled" -eq 1 ]; then
    /bin/rm -rf "$fixture_parent" >/dev/null 2>&1 || cleanup_status=$?
  else
    printf '%s\n' URI_CLASSIFIER_TEST_EVIDENCE_RETAINED >&2
  fi
  if [ "$prior_status" -ne 0 ]; then exit "$prior_status"; fi
  exit "$cleanup_status"
}
retain_on_signal() {
  signal_status="$1"
  trap - EXIT INT TERM HUP
  printf '%s\n' URI_CLASSIFIER_TEST_EVIDENCE_RETAINED >&2
  exit "$signal_status"
}
trap cleanup EXIT
trap 'retain_on_signal 130' INT
trap 'retain_on_signal 143' TERM
trap 'retain_on_signal 129' HUP

test -x "$classifier"
test -s "$classifier"
rg -q 'from urllib.parse import .*urlsplit' "$classifier"
rg -q '^import ipaddress$' "$classifier"
rg -q 'MAX_INPUT_BYTES|MAX_TOKEN_BYTES|MAX_URI_COUNT' "$classifier"
rg -q 'MAX_RADR_IDENTIFIER_DIGITS|allow_exact|--no-allow-exact' "$classifier"
rg -q 'IPv4Address|IPv6Address|urlsplit' "$classifier"
rg -q 'is_private|is_loopback|is_link_local|is_unspecified|is_multicast|is_reserved|is_site_local' "$classifier"
rg -q 'for scheme in ftp ws wss custom' "$0"
rg -q 'localhost.localdomain|fe80|::ffff|0x7f000001|017700000001' "$0"
rg -q 'allowed-subdelimiter|public-subdelimiters|radr-no-exception|radr-maximum-length' "$0"

run_case() {
  case_name="$1"
  expected_status="$2"
  expected_output="$3"
  value="$4"
  case_root="$fixture_parent/$case_name"
  /bin/mkdir -p "$case_root"
  printf '%s' "$value" > "$case_root/payload.bin"
  status=0
  "$classifier" --allow-exact "$case_root/payload.bin" \
    > "$case_root/stdout" 2> "$case_root/stderr" || status=$?
  test "$status" -eq "$expected_status"
  test "$(/bin/cat "$case_root/stdout")" = "$expected_output"
  test ! -s "$case_root/stderr"
  ! rg -Fq "$value" "$case_root/stdout" "$case_root/stderr"
}

allowed='http:'"//127.0.0.1:11434"
run_case allowed 0 PASS "$allowed"
run_case allowed-comma 2 UNVERIFIABLE_SURFACE_URI "$allowed,"
run_case allowed-parenthesized 2 UNVERIFIABLE_SURFACE_URI "($allowed)"
for suffix in ';token=1' "'token" '(token)' '!token' '$token' '&token' '*token' '+token' '=token'; do
  run_case "allowed-subdelimiter-${RANDOM}" 2 UNVERIFIABLE_SURFACE_URI \
    "$allowed$suffix"
done
run_case allowed-double-quoted 0 PASS "\"$allowed\""
run_case public 0 PASS 'https:'"//api.github.com/v1"
run_case public-subdelimiters 0 PASS 'https:'"//example.invalid/path;param,part?x=1&y=2"
run_case non-uri 0 PASS 'not a URI: example.invalid'

for host in 8.8.8.8 1.1.1.1 93.184.216.34; do
  run_case "public-ipv4-${host//./_}" 0 PASS "custom://$host:443"
done
for host in 100.63.255.255 100.128.0.0; do
  run_case "cgnat-outside-${host//./_}" 0 PASS "custom://$host:443"
done
for host in 100.64.0.0 100.100.50.25 100.127.255.255; do
  run_case "cgnat-${host//./_}" 1 PROHIBITED_PRIVATE_ENDPOINT \
    "custom://$host:443"
done
for host in '[2001:4860:4860::8888]' '[2606:4700:4700::1111]' '[2001:4860:4860:0:0:0:0:8888]'; do
  run_case "public-ipv6-${host//[^A-Za-z0-9]/_}" 0 PASS "custom://$host:443"
done

for host in 224.0.0.1 239.255.255.250 233.252.0.1; do
  run_case "ipv4-multicast-${host//./_}" 1 PROHIBITED_PRIVATE_ENDPOINT \
    "custom://$host:443"
done
for host in '[ff02::1]' '[ff05::2]' '[fec0::1]'; do
  run_case "ipv6-scoped-${host//[^A-Za-z0-9]/_}" 1 PROHIBITED_PRIVATE_ENDPOINT \
    "custom://$host:443"
done
run_case mapped-multicast 1 PROHIBITED_PRIVATE_ENDPOINT \
  'custom://[::ffff:224.0.0.1]:443'
run_case mapped-cgnat 1 PROHIBITED_PRIVATE_ENDPOINT \
  'custom://[::ffff:100.64.0.1]:443'
run_case mapped-public-unicast 0 PASS \
  'custom://[::ffff:8.8.8.8]:443'
run_case radr-opaque-identifier 0 PASS 'radr://5614542'
run_case radr-maximum-length 1 PROHIBITED_PRIVATE_ENDPOINT 'radr://2130706433'

path_only_root="$fixture_parent/path-only"
/bin/mkdir -p "$path_only_root"
printf '%s' "$allowed" > "$path_only_root/payload.bin"
path_only_status=0
"$classifier" "$path_only_root/payload.bin" \
  > "$path_only_root/stdout" 2> "$path_only_root/stderr" || path_only_status=$?
test "$path_only_status" -eq 1
test "$(/bin/cat "$path_only_root/stdout")" = PROHIBITED_PRIVATE_ENDPOINT
test ! -s "$path_only_root/stderr"

radr_no_exception_root="$fixture_parent/radr-no-exception"
/bin/mkdir -p "$radr_no_exception_root"
printf '%s' 'radr://2130706433' > "$radr_no_exception_root/payload.bin"
radr_no_exception_status=0
"$classifier" --no-allow-exact "$radr_no_exception_root/payload.bin" \
  > "$radr_no_exception_root/stdout" 2> "$radr_no_exception_root/stderr" \
  || radr_no_exception_status=$?
test "$radr_no_exception_status" -eq 1
test "$(/bin/cat "$radr_no_exception_root/stdout")" = PROHIBITED_PRIVATE_ENDPOINT
test ! -s "$radr_no_exception_root/stderr"

for scheme in ftp ws wss custom; do
  run_case "scheme-$scheme" 1 PROHIBITED_PRIVATE_ENDPOINT \
    "$scheme:""//127.0.0.1:11434"
done

for host in \
  localhost \
  foo.localhost \
  localhost.localdomain \
  0.0.0.0 \
  127.0.0.1 \
  127.1 \
  127.0.1 \
  2130706433 \
  0x7f000001 \
  017700000001 \
  10.2.3.4 \
  169.254.10.20 \
  172.16.0.1 \
  192.168.1.10; do
  run_case "host-${host//[^A-Za-z0-9]/_}" 1 PROHIBITED_PRIVATE_ENDPOINT \
    "custom://$host:11434"
done

for host in \
  '[::1]' \
  '[0:0:0:0:0:0:0:1]' \
  '[::]' \
  '[fe80::1]' \
  '[fe80:0:0:0:0:0:0:1]' \
  '[fe80::1%25en0]' \
  '[fc00::1]' \
  '[fd12:3456::1]' \
  '[fd12:3456:0:0:0:0:0:1]' \
  '[::ffff:127.0.0.1]' \
  '[::ffff:10.0.0.1]' \
  '[::ffff:7f00:1]' \
  '[0:0:0:0:0:ffff:127.0.0.1]' \
  '[0:0:0:0:0:ffff:7f00:1]' \
  '[0:0:0:0:0:ffff:0a00:1]' \
  '[::ffff:192.168.1.10]' \
  '[2001:db8::1]'; do
  run_case "ipv6-${host//[^A-Za-z0-9]/_}" 1 PROHIBITED_PRIVATE_ENDPOINT \
    "custom://$host:11434"
done

run_case ipv6-zone-unescaped 2 UNVERIFIABLE_SURFACE_URI \
  'custom://[fe80::1%en0]:11434'

run_case userinfo 1 PROHIBITED_PRIVATE_ENDPOINT \
  'custom://user:pass@127.0.0.1:11434'
run_case public-userinfo 1 PROHIBITED_PRIVATE_ENDPOINT \
  'custom://user:pass@example.invalid:443'
run_case percent-host 1 PROHIBITED_PRIVATE_ENDPOINT \
  'custom://%31%32%37.%30.%30.%31:11434'
run_case idna-local 1 PROHIBITED_PRIVATE_ENDPOINT \
  'custom://xn--localhost-9za.localhost:11434'
run_case malformed-empty-label 2 UNVERIFIABLE_SURFACE_URI \
  'custom://foo..bar:443'

for malformed in \
  'custom://[::1:11434' \
  'custom://:11434' \
  'custom://127.0.0.1:bad' \
  'custom://%ZZ:11434' \
  'custom://127.0.0.1%2Fprivate:11434' \
  'custom://user@@127.0.0.1:11434'; do
  run_case "malformed-${RANDOM}" 2 UNVERIFIABLE_SURFACE_URI "$malformed"
done

run_case path 1 PROHIBITED_PRIVATE_ENDPOINT \
  "$allowed/api/tags"
run_case query 1 PROHIBITED_PRIVATE_ENDPOINT \
  "$allowed?token=private"
run_case fragment 1 PROHIBITED_PRIVATE_ENDPOINT \
  "$allowed#private"
run_case host-suffix 2 UNVERIFIABLE_SURFACE_URI \
  "$allowed.example"
run_case scheme-case 1 PROHIBITED_PRIVATE_ENDPOINT \
  'HTTP:'"//127.0.0.1:11434"

mixed_private="$allowed custom://192.168.1.10:11434"
run_case mixed 1 PROHIBITED_PRIVATE_ENDPOINT "$mixed_private"
multiple_allowed="$allowed $allowed"
run_case multiple-allowed 0 PASS "$multiple_allowed"
no_exception_root="$fixture_parent/no-exact-exception"
/bin/mkdir -p "$no_exception_root"
printf '%s' "$allowed" > "$no_exception_root/payload.bin"
no_exception_status=0
"$classifier" --no-allow-exact "$no_exception_root/payload.bin" \
  > "$no_exception_root/stdout" 2> "$no_exception_root/stderr" \
  || no_exception_status=$?
test "$no_exception_status" -eq 1
test "$(/bin/cat "$no_exception_root/stdout")" = PROHIBITED_PRIVATE_ENDPOINT
test ! -s "$no_exception_root/stderr"
printf '%s\0%s\0' "$allowed" 'custom://127.0.0.1:11435' \
  > "$fixture_parent/nul-mixed.bin"
status=0
"$classifier" "$fixture_parent/nul-mixed.bin" \
  > "$fixture_parent/nul-mixed.stdout" \
  2> "$fixture_parent/nul-mixed.stderr" || status=$?
test "$status" -eq 1
test "$(/bin/cat "$fixture_parent/nul-mixed.stdout")" = PROHIBITED_PRIVATE_ENDPOINT
test ! -s "$fixture_parent/nul-mixed.stderr"

long_token="custom://example.invalid/$(/usr/bin/head -c 9000 /dev/zero | /usr/bin/tr '\000' a)"
run_case overlong 2 UNVERIFIABLE_SURFACE_URI "$long_token"

many_tokens="$fixture_parent/many.bin"
: > "$many_tokens"
for i in $(/usr/bin/seq 1 4097); do
  printf '%s%s' 'custom://example.invalid:443/' "$i" >> "$many_tokens"
  printf ' ' >> "$many_tokens"
done
status=0
"$classifier" "$many_tokens" > "$fixture_parent/many.stdout" \
  2> "$fixture_parent/many.stderr" || status=$?
test "$status" -eq 2
test "$(/bin/cat "$fixture_parent/many.stdout")" = UNVERIFIABLE_SURFACE_URI
test ! -s "$fixture_parent/many.stderr"

/usr/bin/truncate -s 67108865 "$fixture_parent/oversized.bin"
status=0
"$classifier" "$fixture_parent/oversized.bin" \
  > "$fixture_parent/oversized.stdout" \
  2> "$fixture_parent/oversized.stderr" || status=$?
test "$status" -eq 2
test "$(/bin/cat "$fixture_parent/oversized.stdout")" = UNVERIFIABLE_SURFACE_URI
test ! -s "$fixture_parent/oversized.stderr"

/bin/ln -s "$fixture_parent/allowed/payload.bin" "$fixture_parent/symlink"
status=0
"$classifier" "$fixture_parent/symlink" \
  > "$fixture_parent/symlink.stdout" \
  2> "$fixture_parent/symlink.stderr" || status=$?
test "$status" -eq 3
test ! -s "$fixture_parent/symlink.stdout"
test ! -s "$fixture_parent/symlink.stderr"

for invalid_input in "$fixture_parent/missing" "$fixture_parent/allowed"; do
  status=0
  "$classifier" "$invalid_input" \
    > "$fixture_parent/invalid.stdout" \
    2> "$fixture_parent/invalid.stderr" || status=$?
  test "$status" -eq 3
  test ! -s "$fixture_parent/invalid.stdout"
  test ! -s "$fixture_parent/invalid.stderr"
done

fixture_cleanup_enabled=1
printf '%s\n' URI_CLASSIFIER_TESTS_PASS
