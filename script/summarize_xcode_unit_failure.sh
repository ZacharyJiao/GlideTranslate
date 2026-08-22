#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

result_bundle="${1:?result bundle required}"
summary_prefix=XCODE_UNIT_FAILURE_SUMMARY
rm_bin="${UNIT_SUMMARY_RM_BIN:-/bin/rm}"
private_root_removed=0
emit_unverifiable() {
  printf '%s\n' "$summary_prefix:UNVERIFIABLE"
  exit 0
}

test -d "$result_bundle" || emit_unverifiable
private_root="$(mktemp -d 2>/dev/null || true)"
test -n "$private_root" || emit_unverifiable
cleanup() {
  prior_status=$?
  trap - EXIT INT TERM HUP
  cleanup_status=0
  if [ "$private_root_removed" -eq 0 ] && [ -e "$private_root" ]; then
    "$rm_bin" -rf "$private_root" >/dev/null 2>&1 || cleanup_status=$?
  fi
  if [ "$prior_status" -ne 0 ]; then exit "$prior_status"; fi
  if [ "$cleanup_status" -ne 0 ]; then exit 2; fi
  exit 0
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

xcrun_bin="${XCRUN_BIN:-/usr/bin/xcrun}"
tool_status=0
"$xcrun_bin" xcresulttool get test-results summary \
  --path "$result_bundle" --compact \
  > "$private_root/summary.json" \
  2> "$private_root/xcresulttool.stderr" || tool_status=$?
test "$tool_status" -eq 0 || emit_unverifiable

parse_status=0
/usr/bin/jq -r '
  def failure_kind:
    if (.failureText | test("(?i)timeout|timed out")) then "timeout"
    elif (.failureText | test("(?i)crash|uncaught exception|signal")) then "crash"
    elif (.failureText | test("(?i)setUp|tearDown|setup|teardown")) then "setup"
    elif (.failureText | test("(?i)assert|failed")) then "assertion"
    else "unknown"
    end;
  if (type != "object" or
      .result != "Failed" or
      .failedTests != 1 or
      (.testFailures | type) != "array" or
      (.testFailures | length) != 1) then
    error("summary shape")
  else .testFailures[0] end
  | if (.targetName | type) != "string" or
       .targetName != "GlideTranslateTests" or
       (.testIdentifierString | type) != "string" or
       (.testIdentifierString | length) > 160 or
       (.testIdentifierString | test("^GlideTranslateTests/[A-Za-z_][A-Za-z0-9_]*/[A-Za-z_][A-Za-z0-9_]*(\\(\\))?$") | not) or
       (.failureText | type) != "string" or
       (.failureText | length) > 65536 then
    error("failure fields")
  else
    [.targetName, .testIdentifierString, failure_kind] | @tsv
  end
' "$private_root/summary.json" > "$private_root/normalized.tsv" \
  2> "$private_root/jq.stderr" || parse_status=$?
test "$parse_status" -eq 0 || emit_unverifiable
test "$(/usr/bin/wc -l < "$private_root/normalized.tsv" | /usr/bin/tr -d ' ')" -eq 1 || emit_unverifiable

IFS=$'\t' read -r target identifier kind < "$private_root/normalized.tsv" || emit_unverifiable
test "$target" = GlideTranslateTests || emit_unverifiable
case "$kind" in
  assertion|setup|crash|timeout|unknown) ;;
  *) emit_unverifiable ;;
esac
case "$identifier" in
  GlideTranslateTests/*) ;;
  *) emit_unverifiable ;;
esac
public_summary="$summary_prefix:$identifier:$kind"
if "$rm_bin" -rf "$private_root" >/dev/null 2>&1; then
  private_root_removed=1
else
  printf '%s\n' "$summary_prefix:UNVERIFIABLE"
  exit 2
fi
trap - EXIT INT TERM HUP
printf '%s\n' "$public_summary"
