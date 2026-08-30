#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

workspace_root="$(cd "$(dirname "$0")/.." && pwd)"
archive="${1:?release archive required}"
output_root="${2:?new output root required}"
expected_version=0.2.0
expected_build=1
artifact_name=GlideTranslate-0.2.0-macos-arm64.zip
checksum_name="$artifact_name.sha256"
approved_bundle_id=com.zaryolabs.GlideTranslate
inspector="$workspace_root/script/inspect_release_payload.sh"
entitlements="$workspace_root/App/GlideTranslate/GlideTranslate.entitlements"

write_tree_manifest() {
  manifest_root="$1"
  manifest_output="$2"
  manifest_paths="$3"
  manifest_unsorted="$4"
  if ! /usr/bin/find "$manifest_root" -mindepth 1 -print0 \
      > "$manifest_paths" 2>> "$private_root/manifest.private"; then
    return 1
  fi
  : > "$manifest_unsorted"
  if ! root_mode="$(/usr/bin/stat -f '%Lp' "$manifest_root" \
      2>> "$private_root/manifest.private")"; then
    return 1
  fi
  case "$root_mode" in
    ''|*[!0-7]*) return 1 ;;
  esac
  printf '%s\t%s\t%s\t%s\n' . directory "$root_mode" - \
    >> "$manifest_unsorted"
  while IFS= read -r -d '' manifest_path; do
    relative_path="${manifest_path#"$manifest_root"/}"
    case "$relative_path" in
      *[[:cntrl:]]*) return 1 ;;
    esac
    if [ -f "$manifest_path" ]; then
      entry_type=file
      entry_hash="$(/usr/bin/shasum -a 256 "$manifest_path" \
        2>> "$private_root/manifest.private" | /usr/bin/awk '{print $1}')" \
        || return 1
      case "$entry_hash" in
        ''|*[!0-9a-f]*) return 1 ;;
      esac
      [ "${#entry_hash}" -eq 64 ] || return 1
    elif [ -d "$manifest_path" ]; then
      entry_type=directory
      entry_hash=-
    else
      return 1
    fi
    entry_mode="$(/usr/bin/stat -f '%Lp' "$manifest_path" \
      2>> "$private_root/manifest.private")" || return 1
    case "$entry_mode" in
      ''|*[!0-7]*) return 1 ;;
    esac
    printf '%s\t%s\t%s\t%s\n' \
      "$relative_path" "$entry_type" "$entry_mode" "$entry_hash" \
      >> "$manifest_unsorted"
  done < "$manifest_paths"
  LC_ALL=C /usr/bin/sort "$manifest_unsorted" > "$manifest_output" \
    2>> "$private_root/manifest.private"
}

test -d "$archive" || {
  printf '%s\n' RELEASE_ARCHIVE_INVALID >&2
  exit 1
}
test ! -e "$output_root" || {
  printf '%s\n' RELEASE_OUTPUT_EXISTS >&2
  exit 1
}
test -x "$inspector" && test -f "$entitlements" || {
  printf '%s\n' RELEASE_INPUT_MISSING >&2
  exit 1
}

app="$archive/Products/Applications/GlideTranslate.app"
main_binary="$app/Contents/MacOS/GlideTranslate"
test -d "$app" && test -f "$main_binary" || {
  printf '%s\n' RELEASE_ARCHIVE_LAYOUT_INVALID >&2
  exit 1
}

private_root="$(mktemp -d)"
output_created=0
release_success=0
cleanup() {
  prior_status=$?
  trap - EXIT INT TERM HUP
  cleanup_status=0
  /bin/rm -rf "$private_root" >/dev/null 2>&1 || cleanup_status=1
  if [ "$release_success" -ne 1 ] && [ "$output_created" -eq 1 ]; then
    /bin/rm -rf "$output_root" >/dev/null 2>&1 || cleanup_status=1
  fi
  if [ "$prior_status" -ne 0 ]; then exit "$prior_status"; fi
  if [ "$cleanup_status" -ne 0 ]; then
    printf '%s\n' RELEASE_CLEANUP_FAILED >&2
    exit 2
  fi
  exit 0
}
cleanup_signal() {
  signal_status="$1"
  trap - EXIT INT TERM HUP
  /bin/rm -rf "$private_root" >/dev/null 2>&1 || true
  if [ "$output_created" -eq 1 ]; then
    /bin/rm -rf "$output_root" >/dev/null 2>&1 || true
  fi
  exit "$signal_status"
}
trap cleanup EXIT
trap 'cleanup_signal 130' INT
trap 'cleanup_signal 143' TERM
trap 'cleanup_signal 129' HUP

unsigned_inspection="$private_root/unsigned-inspection"
if ! GT_APPROVED_BUNDLE_ID="$approved_bundle_id" \
    "$inspector" "$archive" "$unsigned_inspection" \
    > "$private_root/unsigned-inspection.stdout" \
    2> "$private_root/unsigned-inspection.stderr"; then
  printf '%s\n' RELEASE_PAYLOAD_INSPECTION_FAILED >&2
  exit 1
fi

plist="$app/Contents/Info.plist"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
  "$plist" 2> "$private_root/version.private")" || {
  printf '%s\n' RELEASE_VERSION_MISMATCH >&2
  exit 1
}
build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' \
  "$plist" 2> "$private_root/build.private")" || {
  printf '%s\n' RELEASE_BUILD_MISMATCH >&2
  exit 1
}
test "$version" = "$expected_version" || {
  printf '%s\n' RELEASE_VERSION_MISMATCH >&2
  exit 1
}
test "$build" = "$expected_build" || {
  printf '%s\n' RELEASE_BUILD_MISMATCH >&2
  exit 1
}
archs="$(/usr/bin/lipo -archs "$main_binary" \
  2> "$private_root/lipo.private")" || {
  printf '%s\n' RELEASE_ARCHITECTURE_UNVERIFIABLE >&2
  exit 2
}
test "$archs" = arm64 || {
  printf '%s\n' RELEASE_ARCHITECTURE_MISMATCH >&2
  exit 1
}

payload_root="$private_root/payload"
/bin/mkdir "$payload_root"
signed_app="$payload_root/GlideTranslate.app"
/usr/bin/ditto "$app" "$signed_app"
if ! /usr/bin/codesign --force --deep --sign - --options runtime \
    --entitlements "$entitlements" "$signed_app" \
    > "$private_root/signing.stdout.private" \
    2> "$private_root/signing.stderr.private"; then
  printf '%s\n' RELEASE_SIGNING_FAILED >&2
  exit 1
fi
if ! /usr/bin/codesign --verify --deep --strict "$signed_app" \
    > "$private_root/signature-verify.stdout.private" \
    2> "$private_root/signature-verify.stderr.private"; then
  printf '%s\n' RELEASE_SIGNATURE_INVALID >&2
  exit 1
fi
if ! /usr/bin/codesign -dvvv "$signed_app" >/dev/null \
    2> "$private_root/signature-details.private"; then
  printf '%s\n' RELEASE_SIGNATURE_UNVERIFIABLE >&2
  exit 2
fi
details="$private_root/signature-details.private"
if ! LC_ALL=C rg -q '^Identifier=com[.]zaryolabs[.]GlideTranslate$' "$details" ||
   ! LC_ALL=C rg -q '^Signature=adhoc$' "$details" ||
   ! LC_ALL=C rg -q '^TeamIdentifier=not set$' "$details" ||
   ! LC_ALL=C rg -q '^CodeDirectory .*flags=.*runtime' "$details" ||
   LC_ALL=C rg -q '^Authority=' "$details"; then
  printf '%s\n' RELEASE_SIGNATURE_CLASSIFICATION_MISMATCH >&2
  exit 1
fi
if ! /usr/bin/codesign -d --entitlements :- "$signed_app" \
    > "$private_root/final-entitlements.plist" \
    2> "$private_root/entitlements.private" ||
   ! /usr/bin/plutil -convert binary1 \
      -o "$private_root/final-entitlements.binary" \
      "$private_root/final-entitlements.plist" \
      2> "$private_root/entitlements-plutil.private" ||
   ! /usr/bin/plutil -convert binary1 \
      -o "$private_root/approved-entitlements.binary" "$entitlements" \
      2>> "$private_root/entitlements-plutil.private" ||
   ! /usr/bin/cmp -s "$private_root/final-entitlements.binary" \
      "$private_root/approved-entitlements.binary"; then
  printf '%s\n' RELEASE_ENTITLEMENTS_MISMATCH >&2
  exit 1
fi
spctl_status=0
/usr/sbin/spctl -a -t exec -vv "$signed_app" \
  > "$private_root/spctl.stdout.private" \
  2> "$private_root/spctl.stderr.private" || spctl_status=$?
case "$spctl_status" in
  3)
    spctl_developer_id_status=0
    LC_ALL=C rg -qi \
      -e '^(source|origin)=[^[:cntrl:]]*Developer ID[^[:cntrl:]]*$' \
      -e '^Developer ID[^[:cntrl:]]*$' \
      "$private_root/spctl.stdout.private" \
      "$private_root/spctl.stderr.private" \
      >/dev/null 2>&1 || spctl_developer_id_status=$?
    case "$spctl_developer_id_status" in
      0)
        printf '%s\n' RELEASE_GATEKEEPER_CLASSIFICATION_MISMATCH >&2
        exit 1
        ;;
      1) ;;
      *)
        printf '%s\n' RELEASE_GATEKEEPER_UNVERIFIABLE >&2
        exit 2
        ;;
    esac
    # Validate the complete diagnostic set. Every nonempty line must be an
    # exact no-usable-signature/ad-hoc reason or a generic rejection line;
    # existential matching would hide a contradictory extra diagnostic.
    spctl_output_status=0
    LC_ALL=C /usr/bin/awk '
      BEGIN { saw_accepted = 0; invalid = 0 }
      NF {
        line = tolower($0)
        if (line ~ /^source=no usable signature$/ ||
            line ~ /^origin=no usable signature$/ ||
            line ~ /^source=ad[ -]?hoc$/ ||
            line ~ /^origin=ad[ -]?hoc$/ ||
            line ~ /^[^[:cntrl:]]+:[[:space:]]+rejected$/) {
          saw_accepted = 1
        } else {
          invalid = 1
        }
      }
      END {
        if (invalid || !saw_accepted) exit 1
        exit 0
      }
    ' "$private_root/spctl.stdout.private" \
      "$private_root/spctl.stderr.private" \
      >/dev/null 2>&1 || spctl_output_status=$?
    case "$spctl_output_status" in
      0) ;;
      1)
        printf '%s\n' RELEASE_GATEKEEPER_CLASSIFICATION_MISMATCH >&2
        exit 1
        ;;
      *)
        printf '%s\n' RELEASE_GATEKEEPER_UNVERIFIABLE >&2
        exit 2
        ;;
    esac
    ;;
  0)
    printf '%s\n' RELEASE_GATEKEEPER_CLASSIFICATION_MISMATCH >&2
    exit 1
    ;;
  *)
    printf '%s\n' RELEASE_GATEKEEPER_UNVERIFIABLE >&2
    exit 2
    ;;
esac

policy_status=0
/usr/bin/syspolicy_check distribution "$signed_app" --json \
  > "$private_root/syspolicy.json" \
  2> "$private_root/syspolicy.private" || policy_status=$?
case "$policy_status" in
  70) ;;
  0)
    printf '%s\n' RELEASE_GATEKEEPER_CLASSIFICATION_MISMATCH >&2
    exit 1
    ;;
  *)
    printf '%s\n' RELEASE_GATEKEEPER_UNVERIFIABLE >&2
    exit 2
    ;;
esac
policy_json_status=0
/usr/bin/jq -e '
  .output | type == "array" and length == 2 and
  ([.[] | {
    level: .SyspolicyCheckErrorLevel,
    category: .SyspolicyCheckShortError
  }] | sort_by(.category)) == [
    {level: "Warning", category: "Adhoc Signed App"},
    {level: "Fatal", category: "Notary Ticket Missing"}
  ]
' "$private_root/syspolicy.json" >/dev/null \
    2> "$private_root/syspolicy-jq.private" || policy_json_status=$?
case "$policy_json_status" in
  0) ;;
  1)
    printf '%s\n' RELEASE_GATEKEEPER_CLASSIFICATION_MISMATCH >&2
    exit 1
    ;;
  *)
    printf '%s\n' RELEASE_GATEKEEPER_UNVERIFIABLE >&2
    exit 2
    ;;
esac

signed_inspection="$private_root/signed-inspection"
if ! GT_APPROVED_BUNDLE_ID="$approved_bundle_id" \
    "$inspector" "$payload_root" "$signed_inspection" \
    > "$private_root/signed-inspection.stdout" \
    2> "$private_root/signed-inspection.stderr"; then
  printf '%s\n' RELEASE_PAYLOAD_INSPECTION_FAILED >&2
  exit 1
fi
if ! write_tree_manifest "$payload_root" \
    "$private_root/source-manifest.txt" \
    "$private_root/source-manifest.paths" \
    "$private_root/source-manifest.unsorted"; then
  printf '%s\n' RELEASE_ARCHIVE_MANIFEST_UNVERIFIABLE >&2
  exit 2
fi

private_zip="$private_root/$artifact_name"
if ! /usr/bin/ditto -c -k --keepParent "$signed_app" "$private_zip" \
    > "$private_root/zip.stdout.private" \
    2> "$private_root/zip.stderr.private"; then
  printf '%s\n' RELEASE_ARCHIVE_CREATION_FAILED >&2
  exit 1
fi
extracted="$private_root/extracted"
/bin/mkdir "$extracted"
if ! /usr/bin/ditto -x -k "$private_zip" "$extracted" \
    > "$private_root/unzip.stdout.private" \
    2> "$private_root/unzip.stderr.private"; then
  printf '%s\n' RELEASE_ARCHIVE_EXTRACTION_FAILED >&2
  exit 1
fi
extracted_app="$extracted/GlideTranslate.app"
test -x "$extracted_app/Contents/MacOS/GlideTranslate" || {
  printf '%s\n' RELEASE_ARCHIVE_ROUNDTRIP_MISMATCH >&2
  exit 1
}
if ! write_tree_manifest "$extracted" \
    "$private_root/extracted-manifest.txt" \
    "$private_root/extracted-manifest.paths" \
    "$private_root/extracted-manifest.unsorted"; then
  printf '%s\n' RELEASE_ARCHIVE_MANIFEST_UNVERIFIABLE >&2
  exit 2
fi
if ! /usr/bin/cmp -s "$private_root/source-manifest.txt" \
    "$private_root/extracted-manifest.txt"; then
  printf '%s\n' RELEASE_ARCHIVE_ROUNDTRIP_MISMATCH >&2
  exit 1
fi
if ! /usr/bin/codesign --verify --deep --strict "$extracted_app" \
    > "$private_root/extracted-signature.stdout.private" \
    2> "$private_root/extracted-signature.stderr.private"; then
  printf '%s\n' RELEASE_ARCHIVE_SIGNATURE_INVALID >&2
  exit 1
fi
extracted_inspection="$private_root/extracted-inspection"
if ! GT_APPROVED_BUNDLE_ID="$approved_bundle_id" \
    "$inspector" "$extracted" "$extracted_inspection" \
    > "$private_root/extracted-inspection.stdout" \
    2> "$private_root/extracted-inspection.stderr"; then
  printf '%s\n' RELEASE_PAYLOAD_INSPECTION_FAILED >&2
  exit 1
fi

/bin/mkdir -m 700 "$output_root"
output_created=1
/bin/cp "$private_zip" "$output_root/$artifact_name"
if ! (
  cd "$output_root"
  /usr/bin/shasum -a 256 "$artifact_name" > "$checksum_name"
); then
  printf '%s\n' RELEASE_CHECKSUM_UNVERIFIABLE >&2
  exit 2
fi
if ! (
  cd "$output_root"
  /usr/bin/shasum -a 256 -c "$checksum_name" >/dev/null 2>&1
); then
  printf '%s\n' RELEASE_CHECKSUM_MISMATCH >&2
  exit 1
fi
test "$(/usr/bin/find "$output_root" -type f | /usr/bin/wc -l | \
  /usr/bin/tr -d ' ')" -eq 2 || {
  printf '%s\n' RELEASE_OUTPUT_INVALID >&2
  exit 1
}

release_success=1
printf '%s\n' ADHOC_RELEASE_PACKAGE_PASSED
