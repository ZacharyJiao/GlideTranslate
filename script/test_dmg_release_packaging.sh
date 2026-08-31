#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

workspace_root="$(cd "$(dirname "$0")/.." && pwd)"
packager="$workspace_root/script/package_dmg_release.sh"
inspector="$workspace_root/script/inspect_release_payload.sh"
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

# This executable assertion is intentionally first: it records RED while the
# old ZIP-only packager is still present and the DMG entry point is absent.
test -x "$packager"
test -x "$inspector"

record_stage() {
  if [ -n "${GT_AGGREGATE_STAGE_FILE:-}" ]; then
    printf 'DMG_RELEASE_PACKAGING_TESTS_%s\n' "$1" > "$GT_AGGREGATE_STAGE_FILE"
  fi
}

make_archive() {
  name="$1"
  version="$2"
  build="${3:-2}"
  archive="$fixture_root/$name.xcarchive"
  app="$archive/Products/Applications/GlideTranslate.app"
  /bin/mkdir -p "$app/Contents/MacOS" \
    "$app/Contents/Resources/en.lproj" \
    "$app/Contents/Resources/zh-Hans.lproj" "$archive/dSYMs"
  /usr/bin/clang -arch arm64 -x c \
    -o "$app/Contents/MacOS/GlideTranslate" - <<'EOF'
int main(void) { return 0; }
EOF
  /usr/libexec/PlistBuddy -c Clear \
    -c 'Add :CFBundleIdentifier string com.zaryolabs.GlideTranslate' \
    -c 'Add :CFBundleShortVersionString string '"$version" \
    -c 'Add :CFBundleVersion string '"$build" \
    -c 'Add :LSMinimumSystemVersion string 14.0' \
    -c 'Add :LSUIElement bool true' \
    "$app/Contents/Info.plist" >/dev/null
  printf '%s\n' 'safe localized resource' \
    > "$app/Contents/Resources/en.lproj/Localizable.strings"
  printf '%s\n' 'safe archive metadata' > "$archive/Info.plist"
  printf '%s\n' "$archive"
}

assert_closed_failure() {
  name="$1"
  expected="$2"
  shift 2
  status=0
  "$@" > "$fixture_root/$name.stdout" 2> "$fixture_root/$name.stderr" \
    || status=$?
  test "$status" -ne 0
  test "$(/bin/cat "$fixture_root/$name.stderr")" = "$expected"
  test ! -s "$fixture_root/$name.stdout"
}

make_spctl() {
  path="$1"
  mode="${2:-expected}"
  case "$mode" in
    expected)
      /usr/bin/printf '%s\n' '#!/usr/bin/env bash' \
        'printf "%s\\n" "source=No usable signature" >&2' \
        'exit 3' > "$path" ;;
    failure)
      /usr/bin/printf '%s\n' '#!/usr/bin/env bash' 'exit 9' > "$path" ;;
    developer-id)
      /usr/bin/printf '%s\n' '#!/usr/bin/env bash' \
        'printf "%s\\n" "source=Unnotarized Developer ID" >&2' \
        'exit 3' > "$path" ;;
    accepted)
      /usr/bin/printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$path" ;;
    *)
      /usr/bin/printf '%s\n' '#!/usr/bin/env bash' \
        'printf "%s\\n" "source=Unrelated Policy Denial" >&2' \
        'exit 3' > "$path" ;;
  esac
  /bin/chmod 755 "$path"
}

make_policy() {
  path="$1"
  mode="${2:-expected}"
  case "$mode" in
    expected)
      policy_json='{"output":[{"SyspolicyCheckErrorLevel":"Warning","SyspolicyCheckShortError":"Adhoc Signed App"},{"SyspolicyCheckErrorLevel":"Fatal","SyspolicyCheckShortError":"Notary Ticket Missing"}]}'
      /usr/bin/printf '%s\n' '#!/usr/bin/env bash' \
        "printf '%s\\n' '$policy_json'" \
        'exit 70' > "$path" ;;
    failure)
      /usr/bin/printf '%s\n' '#!/usr/bin/env bash' 'exit 9' > "$path" ;;
    unrelated)
      policy_json='{"output":[{"SyspolicyCheckErrorLevel":"Fatal","SyspolicyCheckShortError":"Unrelated Policy Denial"}]}'
      /usr/bin/printf '%s\n' '#!/usr/bin/env bash' \
        "printf '%s\\n' '$policy_json'" \
        'exit 70' > "$path" ;;
    malformed)
      /usr/bin/printf '%s\n' '#!/usr/bin/env bash' \
        'printf "%s\\n" "{malformed"' 'exit 70' > "$path" ;;
    partial)
      policy_json='{"output":[{"SyspolicyCheckErrorLevel":"Warning","SyspolicyCheckShortError":"Adhoc Signed App"}]}'
      /usr/bin/printf '%s\n' '#!/usr/bin/env bash' \
        "printf '%s\\n' '$policy_json'" \
        'exit 70' > "$path" ;;
  esac
  /bin/chmod 755 "$path"
}

make_hdiutil() {
  path="$1"
  /usr/bin/printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    'mode="${GT_HDIUTIL_MODE:-expected}"' \
    'log="${GT_HDIUTIL_LOG:?}"' \
    'mountpoint_file="${GT_HDIUTIL_MOUNTPOINT_FILE:?}"' \
    'printf "%s\\n" "$@" >> "$log"' \
    'verb="${1:?}"' \
    'case "$verb" in' \
    '  create)' \
    '    [ "$mode" != create-failure ] || exit 9' \
    '    source=""' \
    '    image="${@: -1}"' \
    '    while [ "$#" -gt 0 ]; do' \
    '      if [ "$1" = -srcfolder ]; then source="$2"; shift 2; else shift; fi' \
    '    done' \
    '    [ -n "$source" ] || exit 64' \
    '    /bin/mkdir -p "$image.contents"' \
    '    /usr/bin/ditto "$source" "$image.contents"' \
    '    /usr/bin/touch "$image"' \
    '    ;;' \
    '  attach)' \
    '    [ "$mode" != attach-failure ] || exit 9' \
    '    image="${@: -1}"' \
    '    mountpoint="$image.mount"' \
    '    printf "%s\\n" "$mountpoint" > "$mountpoint_file"' \
    '    /bin/mkdir -p "$mountpoint"' \
    '    /usr/bin/ditto "$image.contents" "$mountpoint"' \
    '    if [ "$mode" = wrong-layout ]; then /usr/bin/touch "$mountpoint/Unexpected"; fi' \
    '    if [ "$mode" = wrong-symlink ]; then /bin/rm -f "$mountpoint/Applications"; /bin/ln -s /tmp/not-applications "$mountpoint/Applications"; fi' \
    '    if [ "$mode" = roundtrip ]; then /bin/chmod 644 "$mountpoint/GlideTranslate.app/Contents/MacOS/GlideTranslate"; fi' \
    '    if [ "$mode" = malformed-mount ]; then' \
    '      /usr/bin/printf "%s\\n" "<?xml version=\\"1.0\\" encoding=\\"UTF-8\\"?>" "<plist version=\\"1.0\\"><dict><key>system-entities</key><array><dict><key>dev-entry</key><string>/dev/mock-dmg</string></dict></array></dict></plist>"' \
    '    else' \
    '      /usr/bin/printf "%s\\n" "<?xml version=\\"1.0\\" encoding=\\"UTF-8\\"?>" "<plist version=\\"1.0\\"><dict><key>system-entities</key><array><dict><key>dev-entry</key><string>/dev/mock-dmg</string><key>mount-point</key><string>$mountpoint</string></dict></array></dict></plist>"' \
    '    fi' \
    '    ;;' \
    '  detach)' \
    '    [ "$mode" != detach-failure ] || exit 9' \
    '    target="${@: -1}"' \
    '    /bin/rm -rf "$(/bin/cat "$mountpoint_file")"' \
    '    ;;' \
    '  *) exit 64 ;;' \
    'esac' > "$path"
  /bin/chmod 755 "$path"
}

make_policy_wrapper() {
  path="$1"
  /usr/bin/printf '%s\n' '#!/usr/bin/env bash' \
    'exec "${GT_POLICY_REAL:?}" "$@"' > "$path"
  /bin/chmod 755 "$path"
}

accepted_spctl="$fixture_root/accepted-spctl"
make_spctl "$accepted_spctl"
accepted_policy="$fixture_root/accepted-policy"
make_policy "$accepted_policy"
hdiutil_stub="$fixture_root/hdiutil"
make_hdiutil "$hdiutil_stub"

make_packager() {
  destination="$1"
  spctl_path="$2"
  policy_path="$3"
  /usr/bin/sed \
    -e "s#workspace_root=.*#workspace_root='$workspace_root'#" \
    -e "s#/usr/sbin/spctl#$spctl_path#g" \
    -e "s#/usr/bin/syspolicy_check#$policy_path#g" \
    -e "s#/usr/bin/hdiutil#$hdiutil_stub#g" \
    "$packager" > "$destination"
  /bin/chmod 755 "$destination"
}

contract_packager="$fixture_root/contract-packager"
make_packager "$contract_packager" "$accepted_spctl" "$accepted_policy"

accepted_archive="$(make_archive accepted 0.2.1 2)"
accepted_output="$fixture_root/accepted-output"
export GT_HDIUTIL_LOG="$fixture_root/hdiutil.log"
export GT_HDIUTIL_MOUNTPOINT_FILE="$fixture_root/mountpoint"
record_stage ACCEPTED_FIXTURE
accepted_status=0
"$contract_packager" "$accepted_archive" "$accepted_output" \
  > "$fixture_root/accepted.stdout" 2> "$fixture_root/accepted.stderr" \
  || accepted_status=$?
if [ "$accepted_status" -ne 0 ]; then
  /bin/cat "$fixture_root/accepted.stderr"
  exit "$accepted_status"
fi
test "$(/bin/cat "$fixture_root/accepted.stdout")" = DMG_RELEASE_PACKAGE_PASSED
test ! -s "$fixture_root/accepted.stderr"
artifact_name=GlideTranslate-0.2.1-macos-arm64.dmg
test -f "$accepted_output/$artifact_name"
test "$(/usr/bin/find "$accepted_output" -type f | /usr/bin/wc -l | /usr/bin/tr -d ' ')" -eq 1
test "$(/usr/bin/find "$accepted_output" -type l | /usr/bin/wc -l | /usr/bin/tr -d ' ')" -eq 0
test -z "$(/usr/bin/find "$accepted_output" -mindepth 1 -maxdepth 1 \
  \( -name '*.zip' -o -name '*.sha256' \) -print)"
rg -q -- '-readonly' "$GT_HDIUTIL_LOG"
rg -q -- '-nobrowse' "$GT_HDIUTIL_LOG"

existing_output="$fixture_root/existing-output"
/bin/mkdir "$existing_output"
record_stage EXISTING_OUTPUT
assert_closed_failure existing RELEASE_OUTPUT_EXISTS \
  "$contract_packager" "$accepted_archive" "$existing_output"

wrong_version="$(make_archive wrong-version 1.0 2)"
record_stage WRONG_VERSION
assert_closed_failure wrong-version RELEASE_VERSION_MISMATCH \
  "$contract_packager" "$wrong_version" "$fixture_root/wrong-version-output"

wrong_build="$(make_archive wrong-build 0.2.1 1)"
record_stage WRONG_BUILD
assert_closed_failure wrong-build RELEASE_BUILD_MISMATCH \
  "$contract_packager" "$wrong_build" "$fixture_root/wrong-build-output"

wrong_architecture="$(make_archive wrong-architecture 0.2.1 2)"
/usr/bin/clang -arch x86_64 -x c \
  -o "$wrong_architecture/Products/Applications/GlideTranslate.app/Contents/MacOS/GlideTranslate" - <<'EOF'
int main(void) { return 0; }
EOF
record_stage WRONG_ARCHITECTURE
assert_closed_failure wrong-architecture RELEASE_PAYLOAD_INSPECTION_FAILED \
  "$contract_packager" "$wrong_architecture" "$fixture_root/wrong-architecture-output"

missing_layout="$fixture_root/missing-layout.xcarchive"
/bin/mkdir "$missing_layout"
record_stage MISSING_LAYOUT
assert_closed_failure missing-layout RELEASE_ARCHIVE_LAYOUT_INVALID \
  "$contract_packager" "$missing_layout" "$fixture_root/missing-layout-output"

signing_tool="$fixture_root/failing-codesign"
/usr/bin/printf '%s\n' '#!/usr/bin/env bash' 'exit 9' > "$signing_tool"
/bin/chmod 755 "$signing_tool"
signing_packager="$fixture_root/signing-packager"
/usr/bin/sed -e "s#workspace_root=.*#workspace_root='$workspace_root'#" \
  -e "s#/usr/sbin/spctl#$accepted_spctl#g" \
  -e "s#/usr/bin/syspolicy_check#$accepted_policy#g" \
  -e "s#/usr/bin/codesign#$signing_tool#g" \
  -e "s#/usr/bin/hdiutil#$hdiutil_stub#g" \
  "$packager" > "$signing_packager"
/bin/chmod 755 "$signing_packager"
record_stage SIGNING_FAILURE
assert_closed_failure signing RELEASE_SIGNING_FAILED \
  "$signing_packager" "$accepted_archive" "$fixture_root/signing-output"

classification_tool="$fixture_root/classification-codesign"
/usr/bin/printf '%s\n' '#!/usr/bin/env bash' \
  'if [ "$1" = -dvvv ]; then' \
  '  printf "%s\\n" "Identifier=com.zaryolabs.GlideTranslate" "CodeDirectory v=20500 flags=0x10002(adhoc,runtime)" "Signature=adhoc" "TeamIdentifier=unexpected" >&2' \
  '  exit 0' \
  'fi' \
  'exec /usr/bin/codesign "$@"' > "$classification_tool"
/bin/chmod 755 "$classification_tool"
classification_packager="$fixture_root/classification-packager"
/usr/bin/sed -e "s#workspace_root=.*#workspace_root='$workspace_root'#" \
  -e "s#/usr/sbin/spctl#$accepted_spctl#g" \
  -e "s#/usr/bin/syspolicy_check#$accepted_policy#g" \
  -e "s#/usr/bin/codesign#$classification_tool#g" \
  -e "s#/usr/bin/hdiutil#$hdiutil_stub#g" \
  "$packager" > "$classification_packager"
/bin/chmod 755 "$classification_packager"
record_stage SIGNATURE_CLASSIFICATION
assert_closed_failure classification RELEASE_SIGNATURE_CLASSIFICATION_MISMATCH \
  "$classification_packager" "$accepted_archive" "$fixture_root/classification-output"

entitlements_tool="$fixture_root/entitlements-codesign"
/usr/bin/printf '%s\n' '#!/usr/bin/env bash' \
  'if [ "$1" = -d ] && [ "$2" = --entitlements ]; then' \
  '  printf "%s\\n" "<?xml version=\"1.0\" encoding=\"UTF-8\"?>" "<plist version=\"1.0\"><dict><key>unexpected</key><true/></dict></plist>"' \
  '  exit 0' \
  'fi' \
  'exec /usr/bin/codesign "$@"' > "$entitlements_tool"
/bin/chmod 755 "$entitlements_tool"
entitlements_packager="$fixture_root/entitlements-packager"
/usr/bin/sed -e "s#workspace_root=.*#workspace_root='$workspace_root'#" \
  -e "s#/usr/sbin/spctl#$accepted_spctl#g" \
  -e "s#/usr/bin/syspolicy_check#$accepted_policy#g" \
  -e "s#/usr/bin/codesign#$entitlements_tool#g" \
  -e "s#/usr/bin/hdiutil#$hdiutil_stub#g" \
  "$packager" > "$entitlements_packager"
/bin/chmod 755 "$entitlements_packager"
record_stage ENTITLEMENTS
assert_closed_failure entitlements RELEASE_ENTITLEMENTS_MISMATCH \
  "$entitlements_packager" "$accepted_archive" "$fixture_root/entitlements-output"

failing_spctl="$fixture_root/failing-spctl"
make_spctl "$failing_spctl" failure
failing_spctl_packager="$fixture_root/failing-spctl-packager"
make_packager "$failing_spctl_packager" "$failing_spctl" "$accepted_policy"
record_stage SPCTL_FAILURE
assert_closed_failure spctl RELEASE_GATEKEEPER_UNVERIFIABLE \
  "$failing_spctl_packager" "$accepted_archive" "$fixture_root/spctl-output"

developer_spctl="$fixture_root/developer-spctl"
make_spctl "$developer_spctl" developer-id
developer_spctl_packager="$fixture_root/developer-spctl-packager"
make_packager "$developer_spctl_packager" "$developer_spctl" "$accepted_policy"
record_stage SPCTL_DEVELOPER_ID
assert_closed_failure developer-spctl RELEASE_GATEKEEPER_CLASSIFICATION_MISMATCH \
  "$developer_spctl_packager" "$accepted_archive" "$fixture_root/developer-spctl-output"

for mode in create-failure attach-failure wrong-layout wrong-symlink roundtrip detach-failure; do
  record_stage "DMG_${mode//-/_}"
  output="$fixture_root/$mode-output"
  status=0
  GT_HDIUTIL_MODE="$mode" "$contract_packager" "$accepted_archive" "$output" \
    > "$fixture_root/$mode.stdout" 2> "$fixture_root/$mode.stderr" || status=$?
  test "$status" -ne 0
  case "$mode" in
    create-failure) expected=RELEASE_DMG_CREATE_FAILED ;;
    attach-failure) expected=RELEASE_DMG_ATTACH_FAILED ;;
    wrong-layout) expected=RELEASE_DMG_LAYOUT_INVALID ;;
    wrong-symlink) expected=RELEASE_DMG_SYMLINK_INVALID ;;
    roundtrip) expected=RELEASE_DMG_ROUNDTRIP_MISMATCH ;;
    detach-failure) expected=RELEASE_DMG_DETACH_FAILED ;;
  esac
  test "$(/bin/cat "$fixture_root/$mode.stderr")" = "$expected"
  test ! -s "$fixture_root/$mode.stdout"
  test ! -e "$output"
done

record_stage DMG_MALFORMED_MOUNT
malformed_mount_output="$fixture_root/malformed-mount-output"
malformed_mount_status=0
GT_HDIUTIL_MODE=malformed-mount "$contract_packager" "$accepted_archive" "$malformed_mount_output" \
  > "$fixture_root/malformed-mount.stdout" 2> "$fixture_root/malformed-mount.stderr" \
  || malformed_mount_status=$?
test "$malformed_mount_status" -ne 0
test "$(/bin/cat "$fixture_root/malformed-mount.stderr")" = RELEASE_DMG_ATTACH_FAILED
test ! -s "$fixture_root/malformed-mount.stdout"
test ! -e "$malformed_mount_output"
test "$(/usr/bin/tail -n 1 "$GT_HDIUTIL_LOG")" = /dev/mock-dmg
malformed_mount_path="$(/bin/cat "$GT_HDIUTIL_MOUNTPOINT_FILE")"
test ! -e "$malformed_mount_path"

policy_failure="$fixture_root/policy-failure"
make_policy "$policy_failure" failure
policy_packager="$fixture_root/policy-packager"
make_packager "$policy_packager" "$accepted_spctl" "$policy_failure"
record_stage POLICY_FAILURE
assert_closed_failure policy RELEASE_GATEKEEPER_UNVERIFIABLE \
  "$policy_packager" "$accepted_archive" "$fixture_root/policy-output"

output_copy_tool="$fixture_root/failing-cp"
/usr/bin/printf '%s\n' '#!/usr/bin/env bash' 'exit 9' > "$output_copy_tool"
/bin/chmod 755 "$output_copy_tool"
output_packager="$fixture_root/output-packager"
/usr/bin/sed -e "s#workspace_root=.*#workspace_root='$workspace_root'#" \
  -e "s#/usr/sbin/spctl#$accepted_spctl#g" \
  -e "s#/usr/bin/syspolicy_check#$accepted_policy#g" \
  -e "s#/usr/bin/hdiutil#$hdiutil_stub#g" \
  -e "s#/bin/cp#$output_copy_tool#g" \
  "$packager" > "$output_packager"
/bin/chmod 755 "$output_packager"
record_stage OUTPUT_COPY_FAILURE
assert_closed_failure output-copy RELEASE_DMG_OUTPUT_COPY_FAILED \
  "$output_packager" "$accepted_archive" "$fixture_root/output-copy-output"

record_stage COMPLETE
printf '%s\n' DMG_RELEASE_PACKAGING_TESTS_PASSED
