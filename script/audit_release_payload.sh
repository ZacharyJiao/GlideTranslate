#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

extracted_root="${1:?extracted payload root required}"
inspection_root="${2:?inspection root required}"
workspace_root="$(cd "$(dirname "$0")/.." && pwd)"
approved_bundle_id=com.zaryolabs.GlideTranslate
surface_checker="${RELEASE_SURFACE_CHECKER:-$workspace_root/script/check_external_surfaces.sh}"
gitleaks_bin="${RELEASE_GITLEAKS_BIN:-gitleaks}"
payload_inspector="${RELEASE_PAYLOAD_INSPECTOR:-$workspace_root/script/inspect_release_payload.sh}"
rm_bin="${RELEASE_AUDIT_RM_BIN:-/bin/rm}"

test -d "$extracted_root" || {
  printf '%s\n' RELEASE_PAYLOAD_AUDIT_INPUT_INVALID >&2
  exit 1
}
test ! -L "$extracted_root" || {
  printf '%s\n' RELEASE_PAYLOAD_AUDIT_INPUT_INVALID >&2
  exit 1
}
test ! -e "$inspection_root" || {
  printf '%s\n' RELEASE_PAYLOAD_AUDIT_OUTPUT_EXISTS >&2
  exit 1
}
test ! -L "$inspection_root" || {
  printf '%s\n' RELEASE_PAYLOAD_AUDIT_OUTPUT_EXISTS >&2
  exit 1
}

private_root="$(mktemp -d 2>/dev/null || true)"
test -n "$private_root" || {
  printf '%s\n' RELEASE_PAYLOAD_AUDIT_UNVERIFIABLE >&2
  exit 2
}
inspection_created=0
cleanup() {
  prior_status=$?
  trap - EXIT INT TERM HUP
  cleanup_status=0
  "$rm_bin" -rf "$private_root" >/dev/null 2>&1 || cleanup_status=$?
  if [ "$inspection_created" -eq 1 ]; then
    "$rm_bin" -rf "$inspection_root" >/dev/null 2>&1 || cleanup_status=$?
  fi
  if [ -e "$private_root" ]; then
    "$rm_bin" -rf "$private_root" >/dev/null 2>&1 || cleanup_status=$?
  fi
  if [ "$inspection_created" -eq 1 ] && [ -e "$inspection_root" ]; then
    "$rm_bin" -rf "$inspection_root" >/dev/null 2>&1 || cleanup_status=$?
  fi
  if [ "$prior_status" -ne 0 ]; then exit "$prior_status"; fi
  if [ "$cleanup_status" -ne 0 ]; then
    printf '%s\n' RELEASE_PAYLOAD_AUDIT_CLEANUP_FAILED >&2
    exit 2
  fi
  exit 0
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

surface_status=0
"$surface_checker" --release-payload "$extracted_root" \
  > "$private_root/surface.stdout" 2> "$private_root/surface.stderr" || surface_status=$?
if [ "$surface_status" -ne 0 ]; then
  printf '%s\n' RELEASE_PAYLOAD_AUDIT_FAILED:EXTERNAL_SURFACE >&2
  exit 1
fi

gitleaks_status=0
"$gitleaks_bin" detect --source "$extracted_root" --no-banner --redact \
  > "$private_root/gitleaks.stdout" 2> "$private_root/gitleaks.stderr" || gitleaks_status=$?
if [ "$gitleaks_status" -ne 0 ]; then
  printf '%s\n' RELEASE_PAYLOAD_AUDIT_FAILED:GITLEAKS >&2
  exit 1
fi

inspection_status=0
GT_APPROVED_BUNDLE_ID="$approved_bundle_id" \
  "$payload_inspector" "$extracted_root" "$inspection_root" \
  > "$private_root/inspection.stdout" 2> "$private_root/inspection.stderr" || inspection_status=$?
inspection_created=1
if [ "$inspection_status" -ne 0 ]; then
  printf '%s\n' RELEASE_PAYLOAD_AUDIT_FAILED:PAYLOAD_INSPECTION >&2
  exit 1
fi

if "$rm_bin" -rf "$private_root" >/dev/null 2>&1 && \
   "$rm_bin" -rf "$inspection_root" >/dev/null 2>&1; then
  trap - EXIT INT TERM HUP
  printf '%s\n' RELEASE_PAYLOAD_AUDIT_PASSED
  exit 0
fi
printf '%s\n' RELEASE_PAYLOAD_AUDIT_CLEANUP_FAILED >&2
exit 2
