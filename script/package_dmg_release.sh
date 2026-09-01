#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

if [ "$#" -ne 2 ]; then
  printf '%s\n' RELEASE_ARGUMENTS_INVALID >&2
  exit 1
fi

workspace_root="$(cd "$(dirname "$0")/.." && pwd)"
archive="$1"
output_root="$2"
expected_version=0.2.2
expected_build=3
artifact_name=GlideTranslate-0.2.2-macos-arm64.dmg
approved_bundle_id=com.zaryolabs.GlideTranslate
inspector="$workspace_root/script/inspect_release_payload.sh"
entitlements="$workspace_root/App/GlideTranslate/GlideTranslate.entitlements"

# Keep the release boundary explicit. Tests replace these absolute tool paths
# in temporary copies; the normal path always uses the native macOS tools.
codesign_bin=/usr/bin/codesign
hdiutil_bin=/usr/bin/hdiutil
jq_bin=/usr/bin/jq
spctl_bin=/usr/sbin/spctl
syspolicy_bin=/usr/bin/syspolicy_check

fail() {
  printf '%s\n' "$1" >&2
  exit "${2:-1}"
}

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
      entry_type='file'
      if ! entry_hash="$(/usr/bin/shasum -a 256 "$manifest_path" \
          2>> "$private_root/manifest.private" \
          | /usr/bin/awk '{print $1}')"; then
        return 1
      fi
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
    if ! entry_mode="$(/usr/bin/stat -f '%Lp' "$manifest_path" \
        2>> "$private_root/manifest.private")"; then
      return 1
    fi
    case "$entry_mode" in
      ''|*[!0-7]*) return 1 ;;
    esac
    printf '%s\t%s\t%s\t%s\n' \
      "$relative_path" "$entry_type" "$entry_mode" "$entry_hash" \
      >> "$manifest_unsorted"
  done < "$manifest_paths"
  if ! LC_ALL=C /usr/bin/sort "$manifest_unsorted" > "$manifest_output" \
      2>> "$private_root/manifest.private"; then
    return 1
  fi
}

verify_gatekeeper_classification() {
  spctl_status=0
  "$spctl_bin" -a -t exec -vv "$signed_app" \
    > "$private_root/spctl.stdout.private" \
    2> "$private_root/spctl.stderr.private" || spctl_status=$?
  case "$spctl_status" in
    3)
      spctl_developer_id_status=0
      LC_ALL=C rg -qi \
        -e '^(source|origin)=[^[:cntrl:]]*Developer ID[^[:cntrl:]]*$' \
        -e '^Developer ID[^[:cntrl:]]*$' \
        "$private_root/spctl.stdout.private" \
        "$private_root/spctl.stderr.private" >/dev/null 2>&1 \
        || spctl_developer_id_status=$?
      case "$spctl_developer_id_status" in
        0) fail RELEASE_GATEKEEPER_CLASSIFICATION_MISMATCH ;;
        1) ;;
        *) fail RELEASE_GATEKEEPER_UNVERIFIABLE 2 ;;
      esac
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
        "$private_root/spctl.stderr.private" >/dev/null 2>&1 \
        || spctl_output_status=$?
      case "$spctl_output_status" in
        0) ;;
        1) fail RELEASE_GATEKEEPER_CLASSIFICATION_MISMATCH ;;
        *) fail RELEASE_GATEKEEPER_UNVERIFIABLE 2 ;;
      esac
      ;;
    0) fail RELEASE_GATEKEEPER_CLASSIFICATION_MISMATCH ;;
    *) fail RELEASE_GATEKEEPER_UNVERIFIABLE 2 ;;
  esac

  policy_status=0
  "$syspolicy_bin" distribution "$signed_app" --json \
    > "$private_root/syspolicy.json" \
    2> "$private_root/syspolicy.private" || policy_status=$?
  case "$policy_status" in
    70) ;;
    0) fail RELEASE_GATEKEEPER_CLASSIFICATION_MISMATCH ;;
    *) fail RELEASE_GATEKEEPER_UNVERIFIABLE 2 ;;
  esac
  policy_json_status=0
  "$jq_bin" -e '
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
    1) fail RELEASE_GATEKEEPER_CLASSIFICATION_MISMATCH ;;
    *) fail RELEASE_GATEKEEPER_UNVERIFIABLE 2 ;;
  esac
}

if ! test -d "$archive"; then
  fail RELEASE_ARCHIVE_INVALID
fi
if test -e "$output_root" || test -L "$output_root"; then
  fail RELEASE_OUTPUT_EXISTS
fi
if ! test -x "$inspector" || ! test -f "$entitlements"; then
  fail RELEASE_INPUT_MISSING
fi

app="$archive/Products/Applications/GlideTranslate.app"
main_binary="$app/Contents/MacOS/GlideTranslate"
if ! test -d "$app" || ! test -f "$main_binary"; then
  fail RELEASE_ARCHIVE_LAYOUT_INVALID
fi

private_root=""
if ! private_root="$(/usr/bin/mktemp -d 2>/dev/null)"; then
  fail RELEASE_TEMP_UNAVAILABLE 2
fi
output_created=0
attached=0
detach_target=""
mount_point=""
release_success=0

cleanup() {
  prior_status=$?
  trap - EXIT INT TERM HUP
  cleanup_status=0
  if [ "$attached" -eq 1 ] && [ -n "$detach_target" ]; then
    if ! "$hdiutil_bin" detach "$detach_target" \
        > /dev/null 2> "$private_root/detach-cleanup.private"; then
      "$hdiutil_bin" detach -force "$detach_target" \
        > /dev/null 2>> "$private_root/detach-cleanup.private" \
        || cleanup_status=1
    fi
  fi
  /bin/rm -rf "$private_root" >/dev/null 2>&1 || cleanup_status=1
  if [ "$release_success" -ne 1 ] && [ "$output_created" -eq 1 ]; then
    /bin/rm -rf "$output_root" >/dev/null 2>&1 || cleanup_status=1
  fi
  if [ "$prior_status" -ne 0 ]; then
    exit "$prior_status"
  fi
  if [ "$cleanup_status" -ne 0 ]; then
    printf '%s\n' RELEASE_CLEANUP_FAILED >&2
    exit 2
  fi
  exit 0
}

cleanup_signal() {
  signal_status="$1"
  trap - EXIT INT TERM HUP
  if [ "$attached" -eq 1 ] && [ -n "$detach_target" ]; then
    "$hdiutil_bin" detach "$detach_target" >/dev/null 2>&1 || \
      "$hdiutil_bin" detach -force "$detach_target" >/dev/null 2>&1 || true
  fi
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
  fail RELEASE_PAYLOAD_INSPECTION_FAILED
fi

plist="$app/Contents/Info.plist"
if ! version="$(/usr/libexec/PlistBuddy \
    -c 'Print :CFBundleShortVersionString' "$plist" \
    2> "$private_root/version.private")"; then
  fail RELEASE_VERSION_MISMATCH
fi
if ! build="$(/usr/libexec/PlistBuddy \
    -c 'Print :CFBundleVersion' "$plist" \
    2> "$private_root/build.private")"; then
  fail RELEASE_BUILD_MISMATCH
fi
if [ "$version" != "$expected_version" ]; then
  fail RELEASE_VERSION_MISMATCH
fi
if [ "$build" != "$expected_build" ]; then
  fail RELEASE_BUILD_MISMATCH
fi
if ! archs="$(/usr/bin/lipo -archs "$main_binary" \
    2> "$private_root/lipo.private")"; then
  fail RELEASE_ARCHITECTURE_UNVERIFIABLE 2
fi
if [ "$archs" != arm64 ]; then
  fail RELEASE_ARCHITECTURE_MISMATCH
fi

payload_root="$private_root/payload"
if ! /bin/mkdir "$payload_root" \
    > /dev/null 2> "$private_root/payload-mkdir.private"; then
  fail RELEASE_STAGING_FAILED 2
fi
signed_app="$payload_root/GlideTranslate.app"
if ! /usr/bin/ditto "$app" "$signed_app" \
    > "$private_root/stage-copy.stdout.private" \
    2> "$private_root/stage-copy.stderr.private"; then
  fail RELEASE_STAGING_FAILED
fi
if ! "$codesign_bin" --force --deep --sign - --options runtime \
    --entitlements "$entitlements" "$signed_app" \
    > "$private_root/signing.stdout.private" \
    2> "$private_root/signing.stderr.private"; then
  fail RELEASE_SIGNING_FAILED
fi
if ! "$codesign_bin" --verify --deep --strict "$signed_app" \
    > "$private_root/signature-verify.stdout.private" \
    2> "$private_root/signature-verify.stderr.private"; then
  fail RELEASE_SIGNATURE_INVALID
fi
if ! "$codesign_bin" -dvvv "$signed_app" >/dev/null \
    2> "$private_root/signature-details.private"; then
  fail RELEASE_SIGNATURE_UNVERIFIABLE 2
fi
details="$private_root/signature-details.private"
if ! LC_ALL=C rg -q '^Identifier=com[.]zaryolabs[.]GlideTranslate$' "$details" ||
   ! LC_ALL=C rg -q '^Signature=adhoc$' "$details" ||
   ! LC_ALL=C rg -q '^TeamIdentifier=not set$' "$details" ||
   ! LC_ALL=C rg -q '^CodeDirectory .*flags=.*runtime' "$details" ||
   LC_ALL=C rg -q '^Authority=' "$details"; then
  fail RELEASE_SIGNATURE_CLASSIFICATION_MISMATCH
fi
if ! "$codesign_bin" -d --entitlements :- "$signed_app" \
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
  fail RELEASE_ENTITLEMENTS_MISMATCH
fi
verify_gatekeeper_classification

signed_inspection="$private_root/signed-inspection"
if ! GT_APPROVED_BUNDLE_ID="$approved_bundle_id" \
    "$inspector" "$payload_root" "$signed_inspection" \
    > "$private_root/signed-inspection.stdout" \
    2> "$private_root/signed-inspection.stderr"; then
  fail RELEASE_PAYLOAD_INSPECTION_FAILED
fi
staging_root="$private_root/dmg-staging"
if ! /bin/mkdir "$staging_root" \
    > /dev/null 2> "$private_root/dmg-staging-mkdir.private"; then
  fail RELEASE_DMG_STAGING_FAILED 2
fi
if ! /usr/bin/ditto "$signed_app" "$staging_root/GlideTranslate.app" \
    > "$private_root/dmg-stage-copy.stdout.private" \
    2> "$private_root/dmg-stage-copy.stderr.private"; then
  fail RELEASE_DMG_STAGING_FAILED
fi
if ! /bin/ln -s /Applications "$staging_root/Applications" \
    > /dev/null 2> "$private_root/dmg-symlink-create.private"; then
  fail RELEASE_DMG_STAGING_FAILED
fi
if ! write_tree_manifest "$staging_root/GlideTranslate.app" \
    "$private_root/source-manifest.txt" \
    "$private_root/source-manifest.paths" \
    "$private_root/source-manifest.unsorted"; then
  fail RELEASE_DMG_MANIFEST_UNVERIFIABLE 2
fi

private_dmg="$private_root/$artifact_name"
if ! "$hdiutil_bin" create -volname "Glide Translate $expected_version" \
    -srcfolder "$staging_root" -format UDZO -ov "$private_dmg" \
    > "$private_root/dmg-create.stdout.private" \
    2> "$private_root/dmg-create.stderr.private"; then
  fail RELEASE_DMG_CREATE_FAILED
fi
if ! test -f "$private_dmg"; then
  fail RELEASE_DMG_CREATE_FAILED
fi

attach_plist="$private_root/dmg-attach.plist"
if ! "$hdiutil_bin" attach -readonly -nobrowse -plist "$private_dmg" \
    > "$attach_plist" 2> "$private_root/dmg-attach.stderr.private"; then
  fail RELEASE_DMG_ATTACH_FAILED
fi
# Treat a successful attach as live state immediately. Resolve a device entry
# independently from the mount-point entry so parse failures still clean up
# through a valid hdiutil detach target.
attached=1
detach_target=""
mount_point=""
fallback_mount_point=""
fallback_device=""
preferred_device=""
preferred_mount_point=""
entity_index=0
while [ "$entity_index" -lt 128 ]; do
  entity_device=""
  entity_device_status=0
  entity_device="$(/usr/libexec/PlistBuddy \
    -c "Print :system-entities:$entity_index:dev-entry" "$attach_plist" \
    2>> "$private_root/dmg-dev-entry.private")" || entity_device_status=$?
  entity_mount=""
  entity_mount_status=0
  entity_mount="$(/usr/libexec/PlistBuddy \
    -c "Print :system-entities:$entity_index:mount-point" "$attach_plist" \
    2>> "$private_root/dmg-mount-point.private")" || entity_mount_status=$?
  entity_device_valid=0
  case "$entity_device" in
    /dev/*)
      case "$entity_device" in
        /dev/|*[[:cntrl:]]*) ;;
        *) entity_device_valid=1 ;;
      esac
      ;;
  esac
  entity_mount_valid=0
  case "$entity_mount" in
    ''|*[[:cntrl:]]*) ;;
    *) entity_mount_valid=1 ;;
  esac
  if [ "$entity_device_status" -eq 0 ] && [ "$entity_device_valid" -eq 1 ]; then
    if [ -z "$fallback_device" ]; then
      fallback_device="$entity_device"
    fi
    if [ "$entity_mount_status" -eq 0 ] &&
       [ "$entity_mount_valid" -eq 1 ] &&
       [ -z "$preferred_device" ]; then
      preferred_device="$entity_device"
      preferred_mount_point="$entity_mount"
    fi
  fi
  if [ "$entity_mount_status" -eq 0 ] &&
     [ "$entity_mount_valid" -eq 1 ] &&
     [ -z "$fallback_mount_point" ]; then
    fallback_mount_point="$entity_mount"
  fi
  entity_index=$((entity_index + 1))
done
if [ -n "$preferred_mount_point" ]; then
  mount_point="$preferred_mount_point"
elif [ -n "$fallback_mount_point" ]; then
  mount_point="$fallback_mount_point"
fi
if [ -n "$preferred_device" ]; then
  detach_target="$preferred_device"
else
  detach_target="$fallback_device"
fi
if [ -z "$detach_target" ] && [ -n "$mount_point" ]; then
  detach_target="$mount_point"
fi
if [ -z "$mount_point" ] || ! test -d "$mount_point"; then
  fail RELEASE_DMG_ATTACH_FAILED
fi
if [ -z "$detach_target" ]; then
  fail RELEASE_DMG_ATTACH_FAILED 2
fi

if ! test -d "$mount_point/GlideTranslate.app" || \
   test -L "$mount_point/GlideTranslate.app" || \
   ! test -L "$mount_point/Applications"; then
  fail RELEASE_DMG_LAYOUT_INVALID
fi
if ! symlink_target="$(/usr/bin/readlink "$mount_point/Applications" \
    2> "$private_root/dmg-symlink.private")"; then
  fail RELEASE_DMG_SYMLINK_INVALID
fi
if [ "$symlink_target" != /Applications ]; then
  fail RELEASE_DMG_SYMLINK_INVALID
fi
if ! root_entries="$(/usr/bin/find "$mount_point" -mindepth 1 -maxdepth 1 \
    -print 2> "$private_root/dmg-layout.private")"; then
  fail RELEASE_DMG_LAYOUT_UNVERIFIABLE 2
fi
if ! /usr/bin/awk -v root="$mount_point" '
  BEGIN { count = 0; invalid = 0 }
  NF {
    count++
    if ($0 != root "/GlideTranslate.app" &&
        $0 != root "/Applications") invalid = 1
  }
  END { if (count != 2 || invalid) exit 1 }
' <<< "$root_entries"; then
  fail RELEASE_DMG_LAYOUT_INVALID
fi

mounted_app="$mount_point/GlideTranslate.app"
if ! write_tree_manifest "$mounted_app" \
    "$private_root/mounted-manifest.txt" \
    "$private_root/mounted-manifest.paths" \
    "$private_root/mounted-manifest.unsorted"; then
  fail RELEASE_DMG_MANIFEST_UNVERIFIABLE 2
fi
if ! /usr/bin/cmp -s "$private_root/source-manifest.txt" \
    "$private_root/mounted-manifest.txt"; then
  fail RELEASE_DMG_ROUNDTRIP_MISMATCH
fi
if ! "$codesign_bin" --verify --deep --strict "$mounted_app" \
    > "$private_root/mounted-signature.stdout.private" \
    2> "$private_root/mounted-signature.stderr.private"; then
  fail RELEASE_DMG_SIGNATURE_INVALID
fi
mounted_inspection_root="$private_root/mounted-inspection-root"
if ! /bin/mkdir "$mounted_inspection_root" || \
   ! /usr/bin/ditto "$mounted_app" \
      "$mounted_inspection_root/GlideTranslate.app" \
      > "$private_root/mounted-inspection-copy.stdout.private" \
      2> "$private_root/mounted-inspection-copy.stderr.private"; then
  fail RELEASE_DMG_INSPECTION_FAILED
fi
mounted_inspection="$private_root/mounted-inspection"
if ! GT_APPROVED_BUNDLE_ID="$approved_bundle_id" \
    "$inspector" "$mounted_inspection_root" "$mounted_inspection" \
    > "$private_root/mounted-inspection.stdout" \
    2> "$private_root/mounted-inspection.stderr"; then
  fail RELEASE_DMG_INSPECTION_FAILED
fi

if ! "$hdiutil_bin" detach "$detach_target" \
    > "$private_root/dmg-detach.stdout.private" \
    2> "$private_root/dmg-detach.stderr.private"; then
  if ! "$hdiutil_bin" detach -force "$detach_target" \
      >> "$private_root/dmg-detach.stdout.private" \
      2>> "$private_root/dmg-detach.stderr.private"; then
    fail RELEASE_DMG_DETACH_FAILED
  fi
fi
attached=0
if test -e "$mount_point"; then
  fail RELEASE_DMG_DETACH_FAILED
fi

if ! /bin/mkdir -m 700 "$output_root" \
    > /dev/null 2> "$private_root/output-mkdir.private"; then
  fail RELEASE_OUTPUT_CREATE_FAILED 2
fi
output_created=1
if ! /bin/cp "$private_dmg" "$output_root/$artifact_name" \
    > /dev/null 2> "$private_root/output-copy.private"; then
  fail RELEASE_DMG_OUTPUT_COPY_FAILED
fi
if ! test -f "$output_root/$artifact_name" || \
   test -L "$output_root/$artifact_name"; then
  fail RELEASE_DMG_OUTPUT_INVALID
fi
if ! output_entries="$(/usr/bin/find "$output_root" -mindepth 1 -maxdepth 1 \
    -print 2> "$private_root/output-layout.private")"; then
  fail RELEASE_DMG_OUTPUT_INVALID 2
fi
if ! /usr/bin/awk -v expected="$output_root/$artifact_name" '
  BEGIN { count = 0; invalid = 0 }
  NF { count++; if ($0 != expected) invalid = 1 }
  END { if (count != 1 || invalid) exit 1 }
' <<< "$output_entries"; then
  fail RELEASE_DMG_OUTPUT_INVALID
fi

release_success=1
printf '%s\n' DMG_RELEASE_PACKAGE_PASSED
