#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

workspace_root="$(cd "$(dirname "$0")/.." && pwd)"
summarizer="$workspace_root/script/summarize_xcode_unit_failure.sh"
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

fake_xcrun="$fixture_root/xcrun"
printf '%s\n' '#!/usr/bin/env bash' \
  'if [ "${GT_XCRESULT_FAILURE:-0}" -eq 1 ]; then exit 7; fi' \
  'exec /bin/cat "${GT_XCRESULT_FIXTURE:?}"' > "$fake_xcrun"
/bin/chmod 755 "$fake_xcrun"
failing_rm="$fixture_root/failing-rm"
rm_state="$fixture_root/rm-state"
rm_target="$fixture_root/rm-target"
printf '%s\n' '#!/usr/bin/env bash' \
  'if [ "$1" = -rf ] && [ ! -e "${GT_RM_STATE_FILE:?}" ]; then' \
  '  : > "$GT_RM_STATE_FILE"' \
  '  printf "%s\n" "$2" > "${GT_RM_TARGET_FILE:?}"' \
  '  exit 23' \
  'fi' \
  'exec /bin/rm "$@"' > "$failing_rm"
/bin/chmod 755 "$failing_rm"
signal_xcrun="$fixture_root/signal-xcrun"
printf '%s\n' '#!/usr/bin/env bash' 'kill -TERM "$PPID"' > "$signal_xcrun"
/bin/chmod 755 "$signal_xcrun"

make_bundle() {
  name="$1"
  json="$2"
  bundle="$fixture_root/$name.xcresult"
  /bin/mkdir "$bundle"
  printf '%s\n' "$json" > "$fixture_root/$name.json"
  printf '%s\n' "$bundle"
}

assert_summary() {
  name="$1"
  expected="$2"
  bundle="$3"
  output="$fixture_root/$name.output"
  error="$fixture_root/$name.error"
  XCRUN_BIN="$fake_xcrun" GT_XCRESULT_FIXTURE="$fixture_root/$name.json" \
    "$summarizer" "$bundle" > "$output" 2> "$error"
  test "$(/bin/cat "$output")" = "$expected"
  test ! -s "$error"
  private_path_prefix='/'"Users/"
  content_marker='GT_PRIVATE_'"USER_CONTENT"
  secret_marker='sec'"ret"
  ! rg -q "$private_path_prefix|$content_marker|assertion text|$secret_marker" "$output"
}

assert_unverifiable() {
  name="$1"
  bundle="$2"
  output="$fixture_root/$name.output"
  error="$fixture_root/$name.error"
  env XCRUN_BIN="$fake_xcrun" GT_XCRESULT_FIXTURE="$fixture_root/$name.json" \
    "$summarizer" "$bundle" > "$output" 2> "$error"
  test "$(/bin/cat "$output")" = XCODE_UNIT_FAILURE_SUMMARY:UNVERIFIABLE
  test ! -s "$error"
}

assert_summary assertion \
  XCODE_UNIT_FAILURE_SUMMARY:GlideTranslateTests/SampleTests/testExample\(\):assertion \
  "$(make_bundle assertion '{"result":"Failed","failedTests":1,"testFailures":[{"targetName":"GlideTranslateTests","testIdentifierString":"GlideTranslateTests/SampleTests/testExample()","failureText":"XCTAssertEqual failed"}]}')"
assert_summary setup \
  XCODE_UNIT_FAILURE_SUMMARY:GlideTranslateTests/SampleTests/testExample\(\):setup \
  "$(make_bundle setup '{"result":"Failed","failedTests":1,"testFailures":[{"targetName":"GlideTranslateTests","testIdentifierString":"GlideTranslateTests/SampleTests/testExample()","failureText":"setUp failed"}]}')"
assert_summary crash \
  XCODE_UNIT_FAILURE_SUMMARY:GlideTranslateTests/SampleTests/testExample\(\):crash \
  "$(make_bundle crash '{"result":"Failed","failedTests":1,"testFailures":[{"targetName":"GlideTranslateTests","testIdentifierString":"GlideTranslateTests/SampleTests/testExample()","failureText":"uncaught exception"}]}')"
assert_summary timeout \
  XCODE_UNIT_FAILURE_SUMMARY:GlideTranslateTests/SampleTests/testExample\(\):timeout \
  "$(make_bundle timeout '{"result":"Failed","failedTests":1,"testFailures":[{"targetName":"GlideTranslateTests","testIdentifierString":"GlideTranslateTests/SampleTests/testExample()","failureText":"test timed out"}]}')"
private_path='/'"Users/private/"'sec'"ret"
content_marker='GT_PRIVATE_'"USER_CONTENT"
unknown_json="$(printf '{"result":"Failed","failedTests":1,"testFailures":[{"targetName":"GlideTranslateTests","testIdentifierString":"GlideTranslateTests/SampleTests/testExample()","failureText":"%s %s"}]}' "$content_marker" "$private_path")"
assert_summary unknown \
  XCODE_UNIT_FAILURE_SUMMARY:GlideTranslateTests/SampleTests/testExample\(\):unknown \
  "$(make_bundle unknown "$unknown_json")"

make_bundle malformed '{malformed' >/dev/null
assert_unverifiable malformed "$fixture_root/malformed.xcresult"
make_bundle zero '{"result":"Failed","failedTests":0,"testFailures":[]}' >/dev/null
assert_unverifiable zero "$fixture_root/zero.xcresult"
make_bundle multiple '{"result":"Failed","failedTests":2,"testFailures":[{"targetName":"GlideTranslateTests","testIdentifierString":"GlideTranslateTests/SampleTests/testA()","failureText":"assertion"},{"targetName":"GlideTranslateTests","testIdentifierString":"GlideTranslateTests/SampleTests/testB()","failureText":"assertion"}]}' >/dev/null
assert_unverifiable multiple "$fixture_root/multiple.xcresult"
make_bundle wrong-target '{"result":"Failed","failedTests":1,"testFailures":[{"targetName":"OtherTests","testIdentifierString":"OtherTests/SampleTests/testA()","failureText":"assertion"}]}' >/dev/null
assert_unverifiable wrong-target "$fixture_root/wrong-target.xcresult"
make_bundle malformed-id '{"result":"Failed","failedTests":1,"testFailures":[{"targetName":"GlideTranslateTests","testIdentifierString":"GlideTranslateTests/../private","failureText":"assertion"}]}' >/dev/null
assert_unverifiable malformed-id "$fixture_root/malformed-id.xcresult"

oversized_id="GlideTranslateTests/SampleTests/"
while [ "${#oversized_id}" -lt 201 ]; do oversized_id="${oversized_id}A"; done
make_bundle oversized "$(printf '{"result":"Failed","failedTests":1,"testFailures":[{"targetName":"GlideTranslateTests","testIdentifierString":"%s","failureText":"assertion"}]}' "$oversized_id")" >/dev/null
assert_unverifiable oversized "$fixture_root/oversized.xcresult"

printf '%s\n' 'not used' > "$fixture_root/tool-failure.json"
tool_failure_output="$fixture_root/tool-failure.output"
tool_failure_error="$fixture_root/tool-failure.error"
XCRUN_BIN="$fake_xcrun" GT_XCRESULT_FIXTURE="$fixture_root/tool-failure.json" \
  GT_XCRESULT_FAILURE=1 "$summarizer" "$fixture_root/tool-failure.xcresult" \
  > "$tool_failure_output" 2> "$tool_failure_error"
test "$(/bin/cat "$tool_failure_output")" = XCODE_UNIT_FAILURE_SUMMARY:UNVERIFIABLE
test ! -s "$tool_failure_error"

cleanup_bundle="$(make_bundle cleanup-failure '{"result":"Failed","failedTests":1,"testFailures":[{"targetName":"GlideTranslateTests","testIdentifierString":"GlideTranslateTests/SampleTests/testExample()","failureText":"XCTAssertEqual failed"}]}')"
cleanup_output="$fixture_root/cleanup-failure.output"
cleanup_error="$fixture_root/cleanup-failure.error"
cleanup_status=0
XCRUN_BIN="$fake_xcrun" GT_XCRESULT_FIXTURE="$fixture_root/cleanup-failure.json" \
  UNIT_SUMMARY_RM_BIN="$failing_rm" GT_RM_STATE_FILE="$rm_state" \
  GT_RM_TARGET_FILE="$rm_target" "$summarizer" "$cleanup_bundle" \
  > "$cleanup_output" 2> "$cleanup_error" || cleanup_status=$?
test "$cleanup_status" -ne 0
test "$(/bin/cat "$cleanup_output")" = XCODE_UNIT_FAILURE_SUMMARY:UNVERIFIABLE
test ! -s "$cleanup_error"
private_path_prefix='/'"Users/"
content_marker='GT_PRIVATE_'"USER_CONTENT"
secret_marker='sec'"ret"
! rg -q "$private_path_prefix|$content_marker|$secret_marker|XCTAssert" "$cleanup_output"
cleanup_private_root="$(/bin/cat "$rm_target")"
test ! -e "$cleanup_private_root"

signal_output="$fixture_root/signal.output"
signal_error="$fixture_root/signal.error"
signal_status=0
XCRUN_BIN="$signal_xcrun" "$summarizer" "$cleanup_bundle" \
  > "$signal_output" 2> "$signal_error" || signal_status=$?
test "$signal_status" -eq 143
test ! -s "$signal_output"
test ! -s "$signal_error"

printf '%s\n' SUMMARIZE_XCODE_UNIT_FAILURE_TESTS_PASS
