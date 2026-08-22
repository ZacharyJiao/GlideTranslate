#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

workspace_root="$(cd "$(dirname "$0")/.." && pwd)"
auditor="$workspace_root/script/audit_release_payload.sh"
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

extracted="$fixture_root/extracted"
/bin/mkdir -p "$extracted"
surface_tool="$fixture_root/surface"
printf '%s\n' '#!/usr/bin/env bash' \
  'test "$1" = --release-payload' \
  ': > "${GT_AUDIT_SURFACE_MARKER:?}"' \
  'exit "${GT_AUDIT_SURFACE_STATUS:-0}"' > "$surface_tool"
/bin/chmod 755 "$surface_tool"
gitleaks_tool="$fixture_root/gitleaks"
printf '%s\n' '#!/usr/bin/env bash' \
  ': > "${GT_AUDIT_GITLEAKS_MARKER:?}"' \
  'exit "${GT_AUDIT_GITLEAKS_STATUS:-0}"' > "$gitleaks_tool"
/bin/chmod 755 "$gitleaks_tool"
inspector_tool="$fixture_root/inspector"
printf '%s\n' '#!/usr/bin/env bash' \
  'test "$GT_APPROVED_BUNDLE_ID" = com.zaryolabs.GlideTranslate' \
  'mkdir "$2"' \
  ': > "${GT_AUDIT_INSPECTOR_MARKER:?}"' \
  'exit "${GT_AUDIT_INSPECTOR_STATUS:-0}"' > "$inspector_tool"
/bin/chmod 755 "$inspector_tool"

run_audit() {
  name="$1"
  output_root="$fixture_root/$name-inspection"
  output="$fixture_root/$name.stdout"
  error="$fixture_root/$name.stderr"
  status=0
  RELEASE_SURFACE_CHECKER="$surface_tool" \
    RELEASE_GITLEAKS_BIN="$gitleaks_tool" \
    RELEASE_PAYLOAD_INSPECTOR="$inspector_tool" \
    GT_AUDIT_SURFACE_MARKER="$fixture_root/$name.surface" \
    GT_AUDIT_GITLEAKS_MARKER="$fixture_root/$name.gitleaks" \
    GT_AUDIT_INSPECTOR_MARKER="$fixture_root/$name.inspector" \
    "$auditor" "$extracted" "$output_root" > "$output" 2> "$error" || status=$?
  printf '%s\n' "$status"
}

success_status="$(run_audit success)"
test "$success_status" -eq 0
test "$(/bin/cat "$fixture_root/success.stdout")" = RELEASE_PAYLOAD_AUDIT_PASSED
test ! -s "$fixture_root/success.stderr"
test -f "$fixture_root/success.surface"
test -f "$fixture_root/success.gitleaks"
test -f "$fixture_root/success.inspector"
test ! -e "$fixture_root/success-inspection"

for failure in surface gitleaks inspector; do
  case "$failure" in
    surface) export GT_AUDIT_SURFACE_STATUS=7; expected=RELEASE_PAYLOAD_AUDIT_FAILED:EXTERNAL_SURFACE ;;
    gitleaks) export GT_AUDIT_GITLEAKS_STATUS=7; expected=RELEASE_PAYLOAD_AUDIT_FAILED:GITLEAKS ;;
    inspector) export GT_AUDIT_INSPECTOR_STATUS=7; expected=RELEASE_PAYLOAD_AUDIT_FAILED:PAYLOAD_INSPECTION ;;
  esac
  status="$(run_audit "$failure")"
  test "$status" -ne 0
  test "$(/bin/cat "$fixture_root/$failure.stderr")" = "$expected"
  test ! -s "$fixture_root/$failure.stdout"
  test ! -e "$fixture_root/$failure-inspection"
  unset GT_AUDIT_SURFACE_STATUS GT_AUDIT_GITLEAKS_STATUS GT_AUDIT_INSPECTOR_STATUS
done

rm_state="$fixture_root/rm-state"
rm_target="$fixture_root/rm-target"
fail_once_rm="$fixture_root/fail-once-rm"
printf '%s\n' '#!/usr/bin/env bash' \
  'if [ "$1" = -rf ] && [ ! -e "${GT_RM_STATE_FILE:?}" ]; then' \
  '  : > "$GT_RM_STATE_FILE"' \
  '  printf "%s\n" "$2" > "${GT_RM_TARGET_FILE:?}"' \
  '  exit 23' \
  'fi' \
  'exec /bin/rm "$@"' > "$fail_once_rm"
/bin/chmod 755 "$fail_once_rm"
cleanup_status=0
cleanup_output="$fixture_root/cleanup.stdout"
RELEASE_SURFACE_CHECKER="$surface_tool" \
  RELEASE_GITLEAKS_BIN="$gitleaks_tool" \
  RELEASE_PAYLOAD_INSPECTOR="$inspector_tool" \
  GT_AUDIT_SURFACE_MARKER="$fixture_root/cleanup.surface" \
  GT_AUDIT_GITLEAKS_MARKER="$fixture_root/cleanup.gitleaks" \
  GT_AUDIT_INSPECTOR_MARKER="$fixture_root/cleanup.inspector" \
  GT_RM_STATE_FILE="$rm_state" GT_RM_TARGET_FILE="$rm_target" \
  RELEASE_AUDIT_RM_BIN="$fail_once_rm" "$auditor" "$extracted" \
  "$fixture_root/cleanup-inspection" >"$cleanup_output" 2>"$fixture_root/cleanup.stderr" \
  || cleanup_status=$?
test "$cleanup_status" -ne 0
test ! -s "$cleanup_output"
test ! -e "$(/bin/cat "$rm_target")"
test "$(/bin/cat "$fixture_root/cleanup.stderr")" = RELEASE_PAYLOAD_AUDIT_CLEANUP_FAILED

printf '%s\n' AUDIT_RELEASE_PAYLOAD_TESTS_PASS
