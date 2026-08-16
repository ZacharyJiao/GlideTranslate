#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

workspace_root="$(cd "$(dirname "$0")/.." && pwd)"
fixture_root="$(mktemp -d)"
fixture_cleanup_enabled=1

cleanup_fixture() {
  prior_status=$?
  trap - EXIT INT TERM HUP
  cleanup_status=0
  if [ "$fixture_cleanup_enabled" -eq 1 ]; then
    /usr/bin/chflags -R nouchg "$fixture_root" 2>/dev/null || true
    /bin/rm -rf "$fixture_root" >/dev/null 2>&1 || cleanup_status=$?
  fi
  if [ "$prior_status" -ne 0 ]; then exit "$prior_status"; fi
  exit "$cleanup_status"
}
retain_fixture_on_signal() {
  signal_status="$1"
  trap - EXIT INT TERM HUP
  fixture_cleanup_enabled=0
  printf '%s\n' COMPATIBILITY_TEST_EVIDENCE_RETAINED >&2
  exit "$signal_status"
}
trap cleanup_fixture EXIT
trap 'retain_fixture_on_signal 130' INT
trap 'retain_fixture_on_signal 143' TERM
trap 'retain_fixture_on_signal 129' HUP

checker="$workspace_root/script/check_compatibility_report.sh"
test -x "$checker"

write_report() {
  report_path="$1"
  /bin/mkdir -p "$(dirname "$report_path")"
  printf '%s\n' \
    '# Compatibility' \
    '' \
    '| Application | Bundle ID | Tested Version | Mouse Automatic Disabled | Mouse Allowed | Optional Keyboard | Shortcut Selection | Shortcut Clipboard | Manual Input | Bounds | Classification | Limitation |' \
    '| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |' \
    '| Safari | com.apple.Safari | 26.5.2 | Blocked | Blocked | Blocked | Blocked | Blocked | Pass | Blocked | Manual-input | Selection paths require pending manual validation. |' \
    '| Chrome | com.google.Chrome | 151.0 | Blocked | Blocked | Blocked | Blocked | Blocked | Pass | Blocked | Blocked | Manual validation requires explicit opt-in. |' \
    '| TextEdit | com.apple.TextEdit | 1.20 | Pass | Pass | Pass | Pass | Pass | Pass | Pass | Full | None |' \
    '| Notes | com.apple.Notes | 4.13 | Blocked | Blocked | Blocked | Blocked | Blocked | Pass | Blocked | Text-only | Rich attachments are outside text selection coverage. |' \
    '| Xcode | com.apple.dt.Xcode | 26.6 | Blocked | Blocked | Blocked | Pass | Pass | Pass | Blocked | Shortcut-clipboard | Automatic capture remains pending manual validation. |' \
    '| Visual Studio Code | com.microsoft.VSCode | 1.132.1 | Blocked | Blocked | Blocked | Pass | Pass | Pass | Blocked | Shortcut-clipboard | Automatic capture remains pending manual validation. |' \
    '| Terminal | com.apple.Terminal | 2.15 | Rejected | Rejected | Rejected | Rejected | Rejected | Pass | Rejected | Rejected | Secure or non-text surfaces can reject selection capture. |' \
    '| Preview | com.apple.Preview | 11.0 | Blocked | Blocked | Blocked | Blocked | Blocked | Pass | Blocked | Blocked | PDF text selection requires pending manual validation. |' \
    > "$report_path"
}

expect_failure() {
  expected_status="$1"
  expected_marker="$2"
  private_fragment="$3"
  shift 3
  stdout_path="$fixture_root/expected.stdout"
  stderr_path="$fixture_root/expected.stderr"
  status=0
  "$@" > "$stdout_path" 2> "$stderr_path" || status=$?
  if [ "$status" -ne "$expected_status" ]; then
    printf 'COMPATIBILITY_FIXTURE_STATUS_UNEXPECTED:%s:%s\n' \
      "$expected_marker" "$status" >&2
    exit 1
  fi
  if ! /usr/bin/grep -Fq "$expected_marker" "$stderr_path"; then
    printf 'COMPATIBILITY_FIXTURE_MARKER_MISSING:%s\n' "$expected_marker" >&2
    exit 1
  fi
  if [ -s "$stdout_path" ]; then
    printf 'COMPATIBILITY_FIXTURE_STDOUT_UNEXPECTED:%s\n' "$expected_marker" >&2
    exit 1
  fi
  if [ -n "$private_fragment" ] && \
     /usr/bin/grep -Fq "$private_fragment" "$stderr_path"; then
    printf 'COMPATIBILITY_FIXTURE_PRIVATE_DIAGNOSTIC_LEAKED:%s\n' \
      "$expected_marker" >&2
    exit 1
  fi
  if /usr/bin/grep -Fq "$fixture_root" "$stderr_path"; then
    printf 'COMPATIBILITY_FIXTURE_ROOT_LEAKED:%s\n' "$expected_marker" >&2
    exit 1
  fi
}

valid_report="$fixture_root/valid.md"
write_report "$valid_report"
"$checker" "$valid_report"

missing_report="$fixture_root/missing.md"
write_report "$missing_report"
/usr/bin/sed '/^| Chrome |/d' "$valid_report" > "$missing_report"
expect_failure 1 COMPATIBILITY_ROW_MISSING:Chrome '' "$checker" "$missing_report"

duplicate_report="$fixture_root/duplicate.md"
write_report "$duplicate_report"
/usr/bin/sed '/^| Chrome |/p' "$valid_report" > "$duplicate_report"
expect_failure 1 COMPATIBILITY_ROW_COUNT:Chrome '' "$checker" "$duplicate_report"

unexpected_report="$fixture_root/unexpected.md"
write_report "$unexpected_report"
printf '%s\n' \
  '| Other App | invalid.example | 1 | Pass | Pass | Pass | Pass | Pass | Pass | Pass | Full | None |' \
  >> "$unexpected_report"
expect_failure 1 COMPATIBILITY_ROW_UNEXPECTED:Other_App '' \
  "$checker" "$unexpected_report"

header_like_report="$fixture_root/header-like.md"
/usr/bin/awk '
  { print }
  /^\| --- / && ! inserted {
    print "| Application | Bundle ID | Tested Version | Mouse Automatic Disabled | Mouse Allowed | Optional Keyboard | Shortcut Selection | Shortcut Clipboard | Manual Input | Bounds | Classification | Limitation |"
    inserted = 1
  }
' "$valid_report" > "$header_like_report"
expect_failure 1 COMPATIBILITY_TABLE_HEADER_COUNT '' \
  "$checker" "$header_like_report"

indented_unexpected_report="$fixture_root/indented-unexpected.md"
/usr/bin/awk '
  { print }
  /^\| --- / && ! inserted {
    print "  | Other App | invalid.example | 1 | Pass | Pass | Pass | Pass | Pass | Pass | Pass | Full | None |"
    inserted = 1
  }
' "$valid_report" > "$indented_unexpected_report"
expect_failure 1 COMPATIBILITY_ROW_UNEXPECTED:Other_App '' \
  "$checker" "$indented_unexpected_report"

incomplete_report="$fixture_root/incomplete.md"
/usr/bin/sed 's/151[.]0/TBD/' "$valid_report" > "$incomplete_report"
expect_failure 1 COMPATIBILITY_ROW_INCOMPLETE '' \
  "$checker" "$incomplete_report"

prose_incomplete_report="$fixture_root/prose-incomplete.md"
/bin/cp "$valid_report" "$prose_incomplete_report"
printf '%s\n' 'TODO: unfinished public compatibility prose.' \
  >> "$prose_incomplete_report"
expect_failure 1 COMPATIBILITY_ROW_INCOMPLETE '' \
  "$checker" "$prose_incomplete_report"

blank_report="$fixture_root/blank.md"
/usr/bin/sed 's/| 26[.]6 |/| |/' "$valid_report" > "$blank_report"
expect_failure 1 COMPATIBILITY_ROW_INCOMPLETE:Xcode '' "$checker" "$blank_report"

invalid_classification_report="$fixture_root/invalid-classification.md"
/usr/bin/sed 's/| Full | None |/| PASS | None |/' \
  "$valid_report" > "$invalid_classification_report"
expect_failure 1 COMPATIBILITY_CLASSIFICATION_INVALID:TextEdit '' \
  "$checker" "$invalid_classification_report"

missing_limitation_report="$fixture_root/missing-limitation.md"
/usr/bin/sed \
  's/| Manual-input | Selection paths require pending manual validation[.] |/| Manual-input | None |/' \
  "$valid_report" > "$missing_limitation_report"
expect_failure 1 COMPATIBILITY_LIMITATION_REQUIRED:Safari '' \
  "$checker" "$missing_limitation_report"

malformed_report="$fixture_root/malformed.md"
/usr/bin/sed 's/| None |$/| None | extra |/' "$valid_report" > "$malformed_report"
expect_failure 1 COMPATIBILITY_ROW_MALFORMED:TextEdit '' \
  "$checker" "$malformed_report"

missing_file="$fixture_root/not-present.md"
expect_failure 2 COMPATIBILITY_REPORT_INVALID '' "$checker" "$missing_file"

probe_bin="$fixture_root/probe-bin"
probe_tmp="$fixture_root/probe-tmp"
/bin/mkdir -p "$probe_bin" "$probe_tmp"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  'if [ "$#" -eq 1 ] && [ "$1" = -d ]; then' \
  '  exec /usr/bin/mktemp -d "${GT_COMPATIBILITY_PROBE_TMP:?}/compatibility.XXXXXX"' \
  'fi' \
  'exec /usr/bin/mktemp "$@"' \
  > "$probe_bin/mktemp"
/bin/chmod 755 "$probe_bin/mktemp"

env PATH="$probe_bin:$PATH" GT_COMPATIBILITY_PROBE_TMP="$probe_tmp" \
  "$checker" "$valid_report"
test -z "$(/usr/bin/find "$probe_tmp" -mindepth 1 -print -quit)"

expect_failure 2 COMPATIBILITY_REPORT_INVALID '' \
  env PATH="$probe_bin:$PATH" GT_COMPATIBILITY_PROBE_TMP="$probe_tmp" \
  "$checker" "$missing_file"
test -z "$(/usr/bin/find "$probe_tmp" -mindepth 1 -print -quit)"

awk_checker="$fixture_root/check-awk-failure.sh"
fake_awk="$fixture_root/private-awk-tool"
printf '%s\n' '#!/usr/bin/env bash' 'printf "%s\n" PRIVATE_AWK_FAILURE >&2' 'exit 23' \
  > "$fake_awk"
/bin/chmod 755 "$fake_awk"
/usr/bin/sed "s#/usr/bin/awk#$fake_awk#g" "$checker" > "$awk_checker"
/bin/chmod 755 "$awk_checker"
expect_failure 2 COMPATIBILITY_PARSE_FAILED PRIVATE_AWK_FAILURE \
  "$awk_checker" "$valid_report"

rg_checker="$fixture_root/check-rg-failure.sh"
fake_rg="$fixture_root/private-rg-tool"
printf '%s\n' '#!/usr/bin/env bash' 'printf "%s\n" PRIVATE_RG_FAILURE >&2' 'exit 23' \
  > "$fake_rg"
/bin/chmod 755 "$fake_rg"
/usr/bin/sed "s#LC_ALL=C rg #LC_ALL=C $fake_rg #g" "$checker" > "$rg_checker"
/bin/chmod 755 "$rg_checker"
expect_failure 2 COMPATIBILITY_SCAN_FAILED PRIVATE_RG_FAILURE \
  "$rg_checker" "$valid_report"

cleanup_checker="$fixture_root/check-cleanup-failure.sh"
/usr/bin/sed \
  's#/bin/rm -rf "$compatibility_root" >/dev/null 2>&1 || cleanup_status=$?#/usr/bin/false || cleanup_status=$?#' \
  "$checker" > "$cleanup_checker"
/bin/chmod 755 "$cleanup_checker"
expect_failure 2 COMPATIBILITY_CLEANUP_FAILED '' \
  env PATH="$probe_bin:$PATH" GT_COMPATIBILITY_PROBE_TMP="$probe_tmp" \
  "$cleanup_checker" "$valid_report"
test -n "$(/usr/bin/find "$probe_tmp" -mindepth 1 -print -quit)"
/bin/rm -rf "$probe_tmp"
/bin/mkdir -p "$probe_tmp"

for signal_row in INT:130 TERM:143 HUP:129; do
  signal_name="${signal_row%%:*}"
  expected_status="${signal_row##*:}"
  signal_checker="$fixture_root/check-signal-$signal_name.sh"
  /usr/bin/sed \
    "/^if ! \/usr\/bin\/awk/i\\
kill -$signal_name \"\$\$\"
" \
    "$checker" > "$signal_checker"
  /bin/chmod 755 "$signal_checker"
  signal_stdout="$fixture_root/signal-$signal_name.stdout"
  signal_stderr="$fixture_root/signal-$signal_name.stderr"
  signal_status=0
  env PATH="$probe_bin:$PATH" GT_COMPATIBILITY_PROBE_TMP="$probe_tmp" \
    "$signal_checker" "$valid_report" \
    > "$signal_stdout" 2> "$signal_stderr" || signal_status=$?
  if [ "$signal_status" -ne "$expected_status" ]; then
    printf 'COMPATIBILITY_SIGNAL_STATUS_UNEXPECTED:%s:%s\n' \
      "$signal_name" "$signal_status" >&2
    exit 1
  fi
  if [ -s "$signal_stdout" ] || [ -s "$signal_stderr" ]; then
    printf 'COMPATIBILITY_SIGNAL_DIAGNOSTIC_UNEXPECTED:%s\n' \
      "$signal_name" >&2
    exit 1
  fi
  test -z "$(/usr/bin/find "$probe_tmp" -mindepth 1 -print -quit)"
done

fixture_cleanup_enabled=1
printf '%s\n' COMPATIBILITY_REPORT_TESTS_PASS
