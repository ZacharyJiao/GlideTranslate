#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

workspace_root="$(cd "$(dirname "$0")/.." && pwd)"
fixture_parent="$(mktemp -d)"
fixture_cleanup_enabled=0

cleanup_fixture() {
  prior_status=$?
  trap - EXIT INT TERM HUP
  cleanup_status=0
  if [ "$fixture_cleanup_enabled" -eq 1 ]; then
    /bin/rm -rf "$fixture_parent" >/dev/null 2>&1 || cleanup_status=$?
  else
    printf '%s\n' CANDIDATE_TEST_EVIDENCE_RETAINED >&2
  fi
  if [ "$prior_status" -ne 0 ]; then exit "$prior_status"; fi
  exit "$cleanup_status"
}
retain_fixture_on_signal() {
  signal_status="$1"
  trap - EXIT INT TERM HUP
  printf '%s\n' CANDIDATE_TEST_EVIDENCE_RETAINED >&2
  exit "$signal_status"
}
trap cleanup_fixture EXIT
trap 'retain_fixture_on_signal 130' INT
trap 'retain_fixture_on_signal 143' TERM
trap 'retain_fixture_on_signal 129' HUP

synthetic="$fixture_parent/synthetic"
/bin/mkdir -p \
  "$synthetic/script" \
  "$synthetic/Sources" \
  "$synthetic/foo..bar" \
  "$synthetic/docs/superpowers" \
  "$synthetic/.codex" \
  "$synthetic/DerivedData" \
  "$synthetic/diagnostics" \
  "$synthetic/database" \
  "$synthetic/archive.xcarchive"
printf '%s\n' 'public synthetic source' > "$synthetic/Sources/Allowed.swift"
printf '%s\n' 'ordinary component' > "$synthetic/foo..bar/Allowed.txt"
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$synthetic/script/executable.sh"
printf '%s\n' 'non executable script fixture' > "$synthetic/script/plain.txt"
/bin/chmod 755 "$synthetic/script/executable.sh"
/bin/chmod 644 "$synthetic/script/plain.txt"
printf '%s\n' 'private plan' > "$synthetic/docs/superpowers/plan.md"
printf '%s\n' 'private agent state' > "$synthetic/.codex/state"
printf '%s\n' 'build state' > "$synthetic/DerivedData/state"
printf '%s\n' 'diagnostic state' > "$synthetic/diagnostics/report.txt"
printf '%s\n' 'database state' > "$synthetic/database/history.sqlite"
printf '%s\n' 'archive state' > "$synthetic/archive.xcarchive/state"
printf '%s\n' Sources foo..bar script > "$synthetic/script/public_paths.txt"

candidate="$fixture_parent/candidate"
(umask 077; "$workspace_root/script/create_candidate_snapshot.sh" "$candidate" "$synthetic")
test -f "$candidate/Sources/Allowed.swift"
test -f "$candidate/foo..bar/Allowed.txt"
test "$(/usr/bin/stat -f '%Lp' "$candidate")" = 755
test "$(/usr/bin/stat -f '%Lp' "$candidate/Sources")" = 755
test "$(/usr/bin/stat -f '%Lp' "$candidate/Sources/Allowed.swift")" = 644
test "$(/usr/bin/stat -f '%Lp' "$candidate/script/executable.sh")" = 755
test "$(/usr/bin/stat -f '%Lp' "$candidate/script/plain.txt")" = 644
for prohibited in docs/superpowers .codex DerivedData diagnostics database archive.xcarchive; do
  test ! -e "$candidate/$prohibited"
done
"$workspace_root/script/check_public_tree.sh" "$candidate"

if "$workspace_root/script/create_candidate_snapshot.sh" "$candidate" "$synthetic" \
  > "$fixture_parent/existing.stdout" 2> "$fixture_parent/existing.stderr"; then
  printf '%s\n' CANDIDATE_EXISTING_DESTINATION_ACCEPTED >&2
  exit 1
fi

assert_invalid_path() {
  fixture_name="$1"
  shift
  invalid_root="$fixture_parent/invalid-$fixture_name"
  invalid_destination="$fixture_parent/destination-$fixture_name"
  /bin/mkdir -p "$invalid_root/script" "$invalid_root/Sources/X"
  "$@" > "$invalid_root/script/public_paths.txt"
  invalid_status=0
  "$workspace_root/script/create_candidate_snapshot.sh" \
    "$invalid_destination" "$invalid_root" \
    > "$fixture_parent/$fixture_name.stdout" \
    2> "$fixture_parent/$fixture_name.stderr" || invalid_status=$?
  test "$invalid_status" -ne 0
  test "$(/bin/cat "$fixture_parent/$fixture_name.stderr")" = CANDIDATE_PATH_INVALID
  test ! -s "$fixture_parent/$fixture_name.stdout"
}

assert_invalid_path dot printf '%s\n' .
assert_invalid_path dot-prefix printf '%s\n' ./Sources
assert_invalid_path dot-component printf '%s\n' Sources/./X
assert_invalid_path parent printf '%s\n' ..
assert_invalid_path parent-prefix printf '%s\n' ../Sources
assert_invalid_path parent-component printf '%s\n' Sources/../Tests
assert_invalid_path repeated-separator printf '%s\n' Sources//X
assert_invalid_path trailing-separator printf '%s\n' Sources/
assert_invalid_path absolute printf '%s\n' /tmp/invalid-candidate-path
assert_invalid_path tab printf 'Sources\tX\n'
assert_invalid_path carriage-return printf 'Sources\rX\n'
assert_invalid_path vertical-tab printf 'Sources\vX\n'
assert_invalid_path form-feed printf 'Sources\fX\n'
assert_invalid_path escape printf 'Sources\033X\n'
assert_invalid_path newline-injection printf 'Sources\n../Injected\n'

symlink_root="$fixture_parent/symlink"
/bin/mkdir -p "$symlink_root/script" "$symlink_root/Sources"
printf '%s\n' 'safe' > "$symlink_root/source.txt"
/bin/ln -s "$symlink_root/source.txt" "$symlink_root/Sources/link"
printf '%s\n' Sources > "$symlink_root/script/public_paths.txt"
symlink_status=0
"$workspace_root/script/create_candidate_snapshot.sh" \
  "$fixture_parent/symlink-candidate" "$symlink_root" \
  > "$fixture_parent/symlink.stdout" 2> "$fixture_parent/symlink.stderr" \
  || symlink_status=$?
test "$symlink_status" -ne 0
test "$(/bin/cat "$fixture_parent/symlink.stderr")" = CANDIDATE_SYMLINK:Sources

enumeration_failure_creator="$fixture_parent/create_candidate_snapshot-enumeration-failure.sh"
/usr/bin/sed \
  's#/usr/bin/find "$source_path" -type f -print0 > "$mode_inventory"#/bin/sh -c '\''exit 23'\'' > "$mode_inventory"#' \
  "$workspace_root/script/create_candidate_snapshot.sh" \
  > "$enumeration_failure_creator"
/bin/chmod 755 "$enumeration_failure_creator"
rg -q "/bin/sh -c 'exit 23'" "$enumeration_failure_creator"
enumeration_failure_status=0
"$enumeration_failure_creator" \
  "$fixture_parent/enumeration-failure-candidate" "$synthetic" \
  > "$fixture_parent/enumeration-failure.stdout" \
  2> "$fixture_parent/enumeration-failure.stderr" \
  || enumeration_failure_status=$?
test "$enumeration_failure_status" -eq 2
test "$([ -s "$fixture_parent/enumeration-failure.stderr" ] && \
  /bin/cat "$fixture_parent/enumeration-failure.stderr")" = CANDIDATE_ENUMERATION_FAILED
test ! -s "$fixture_parent/enumeration-failure.stdout"

probe_source="$fixture_parent/aggregate-source"
probe_bin="$fixture_parent/aggregate-bin"
probe_launcher="$fixture_parent/aggregate-launcher"
probe_tmp="$fixture_parent/aggregate-tmp"
/bin/mkdir -p \
  "$probe_source/script" \
  "$probe_source/.github/workflows" \
  "$probe_source/GlideTranslate.xcodeproj" \
  "$probe_bin" "$probe_launcher" "$probe_tmp"
/bin/cp "$workspace_root/script/create_candidate_snapshot.sh" \
  "$probe_source/script/create_candidate_snapshot.real.sh"
/bin/chmod 755 "$probe_source/script/create_candidate_snapshot.real.sh"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  'script_dir="$(cd "$(dirname "$0")" && pwd)"' \
  '"$script_dir/create_candidate_snapshot.real.sh" "$@"' \
  'if [ -n "${GT_PROBE_SIGNAL_CREATE:-}" ]; then kill -"$GT_PROBE_SIGNAL_CREATE" "$PPID"; fi' \
  > "$probe_source/script/create_candidate_snapshot.sh"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  'if [ -n "${GT_PROBE_BODY_SENTINEL:-}" ]; then printf "%s\n" reached > "$GT_PROBE_BODY_SENTINEL"; fi' \
  > "$probe_source/script/check_public_tree.sh"
for probe_script in \
  check_workflow_pins.sh \
  check_localizations.sh \
  test_compatibility_report.sh \
  check_compatibility_report.sh \
  test_local_ollama_preflight.sh \
  test_release_payload_inspection.sh \
  test_summarize_xcode_unit_failure.sh \
  test_adhoc_release_packaging.sh \
  test_audit_release_payload.sh \
  test_download_bounded_asset.sh \
  test_safe_extract_asset.sh \
  test_external_surfaces.sh; do
  printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail' \
    > "$probe_source/script/$probe_script"
done
/bin/chmod 755 "$probe_source/script/"*.sh
printf '%s\n' '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  ': > "$GT_PROBE_TMP_ROOT/xcode-summary-test"' \
  > "$probe_source/script/test_summarize_xcode_unit_failure.sh"
/bin/chmod 755 "$probe_source/script/test_summarize_xcode_unit_failure.sh"
printf '%s\n' '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  ': > "$GT_PROBE_TMP_ROOT/release-audit-test"' \
  > "$probe_source/script/test_audit_release_payload.sh"
/bin/chmod 755 "$probe_source/script/test_audit_release_payload.sh"
printf '%s\n' \
  .github/workflows/ci.yml GlideTranslate.xcodeproj Package.swift script \
  > "$probe_source/script/public_paths.txt"
printf '%s\n' '// aggregate probe package' > "$probe_source/Package.swift"
printf '%s\n' 'name: aggregate-probe' > "$probe_source/.github/workflows/ci.yml"
printf '%s\n' '// aggregate probe project' \
  > "$probe_source/GlideTranslate.xcodeproj/project.pbxproj"

printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$probe_bin/actionlint"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'if [ "$#" -eq 1 ] && [ "$1" = -d ]; then' \
  '  exec /usr/bin/mktemp -d "${GT_PROBE_TMP_ROOT:?}/tmp.XXXXXX"' \
  'fi' \
  'exec /usr/bin/mktemp "$@"' \
  > "$probe_bin/mktemp"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'if [ -n "${GT_PROBE_SWIFT_STATUS:-}" ]; then exit "$GT_PROBE_SWIFT_STATUS"; fi' \
  'exit 0' \
  > "$probe_bin/swift"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  'project=""' \
  'configuration=""' \
  'arguments="$*"' \
  'while [ "$#" -gt 0 ]; do' \
  '  case "$1" in' \
  '    -project) project="$2"; shift 2 ;;' \
  '    -configuration) configuration="$2"; shift 2 ;;' \
  '    *) shift ;;' \
  '  esac' \
  'done' \
  'if [ "$configuration" = Debug ]; then' \
  '  case " $arguments " in' \
  '    *" -only-testing:GlideTranslateTests "*) : > "$GT_PROBE_TMP_ROOT/xcode-unit"; if [ -n "${GT_PROBE_XCODE_UNIT_STATUS:-}" ]; then exit "$GT_PROBE_XCODE_UNIT_STATUS"; fi ;;' \
  '    *" -only-testing:GlideTranslateUITests "*) : > "$GT_PROBE_TMP_ROOT/xcode-ui"; if [ -n "${GT_PROBE_XCODE_UI_STATUS:-}" ]; then exit "$GT_PROBE_XCODE_UI_STATUS"; fi ;;' \
  '    *) exit 91 ;;' \
  '  esac' \
  'fi' \
  'if [ "${GT_PROBE_CLEANUP_FAILURE:-0}" -eq 1 ] && [ "$configuration" = Release ]; then' \
  '  candidate_root="${project%/GlideTranslate.xcodeproj}"' \
  '  printf "%s\n" blocked > "$candidate_root/cleanup-blocker"' \
  '  /usr/bin/chflags uchg "$candidate_root/cleanup-blocker"' \
  'fi' \
  'exit 0' \
  > "$probe_bin/xcodebuild"
/bin/chmod 755 "$probe_bin/"*

run_aggregate_probe() {
  probe_name="$1"
  shift
  /bin/rm -rf "$probe_tmp"
  /bin/mkdir -p "$probe_tmp"
  (
    cd "$probe_launcher"
    env \
      PATH="$probe_bin:$PATH" \
      TMPDIR="$probe_tmp/" \
      GT_PROBE_TMP_ROOT="$probe_tmp" \
      GT_AGGREGATE_STAGE_FILE="$fixture_parent/$probe_name.stage" \
      GT_CANDIDATE_SOURCE_ROOT="$probe_source" \
      DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
      "$@" \
      "$workspace_root/script/test_all.sh"
  ) > "$fixture_parent/$probe_name.stdout" \
    2> "$fixture_parent/$probe_name.stderr"
}

run_aggregate_probe aggregate-success
test "$(/bin/cat "$fixture_parent/aggregate-success.stage")" = COMPLETE
test -f "$probe_tmp/xcode-unit"
test -f "$probe_tmp/xcode-ui"
test -f "$probe_tmp/xcode-summary-test"
test -f "$probe_tmp/release-audit-test"
/bin/rm -f "$probe_tmp/xcode-unit" "$probe_tmp/xcode-ui" "$probe_tmp/xcode-summary-test" "$probe_tmp/release-audit-test"
test -z "$(/usr/bin/find "$probe_tmp" -mindepth 1 -print -quit)"

xcode_unit_status=0
run_aggregate_probe aggregate-xcode-unit-failure \
  GT_PROBE_XCODE_UNIT_STATUS=23 || xcode_unit_status=$?
test "$xcode_unit_status" -eq 23
test "$(/bin/cat "$fixture_parent/aggregate-xcode-unit-failure.stage")" = XCODE_UNIT_TESTS
test -f "$probe_tmp/xcode-unit"
test ! -e "$probe_tmp/xcode-ui"
/bin/rm -f "$probe_tmp/xcode-unit" "$probe_tmp/xcode-summary-test" "$probe_tmp/release-audit-test"
test -z "$(/usr/bin/find "$probe_tmp" -mindepth 1 -print -quit)"

xcode_ui_status=0
run_aggregate_probe aggregate-xcode-ui-failure \
  GT_PROBE_XCODE_UI_STATUS=29 || xcode_ui_status=$?
test "$xcode_ui_status" -eq 29
test "$(/bin/cat "$fixture_parent/aggregate-xcode-ui-failure.stage")" = XCODE_UI_TESTS
test -f "$probe_tmp/xcode-unit"
test -f "$probe_tmp/xcode-ui"
/bin/rm -f "$probe_tmp/xcode-unit" "$probe_tmp/xcode-ui" "$probe_tmp/xcode-summary-test" "$probe_tmp/release-audit-test"
test -z "$(/usr/bin/find "$probe_tmp" -mindepth 1 -print -quit)"

body_status=0
run_aggregate_probe aggregate-body-failure \
  GT_PROBE_SWIFT_STATUS=23 || body_status=$?
test "$body_status" -eq 23
/bin/rm -f "$probe_tmp/release-audit-test"
test -z "$(/usr/bin/find "$probe_tmp" -mindepth 1 -print -quit)"

cleanup_status=0
run_aggregate_probe aggregate-cleanup-failure \
  GT_PROBE_CLEANUP_FAILURE=1 || cleanup_status=$?
test "$cleanup_status" -ne 0
rg -q '^CANDIDATE_CLEANUP_FAILED$' \
  "$fixture_parent/aggregate-cleanup-failure.stderr"
/usr/bin/chflags -R nouchg "$probe_tmp" 2>/dev/null || true
/bin/rm -rf "$probe_tmp"
/bin/mkdir -p "$probe_tmp"

for signal_row in INT:130 TERM:143 HUP:129; do
  signal_name="${signal_row%%:*}"
  expected_status="${signal_row##*:}"
  signal_sentinel="$fixture_parent/aggregate-$signal_name-sentinel"
  signal_status=0
  run_aggregate_probe "aggregate-signal-$signal_name" \
    GT_PROBE_SIGNAL_CREATE="$signal_name" \
    GT_PROBE_BODY_SENTINEL="$signal_sentinel" || signal_status=$?
  test "$signal_status" -eq "$expected_status"
  test ! -e "$signal_sentinel"
  test -z "$(/usr/bin/find "$probe_tmp" -mindepth 1 -print -quit)"
done

outer_owner="$probe_source/script/run_outer_candidate.sh"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  'source_root="${GT_PROBE_OUTER_SOURCE:?}"' \
  'candidate_parent="$(mktemp -d)"' \
  'candidate_root="$candidate_parent/candidate"' \
  'candidate_parent_cleanup=0' \
  'cleanup_candidate_parent_on_exit() {' \
  '  prior_status=$?' \
  '  trap - EXIT INT TERM HUP' \
  '  cleanup_status=0' \
  '  if [ "$candidate_parent_cleanup" -eq 1 ]; then' \
  '    /bin/rm -rf "$candidate_parent" >/dev/null 2>&1 || cleanup_status=$?' \
  '  else' \
  '    printf "%s\n" CANDIDATE_EVIDENCE_RETAINED_LOCALLY >&2' \
  '  fi' \
  '  if [ "$prior_status" -ne 0 ]; then exit "$prior_status"; fi' \
  '  exit "$cleanup_status"' \
  '}' \
  'cleanup_candidate_parent_on_signal() {' \
  '  signal_status="$1"' \
  '  trap - EXIT INT TERM HUP' \
  '  printf "%s\n" CANDIDATE_EVIDENCE_RETAINED_LOCALLY >&2' \
  '  exit "$signal_status"' \
  '}' \
  'trap cleanup_candidate_parent_on_exit EXIT' \
  "trap 'cleanup_candidate_parent_on_signal 130' INT" \
  "trap 'cleanup_candidate_parent_on_signal 143' TERM" \
  "trap 'cleanup_candidate_parent_on_signal 129' HUP" \
  '"$source_root/script/create_candidate_snapshot.sh" "$candidate_root" "$source_root"' \
  'if [ -n "${GT_PROBE_BODY_SENTINEL:-}" ]; then printf "%s\n" reached > "$GT_PROBE_BODY_SENTINEL"; fi' \
  'if [ "${GT_PROBE_OUTER_CLEANUP_FAILURE:-0}" -eq 1 ]; then' \
  '  printf "%s\n" blocked > "$candidate_parent/cleanup-blocker"' \
  '  /usr/bin/chflags uchg "$candidate_parent/cleanup-blocker"' \
  'fi' \
  'if [ -n "${GT_PROBE_OUTER_BODY_STATUS:-}" ]; then exit "$GT_PROBE_OUTER_BODY_STATUS"; fi' \
  'candidate_parent_cleanup=1' \
  > "$outer_owner"
/bin/chmod 755 "$outer_owner"

run_outer_probe() {
  outer_name="$1"
  shift
  /bin/rm -rf "$probe_tmp"
  /bin/mkdir -p "$probe_tmp"
  env \
    PATH="$probe_bin:$PATH" \
    TMPDIR="$probe_tmp/" \
    GT_PROBE_TMP_ROOT="$probe_tmp" \
    GT_PROBE_OUTER_SOURCE="$probe_source" \
    "$@" \
    "$outer_owner" \
    > "$fixture_parent/$outer_name.stdout" \
    2> "$fixture_parent/$outer_name.stderr"
}

run_outer_probe outer-success
test -z "$(/usr/bin/find "$probe_tmp" -mindepth 1 -print -quit)"

outer_body_status=0
run_outer_probe outer-body-failure \
  GT_PROBE_OUTER_BODY_STATUS=23 || outer_body_status=$?
test "$outer_body_status" -eq 23
rg -q '^CANDIDATE_EVIDENCE_RETAINED_LOCALLY$' \
  "$fixture_parent/outer-body-failure.stderr"
test -n "$(/usr/bin/find "$probe_tmp" -mindepth 1 -print -quit)"
/bin/rm -rf "$probe_tmp"
/bin/mkdir -p "$probe_tmp"

outer_cleanup_status=0
run_outer_probe outer-cleanup-failure \
  GT_PROBE_OUTER_CLEANUP_FAILURE=1 || outer_cleanup_status=$?
test "$outer_cleanup_status" -ne 0
test -n "$(/usr/bin/find "$probe_tmp" -mindepth 1 -print -quit)"
/usr/bin/chflags -R nouchg "$probe_tmp" 2>/dev/null || true
/bin/rm -rf "$probe_tmp"
/bin/mkdir -p "$probe_tmp"

for signal_row in INT:130 TERM:143 HUP:129; do
  signal_name="${signal_row%%:*}"
  expected_status="${signal_row##*:}"
  signal_sentinel="$fixture_parent/outer-$signal_name-sentinel"
  outer_signal_status=0
  run_outer_probe "outer-signal-$signal_name" \
    GT_PROBE_SIGNAL_CREATE="$signal_name" \
    GT_PROBE_BODY_SENTINEL="$signal_sentinel" || outer_signal_status=$?
  test "$outer_signal_status" -eq "$expected_status"
  test ! -e "$signal_sentinel"
  rg -q '^CANDIDATE_EVIDENCE_RETAINED_LOCALLY$' \
    "$fixture_parent/outer-signal-$signal_name.stderr"
  test -n "$(/usr/bin/find "$probe_tmp" -mindepth 1 -print -quit)"
  /bin/rm -rf "$probe_tmp"
  /bin/mkdir -p "$probe_tmp"
done

fixture_cleanup_enabled=1
printf '%s\n' CANDIDATE_SNAPSHOT_TEST_PASS
