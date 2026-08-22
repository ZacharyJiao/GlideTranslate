#!/usr/bin/env bash
set -euo pipefail

developer_dir="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
owned_candidate_parent=""
candidate_cleanup_enabled=0

record_stage() {
  if [ -n "${GT_AGGREGATE_STAGE_FILE:-}" ]; then
    printf '%s\n' "$1" > "$GT_AGGREGATE_STAGE_FILE"
  fi
}

cleanup_candidate() {
  if [ "$candidate_cleanup_enabled" -eq 1 ] && \
     [ -n "$owned_candidate_parent" ]; then
    /bin/rm -rf "$owned_candidate_parent" >/dev/null 2>&1 || {
      printf '%s\n' CANDIDATE_CLEANUP_FAILED >&2
      return 1
    }
  fi
}

cleanup_candidate_on_exit() {
  prior_status=$?
  trap - EXIT INT TERM HUP
  cleanup_status=0
  cleanup_candidate || cleanup_status=$?
  if [ "$prior_status" -ne 0 ]; then exit "$prior_status"; fi
  exit "$cleanup_status"
}

cleanup_candidate_on_signal() {
  signal_status="$1"
  trap - EXIT INT TERM HUP
  cleanup_candidate || true
  exit "$signal_status"
}

trap cleanup_candidate_on_exit EXIT
trap 'cleanup_candidate_on_signal 130' INT
trap 'cleanup_candidate_on_signal 143' TERM
trap 'cleanup_candidate_on_signal 129' HUP

if [ -n "${GT_CANDIDATE_ROOT:-}" ]; then
  candidate_root="$GT_CANDIDATE_ROOT"
else
  source_root="${GT_CANDIDATE_SOURCE_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
  owned_candidate_parent="$(mktemp -d)"
  candidate_root="$owned_candidate_parent/candidate"
  candidate_cleanup_enabled=1
  "$source_root/script/create_candidate_snapshot.sh" \
    "$candidate_root" "$source_root"
fi

record_stage PUBLIC_TREE
"$candidate_root/script/check_public_tree.sh" "$candidate_root"
record_stage WORKFLOW_PINS
"$candidate_root/script/check_workflow_pins.sh" "$candidate_root"
record_stage LOCALIZATIONS
"$candidate_root/script/check_localizations.sh" "$candidate_root"
record_stage COMPATIBILITY_REPORT_TESTS
"$candidate_root/script/test_compatibility_report.sh"
record_stage COMPATIBILITY_REPORT
"$candidate_root/script/check_compatibility_report.sh" \
  "$candidate_root/docs/compatibility.md"
record_stage LOCAL_OLLAMA_PREFLIGHT_TESTS
"$candidate_root/script/test_local_ollama_preflight.sh"
record_stage RELEASE_PAYLOAD_INSPECTION_TESTS
"$candidate_root/script/test_release_payload_inspection.sh"
record_stage ADHOC_RELEASE_PACKAGING_TESTS
"$candidate_root/script/test_adhoc_release_packaging.sh"
record_stage RELEASE_PAYLOAD_AUDIT_TESTS
"$candidate_root/script/test_audit_release_payload.sh"
record_stage BOUNDED_DOWNLOAD_TESTS
"$candidate_root/script/test_download_bounded_asset.sh"
record_stage SAFE_EXTRACTION_TESTS
"$candidate_root/script/test_safe_extract_asset.sh"
record_stage EXTERNAL_SURFACE_TESTS
"$candidate_root/script/test_external_surfaces.sh"
record_stage ACTIONLINT
actionlint "$candidate_root/.github/workflows/ci.yml"
record_stage SWIFTPM_TESTS
DEVELOPER_DIR="$developer_dir" swift test --package-path "$candidate_root"
record_stage XCODE_UNIT_FAILURE_SUMMARY_TESTS
"$candidate_root/script/test_summarize_xcode_unit_failure.sh"
xcode_unit_command_args=(
  -project "$candidate_root/GlideTranslate.xcodeproj"
  -scheme GlideTranslate
  -configuration Debug
  -destination 'platform=macOS'
  -only-testing:GlideTranslateTests
)
if [ -n "${GT_XCODE_UNIT_RESULT_BUNDLE:-}" ]; then
  xcode_unit_command_args+=(-resultBundlePath "$GT_XCODE_UNIT_RESULT_BUNDLE")
fi
record_stage XCODE_UNIT_TESTS
DEVELOPER_DIR="$developer_dir" xcodebuild \
  "${xcode_unit_command_args[@]}" \
  CODE_SIGNING_ALLOWED=NO \
  SWIFT_SUPPRESS_WARNINGS=NO \
  SWIFT_TREAT_WARNINGS_AS_ERRORS=YES \
  GCC_TREAT_WARNINGS_AS_ERRORS=YES \
  test
record_stage XCODE_UI_TESTS
DEVELOPER_DIR="$developer_dir" xcodebuild \
  -project "$candidate_root/GlideTranslate.xcodeproj" \
  -scheme GlideTranslate \
  -configuration Debug \
  -destination 'platform=macOS' \
  -only-testing:GlideTranslateUITests \
  CODE_SIGNING_ALLOWED=NO \
  SWIFT_SUPPRESS_WARNINGS=NO \
  SWIFT_TREAT_WARNINGS_AS_ERRORS=YES \
  GCC_TREAT_WARNINGS_AS_ERRORS=YES \
  test
record_stage XCODE_RELEASE_BUILD
DEVELOPER_DIR="$developer_dir" xcodebuild \
  -project "$candidate_root/GlideTranslate.xcodeproj" \
  -scheme GlideTranslate \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  SWIFT_SUPPRESS_WARNINGS=NO \
  SWIFT_TREAT_WARNINGS_AS_ERRORS=YES \
  GCC_TREAT_WARNINGS_AS_ERRORS=YES \
  build
record_stage COMPLETE
