#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

workspace_root="$(cd "$(dirname "$0")/.." && pwd)"
packager="$workspace_root/script/package_adhoc_release.sh"
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

test -x "$packager"
test -x "$inspector"

record_stage() {
  if [ -n "${GT_AGGREGATE_STAGE_FILE:-}" ]; then
    printf 'ADHOC_RELEASE_PACKAGING_TESTS_%s\n' "$1" \
      > "$GT_AGGREGATE_STAGE_FILE"
  fi
}

make_archive() {
  name="$1"
  version="$2"
  archive="$fixture_root/$name.xcarchive"
  app="$archive/Products/Applications/GlideTranslate.app"
  /bin/mkdir -p "$app/Contents/MacOS" \
    "$app/Contents/Resources/en.lproj" "$archive/dSYMs"
  /usr/bin/clang -arch arm64 -x c -o "$app/Contents/MacOS/GlideTranslate" - <<'EOF'
int main(void) { return 0; }
EOF
  /usr/libexec/PlistBuddy -c Clear \
    -c 'Add :CFBundleIdentifier string com.zaryolabs.GlideTranslate' \
    -c 'Add :CFBundleShortVersionString string '"$version" \
    -c 'Add :CFBundleVersion string 1' \
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

rejecting_spctl="$fixture_root/rejecting-spctl"
printf '%s\n' '#!/usr/bin/env bash' 'exit 3' > "$rejecting_spctl"
/bin/chmod 755 "$rejecting_spctl"
rejecting_policy="$fixture_root/rejecting-policy"
printf '%s\n' '#!/usr/bin/env bash' \
  'printf "%s\n" '\''{"output":[{"SyspolicyCheckErrorLevel":"Warning","SyspolicyCheckShortError":"Adhoc Signed App"},{"SyspolicyCheckErrorLevel":"Fatal","SyspolicyCheckShortError":"Notary Ticket Missing"}]}'\''' \
  'exit 70' > "$rejecting_policy"
/bin/chmod 755 "$rejecting_policy"
contract_packager="$fixture_root/contract-packager"
/usr/bin/sed \
  -e "s#workspace_root=.*#workspace_root='$workspace_root'#" \
  -e "s#/usr/sbin/spctl#$rejecting_spctl#g" \
  -e "s#/usr/bin/syspolicy_check#$rejecting_policy#g" \
  "$packager" > "$contract_packager"
/bin/chmod 755 "$contract_packager"

accepted_archive="$(make_archive accepted 0.1.0)"
accepted_output="$fixture_root/accepted-output"
record_stage ACCEPTED_FIXTURE
accepted_status=0
"$contract_packager" "$accepted_archive" "$accepted_output" \
  > "$fixture_root/accepted.stdout" 2> "$fixture_root/accepted.stderr" \
  || accepted_status=$?
if [ "$accepted_status" -ne 0 ]; then
  accepted_category="$(/bin/cat "$fixture_root/accepted.stderr")"
  case "$accepted_category" in
    RELEASE_SIGNING_*|RELEASE_SIGNATURE_*)
      record_stage ACCEPTED_FIXTURE_SIGNATURE
      ;;
    RELEASE_ENTITLEMENTS_*)
      record_stage ACCEPTED_FIXTURE_ENTITLEMENTS
      ;;
    RELEASE_GATEKEEPER_*)
      record_stage ACCEPTED_FIXTURE_GATEKEEPER
      ;;
    RELEASE_PAYLOAD_*|RELEASE_ARCHIVE_MANIFEST_*)
      record_stage ACCEPTED_FIXTURE_PAYLOAD
      ;;
    RELEASE_ARCHIVE_*|RELEASE_OUTPUT_*)
      record_stage ACCEPTED_FIXTURE_ARCHIVE
      ;;
    RELEASE_CHECKSUM_*)
      record_stage ACCEPTED_FIXTURE_CHECKSUM
      ;;
    *)
      record_stage ACCEPTED_FIXTURE_UNKNOWN
      ;;
  esac
  exit "$accepted_status"
fi
test "$(/bin/cat "$fixture_root/accepted.stdout")" = ADHOC_RELEASE_PACKAGE_PASSED
test ! -s "$fixture_root/accepted.stderr"

artifact_name=GlideTranslate-0.1.0-macos-arm64.zip
checksum_name="$artifact_name.sha256"
test -f "$accepted_output/$artifact_name"
test -f "$accepted_output/$checksum_name"
test "$(/usr/bin/find "$accepted_output" -type f | /usr/bin/wc -l | /usr/bin/tr -d ' ')" -eq 2
rg -q "^[0-9a-f]{64}  ${artifact_name}$" "$accepted_output/$checksum_name"
(
  cd "$accepted_output"
  /usr/bin/shasum -a 256 -c "$checksum_name" >/dev/null
)

extracted="$fixture_root/extracted"
/bin/mkdir "$extracted"
/usr/bin/ditto -x -k "$accepted_output/$artifact_name" "$extracted"
app="$extracted/GlideTranslate.app"
test -d "$app"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
  "$app/Contents/Info.plist")" = 0.1.0
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' \
  "$app/Contents/Info.plist")" = 1
test "$(/usr/bin/lipo -archs "$app/Contents/MacOS/GlideTranslate")" = arm64
/usr/bin/codesign --verify --deep --strict "$app"
/usr/bin/codesign -dvvv "$app" > /dev/null \
  2> "$fixture_root/codesign-details.private"
rg -q '^Identifier=com[.]zaryolabs[.]GlideTranslate$' \
  "$fixture_root/codesign-details.private"
rg -q '^Signature=adhoc$' "$fixture_root/codesign-details.private"
rg -q '^TeamIdentifier=not set$' "$fixture_root/codesign-details.private"
rg -q '^CodeDirectory .*flags=.*runtime' \
  "$fixture_root/codesign-details.private"
if rg -q '^Authority=' "$fixture_root/codesign-details.private"; then
  exit 1
fi
/usr/bin/codesign -d --entitlements :- "$app" \
  > "$fixture_root/entitlements.plist" 2> "$fixture_root/entitlements.private"
/usr/bin/plutil -convert binary1 -o "$fixture_root/entitlements.binary" \
  "$fixture_root/entitlements.plist"
/usr/bin/plutil -convert binary1 \
  -o "$fixture_root/approved-entitlements.binary" \
  "$workspace_root/App/GlideTranslate/GlideTranslate.entitlements"
/usr/bin/cmp -s "$fixture_root/entitlements.binary" \
  "$fixture_root/approved-entitlements.binary"
spctl_status=0
"$rejecting_spctl" -a -t exec "$app" >/dev/null 2>&1 || spctl_status=$?
test "$spctl_status" -eq 3
GT_APPROVED_BUNDLE_ID=com.zaryolabs.GlideTranslate \
  "$inspector" "$extracted" "$fixture_root/extracted-inspection"
rg -q '^PAYLOAD_INSPECTION:PASS$' \
  "$fixture_root/extracted-inspection/inspection.txt"

existing_output="$fixture_root/existing-output"
/bin/mkdir "$existing_output"
record_stage EXISTING_OUTPUT
assert_closed_failure existing RELEASE_OUTPUT_EXISTS \
  "$packager" "$accepted_archive" "$existing_output"

wrong_version="$(make_archive wrong-version 1.0)"
record_stage WRONG_VERSION
assert_closed_failure wrong-version RELEASE_VERSION_MISMATCH \
  "$packager" "$wrong_version" "$fixture_root/wrong-version-output"

wrong_build="$(make_archive wrong-build 0.1.0)"
/usr/libexec/PlistBuddy -c 'Set :CFBundleVersion 2' \
  "$wrong_build/Products/Applications/GlideTranslate.app/Contents/Info.plist"
record_stage WRONG_BUILD
assert_closed_failure wrong-build RELEASE_BUILD_MISMATCH \
  "$packager" "$wrong_build" "$fixture_root/wrong-build-output"

wrong_architecture="$(make_archive wrong-architecture 0.1.0)"
/usr/bin/clang -arch x86_64 -x c \
  -o "$wrong_architecture/Products/Applications/GlideTranslate.app/Contents/MacOS/GlideTranslate" - <<'EOF'
int main(void) { return 0; }
EOF
record_stage WRONG_ARCHITECTURE
assert_closed_failure wrong-architecture RELEASE_PAYLOAD_INSPECTION_FAILED \
  "$packager" "$wrong_architecture" \
  "$fixture_root/wrong-architecture-output"

missing_layout="$fixture_root/missing-layout.xcarchive"
/bin/mkdir "$missing_layout"
record_stage MISSING_LAYOUT
assert_closed_failure missing-layout RELEASE_ARCHIVE_LAYOUT_INVALID \
  "$packager" "$missing_layout" "$fixture_root/missing-layout-output"

extra_payload="$(make_archive extra-payload 0.1.0)"
/bin/mkdir -p "$extra_payload/Products/Applications/Other.app/Contents"
printf '%s\n' unrelated \
  > "$extra_payload/Products/Applications/Other.app/Contents/Info.plist"
record_stage EXTRA_PAYLOAD
assert_closed_failure extra-payload RELEASE_PAYLOAD_INSPECTION_FAILED \
  "$packager" "$extra_payload" "$fixture_root/extra-payload-output"

signing_tool="$fixture_root/failing-codesign"
printf '%s\n' '#!/usr/bin/env bash' 'exit 9' > "$signing_tool"
/bin/chmod 755 "$signing_tool"
injected_packager="$fixture_root/injected-packager"
/usr/bin/sed \
  -e "s#workspace_root=.*#workspace_root='$workspace_root'#" \
  -e "s#/usr/bin/codesign#$signing_tool#g" \
  "$packager" > "$injected_packager"
/bin/chmod 755 "$injected_packager"
record_stage SIGNING_FAILURE
assert_closed_failure signing RELEASE_SIGNING_FAILED \
  "$injected_packager" "$accepted_archive" "$fixture_root/signing-output"

classification_tool="$fixture_root/classification-codesign"
printf '%s\n' '#!/usr/bin/env bash' \
  'if [ "$1" = -dvvv ]; then' \
  '  printf "%s\n" "Identifier=com.zaryolabs.GlideTranslate" "CodeDirectory v=20500 flags=0x10002(adhoc,runtime)" "Signature=adhoc" "TeamIdentifier=unexpected" >&2' \
  '  exit 0' \
  'fi' \
  'exec /usr/bin/codesign "$@"' > "$classification_tool"
/bin/chmod 755 "$classification_tool"
classification_packager="$fixture_root/classification-packager"
/usr/bin/sed \
  -e "s#workspace_root=.*#workspace_root='$workspace_root'#" \
  -e "s#/usr/bin/codesign#$classification_tool#g" \
  "$packager" > "$classification_packager"
/bin/chmod 755 "$classification_packager"
record_stage SIGNATURE_CLASSIFICATION
assert_closed_failure classification RELEASE_SIGNATURE_CLASSIFICATION_MISMATCH \
  "$classification_packager" "$accepted_archive" \
  "$fixture_root/classification-output"

entitlements_tool="$fixture_root/entitlements-codesign"
printf '%s\n' '#!/usr/bin/env bash' \
  'if [ "$1" = -d ] && [ "$2" = --entitlements ]; then' \
  '  printf "%s\n" "<?xml version=\"1.0\" encoding=\"UTF-8\"?>" "<plist version=\"1.0\"><dict><key>unexpected</key><true/></dict></plist>"' \
  '  exit 0' \
  'fi' \
  'exec /usr/bin/codesign "$@"' > "$entitlements_tool"
/bin/chmod 755 "$entitlements_tool"
entitlements_packager="$fixture_root/entitlements-packager"
/usr/bin/sed \
  -e "s#workspace_root=.*#workspace_root='$workspace_root'#" \
  -e "s#/usr/bin/codesign#$entitlements_tool#g" \
  "$packager" > "$entitlements_packager"
/bin/chmod 755 "$entitlements_packager"
record_stage ENTITLEMENTS
assert_closed_failure entitlements RELEASE_ENTITLEMENTS_MISMATCH \
  "$entitlements_packager" "$accepted_archive" \
  "$fixture_root/entitlements-output"

spctl_tool="$fixture_root/failing-spctl"
printf '%s\n' '#!/usr/bin/env bash' 'exit 9' > "$spctl_tool"
/bin/chmod 755 "$spctl_tool"
spctl_packager="$fixture_root/spctl-packager"
/usr/bin/sed \
  -e "s#workspace_root=.*#workspace_root='$workspace_root'#" \
  -e "s#/usr/sbin/spctl#$spctl_tool#g" \
  "$packager" > "$spctl_packager"
/bin/chmod 755 "$spctl_packager"
record_stage SPCTL_FAILURE
assert_closed_failure spctl RELEASE_GATEKEEPER_UNVERIFIABLE \
  "$spctl_packager" "$accepted_archive" "$fixture_root/spctl-output"

accepted_spctl="$fixture_root/accepted-spctl"
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$accepted_spctl"
/bin/chmod 755 "$accepted_spctl"
accepted_spctl_packager="$fixture_root/accepted-spctl-packager"
/usr/bin/sed \
  -e "s#workspace_root=.*#workspace_root='$workspace_root'#" \
  -e "s#/usr/sbin/spctl#$accepted_spctl#g" \
  "$packager" > "$accepted_spctl_packager"
/bin/chmod 755 "$accepted_spctl_packager"
record_stage SPCTL_ACCEPTED
assert_closed_failure accepted-spctl RELEASE_GATEKEEPER_CLASSIFICATION_MISMATCH \
  "$accepted_spctl_packager" "$accepted_archive" \
  "$fixture_root/accepted-spctl-output"

roundtrip_tool="$fixture_root/roundtrip-ditto"
printf '%s\n' '#!/usr/bin/env bash' \
  '/usr/bin/ditto "$@" || exit $?' \
  'if [ "$1" = -x ]; then' \
  '  /bin/chmod 644 "$4/GlideTranslate.app/Contents/MacOS/GlideTranslate"' \
  'fi' > "$roundtrip_tool"
/bin/chmod 755 "$roundtrip_tool"
roundtrip_packager="$fixture_root/roundtrip-packager"
/usr/bin/sed \
  -e "s#workspace_root=.*#workspace_root='$workspace_root'#" \
  -e "s#/usr/bin/ditto#$roundtrip_tool#g" \
  "$contract_packager" > "$roundtrip_packager"
/bin/chmod 755 "$roundtrip_packager"
record_stage ROUNDTRIP
assert_closed_failure roundtrip RELEASE_ARCHIVE_ROUNDTRIP_MISMATCH \
  "$roundtrip_packager" "$accepted_archive" "$fixture_root/roundtrip-output"

policy_tool="$fixture_root/unrelated-policy"
printf '%s\n' '#!/usr/bin/env bash' \
  'printf "%s\n" '\''{"output":[{"SyspolicyCheckErrorLevel":"Fatal","SyspolicyCheckShortError":"Unrelated Policy Denial"}]}'\''' \
  'exit 70' > "$policy_tool"
/bin/chmod 755 "$policy_tool"
policy_packager="$fixture_root/policy-packager"
/usr/bin/sed \
  -e "s#workspace_root=.*#workspace_root='$workspace_root'#" \
  -e "s#/usr/sbin/spctl#$rejecting_spctl#g" \
  -e "s#/usr/bin/syspolicy_check#$policy_tool#g" \
  "$packager" > "$policy_packager"
/bin/chmod 755 "$policy_packager"
record_stage POLICY_CLASSIFICATION
assert_closed_failure policy RELEASE_GATEKEEPER_CLASSIFICATION_MISMATCH \
  "$policy_packager" "$accepted_archive" "$fixture_root/policy-output"

zip_tool="$fixture_root/failing-zip-ditto"
printf '%s\n' '#!/usr/bin/env bash' \
  'if [ "$1" = -c ]; then exit 9; fi' \
  'exec /usr/bin/ditto "$@"' > "$zip_tool"
/bin/chmod 755 "$zip_tool"
zip_packager="$fixture_root/zip-packager"
/usr/bin/sed \
  -e "s#workspace_root=.*#workspace_root='$workspace_root'#" \
  -e "s#/usr/bin/ditto#$zip_tool#g" \
  "$contract_packager" > "$zip_packager"
/bin/chmod 755 "$zip_packager"
record_stage ZIP_FAILURE
assert_closed_failure zip RELEASE_ARCHIVE_CREATION_FAILED \
  "$zip_packager" "$accepted_archive" "$fixture_root/zip-output"
test ! -e "$fixture_root/zip-output"

unzip_tool="$fixture_root/failing-unzip-ditto"
printf '%s\n' '#!/usr/bin/env bash' \
  'if [ "$1" = -x ]; then exit 9; fi' \
  'exec /usr/bin/ditto "$@"' > "$unzip_tool"
/bin/chmod 755 "$unzip_tool"
unzip_packager="$fixture_root/unzip-packager"
/usr/bin/sed \
  -e "s#workspace_root=.*#workspace_root='$workspace_root'#" \
  -e "s#/usr/bin/ditto#$unzip_tool#g" \
  "$contract_packager" > "$unzip_packager"
/bin/chmod 755 "$unzip_packager"
record_stage UNZIP_FAILURE
assert_closed_failure unzip RELEASE_ARCHIVE_EXTRACTION_FAILED \
  "$unzip_packager" "$accepted_archive" "$fixture_root/unzip-output"
test ! -e "$fixture_root/unzip-output"

checksum_tool="$fixture_root/failing-checksum"
printf '%s\n' '#!/usr/bin/env bash' \
  'last="${!#}"' \
  'if [ "$last" = GlideTranslate-0.1.0-macos-arm64.zip ]; then exit 9; fi' \
  'exec /usr/bin/shasum "$@"' > "$checksum_tool"
/bin/chmod 755 "$checksum_tool"
checksum_packager="$fixture_root/checksum-packager"
/usr/bin/sed \
  -e "s#workspace_root=.*#workspace_root='$workspace_root'#" \
  -e "s#/usr/bin/shasum#$checksum_tool#g" \
  "$contract_packager" > "$checksum_packager"
/bin/chmod 755 "$checksum_packager"
checksum_output="$fixture_root/checksum-output"
record_stage CHECKSUM_FAILURE
assert_closed_failure checksum RELEASE_CHECKSUM_UNVERIFIABLE \
  "$checksum_packager" "$accepted_archive" "$checksum_output"
test ! -e "$checksum_output"

record_stage COMPLETE
printf '%s\n' ADHOC_RELEASE_PACKAGING_TESTS_PASSED
