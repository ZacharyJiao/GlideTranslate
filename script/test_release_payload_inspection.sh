#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

workspace_root="$(cd "$(dirname "$0")/.." && pwd)"
inspector="$workspace_root/script/inspect_release_payload.sh"
builder="$workspace_root/script/build_release_archive.sh"
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

test -x "$inspector"
test -x "$builder"

make_archive() {
  name="$1"
  archive="$fixture_root/$name.xcarchive"
  app="$archive/Products/Applications/GlideTranslate.app"
  /bin/mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/en.lproj"
  /bin/mkdir -p "$archive/dSYMs"
  /usr/bin/clang -arch arm64 -x c -o "$app/Contents/MacOS/GlideTranslate" - <<'EOF'
int main(void) { return 0; }
EOF
  /usr/libexec/PlistBuddy -c Clear -c 'Add :CFBundleIdentifier string com.zaryolabs.GlideTranslate' \
    -c 'Add :LSMinimumSystemVersion string 14.0' -c 'Add :LSUIElement bool true' \
    "$app/Contents/Info.plist" >/dev/null
  printf '%s\n' 'safe localized resource' > "$app/Contents/Resources/en.lproj/Localizable.strings"
  printf 'icns\000\000\000\010' > "$app/Contents/Resources/AppIcon.icns"
  printf 'BOMStore' > "$app/Contents/Resources/Assets.car"
  printf '%s\n' 'safe archive metadata' > "$archive/Info.plist"
  printf '%s\n' "$archive"
}

assert_rejected() {
  name="$1"
  category="$2"
  input="$3"
  output="$fixture_root/$name-output"
  probe_status=0
  GT_APPROVED_BUNDLE_ID=com.zaryolabs.GlideTranslate \
    "$inspector" "$input" "$output" > "$fixture_root/$name.stdout" \
    2> "$fixture_root/$name.stderr" || probe_status=$?
  test "$probe_status" -ne 0
  rg -q "^${category}(:|$)" "$fixture_root/$name.stderr"
  test ! -s "$fixture_root/$name.stdout"
  test -d "$output/private-strings"
}

accepted="$(make_archive accepted)"
GT_APPROVED_BUNDLE_ID=com.zaryolabs.GlideTranslate \
  "$inspector" "$accepted" "$fixture_root/accepted-output"
test -f "$fixture_root/accepted-output/inspection.txt"
test ! -e "$fixture_root/accepted-output/private-strings"
rg -q '^PAYLOAD_INSPECTION:PASS$' "$fixture_root/accepted-output/inspection.txt"

extracted="$fixture_root/extracted"
/bin/mkdir -p "$extracted"
/bin/cp -R "$accepted/Products/Applications/GlideTranslate.app" \
  "$extracted/GlideTranslate.app"
GT_APPROVED_BUNDLE_ID=com.zaryolabs.GlideTranslate \
  "$inspector" "$extracted" "$fixture_root/extracted-output"
rg -q '^PAYLOAD_INSPECTION:PASS$' \
  "$fixture_root/extracted-output/inspection.txt"

signed_extracted="$fixture_root/signed-extracted"
/bin/cp -R "$extracted" "$signed_extracted"
/usr/bin/codesign --force --deep --sign - --options runtime \
  "$signed_extracted/GlideTranslate.app" >/dev/null 2>&1
GT_APPROVED_BUNDLE_ID=com.zaryolabs.GlideTranslate \
  "$inspector" "$signed_extracted" "$fixture_root/signed-extracted-output"
rg -q '^PAYLOAD_INSPECTION:PASS$' \
  "$fixture_root/signed-extracted-output/inspection.txt"

signed_extra="$fixture_root/signed-extra"
/bin/cp -R "$signed_extracted" "$signed_extra"
printf '%s\n' unexpected \
  > "$signed_extra/GlideTranslate.app/Contents/_CodeSignature/Unexpected"
assert_rejected signed-extra UNEXPECTED_PAYLOAD_PATH "$signed_extra"

extracted_empty_directory="$fixture_root/extracted-empty-directory"
/bin/cp -R "$extracted" "$extracted_empty_directory"
/bin/mkdir \
  "$extracted_empty_directory/GlideTranslate.app/Contents/Unexpected"
assert_rejected extracted-empty-directory UNEXPECTED_PAYLOAD_PATH \
  "$extracted_empty_directory"

archive_empty_directory="$(make_archive archive-empty-directory)"
/bin/mkdir "$archive_empty_directory/Unexpected"
assert_rejected archive-empty-directory UNEXPECTED_PAYLOAD_PATH \
  "$archive_empty_directory"

extracted_extra="$fixture_root/extracted-extra"
/bin/cp -R "$extracted" "$extracted_extra"
printf '%s\n' unrelated > "$extracted_extra/GlideTranslate.app/Contents/Resources/extra.txt"
assert_rejected extracted-extra UNEXPECTED_PAYLOAD_PATH "$extracted_extra"

extracted_other_app="$fixture_root/extracted-other-app"
/bin/cp -R "$extracted" "$extracted_other_app"
/bin/mkdir -p "$extracted_other_app/Other.app/Contents"
printf '%s\n' unrelated > "$extracted_other_app/Other.app/Contents/Info.plist"
assert_rejected extracted-other-app UNEXPECTED_PAYLOAD_PATH \
  "$extracted_other_app"

archive_with_root_app="$(make_archive archive-with-root-app)"
/bin/cp -R "$archive_with_root_app/Products/Applications/GlideTranslate.app" \
  "$archive_with_root_app/GlideTranslate.app"
assert_rejected archive-with-root-app ARCHIVE_LAYOUT_AMBIGUOUS \
  "$archive_with_root_app"

extracted_with_archive_app="$fixture_root/extracted-with-archive-app"
/bin/cp -R "$extracted" "$extracted_with_archive_app"
/bin/mkdir -p "$extracted_with_archive_app/Products/Applications"
/bin/cp -R "$extracted_with_archive_app/GlideTranslate.app" \
  "$extracted_with_archive_app/Products/Applications/GlideTranslate.app"
assert_rejected extracted-with-archive-app ARCHIVE_LAYOUT_AMBIGUOUS \
  "$extracted_with_archive_app"

bundle_mismatch="$(make_archive bundle-mismatch)"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier invalid.example' \
  "$bundle_mismatch/Products/Applications/GlideTranslate.app/Contents/Info.plist"
assert_rejected bundle-mismatch ARCHIVE_BUNDLE_ID_MISMATCH "$bundle_mismatch"

bundle_missing="$(make_archive bundle-missing)"
/usr/libexec/PlistBuddy -c 'Delete :CFBundleIdentifier' \
  "$bundle_missing/Products/Applications/GlideTranslate.app/Contents/Info.plist"
assert_rejected bundle-missing ARCHIVE_BUNDLE_ID_MISMATCH "$bundle_missing"

minimum_mismatch="$(make_archive minimum-mismatch)"
/usr/libexec/PlistBuddy -c 'Set :LSMinimumSystemVersion 13.0' \
  "$minimum_mismatch/Products/Applications/GlideTranslate.app/Contents/Info.plist"
assert_rejected minimum-mismatch ARCHIVE_MINIMUM_OS_MISMATCH "$minimum_mismatch"

minimum_missing="$(make_archive minimum-missing)"
/usr/libexec/PlistBuddy -c 'Delete :LSMinimumSystemVersion' \
  "$minimum_missing/Products/Applications/GlideTranslate.app/Contents/Info.plist"
assert_rejected minimum-missing ARCHIVE_MINIMUM_OS_MISMATCH "$minimum_missing"

accessory_missing="$(make_archive accessory-missing)"
/usr/libexec/PlistBuddy -c 'Delete :LSUIElement' \
  "$accessory_missing/Products/Applications/GlideTranslate.app/Contents/Info.plist"
assert_rejected accessory-missing ARCHIVE_ACCESSORY_BEHAVIOR_MISMATCH \
  "$accessory_missing"

accessory_false="$(make_archive accessory-false)"
/usr/libexec/PlistBuddy -c 'Set :LSUIElement false' \
  "$accessory_false/Products/Applications/GlideTranslate.app/Contents/Info.plist"
assert_rejected accessory-false ARCHIVE_ACCESSORY_BEHAVIOR_MISMATCH \
  "$accessory_false"

missing_input_status=0
"$inspector" "$accepted" "$fixture_root/missing-input-output" \
  > "$fixture_root/missing-input.stdout" 2> "$fixture_root/missing-input.stderr" \
  || missing_input_status=$?
test "$missing_input_status" -eq 1
test "$(/bin/cat "$fixture_root/missing-input.stderr")" = ARCHIVE_BUNDLE_ID_MISMATCH

architecture_mismatch="$(make_archive architecture-mismatch)"
/usr/bin/clang -arch x86_64 -x c \
  -o "$architecture_mismatch/Products/Applications/GlideTranslate.app/Contents/MacOS/GlideTranslate" - <<'EOF'
int main(void) { return 0; }
EOF
assert_rejected architecture-mismatch ARCHIVE_ARCHITECTURE_MISMATCH \
  "$architecture_mismatch"

secondary_architecture="$(make_archive secondary-architecture)"
/bin/mkdir -p "$secondary_architecture/dSYMs/GlideTranslate.app.dSYM/Contents/Resources/DWARF"
/usr/bin/clang -arch x86_64 -x c \
  -o "$secondary_architecture/dSYMs/GlideTranslate.app.dSYM/Contents/Resources/DWARF/GlideTranslate" - <<'EOF'
int main(void) { return 0; }
EOF
assert_rejected secondary-architecture ARCHIVE_MACHO_ARCH_MISMATCH \
  "$secondary_architecture"

arbitrary_data="$(make_archive arbitrary-data)"
printf '\000\001\002\003' > "$arbitrary_data/Products/Applications/GlideTranslate.app/Contents/Resources/arbitrary.bin"
assert_rejected arbitrary-data UNEXPECTED_PAYLOAD_PATH "$arbitrary_data"

extra_app="$(make_archive extra-app)"
/bin/mkdir -p "$extra_app/Products/Applications/Other.app/Contents"
printf '%s\n' unrelated > "$extra_app/Products/Applications/Other.app/Contents/Info.plist"
assert_rejected extra-app UNEXPECTED_PAYLOAD_PATH "$extra_app"

user_path="$(make_archive user-path)"
user_marker='/'"Users/private-user/project"
printf '%s\n' "$user_marker" > "$user_path/Products/Applications/GlideTranslate.app/Contents/Resources/bad.txt"
assert_rejected user-path PROHIBITED_USER_PATH "$user_path"
test "$(/bin/cat "$fixture_root/user-path.stderr")" != *private-user*

agent_path="$(make_archive agent-path)"
/bin/mkdir -p "$agent_path/Products/Applications/GlideTranslate.app/Contents/Resources/.codex"
printf '%s\n' private > "$agent_path/Products/Applications/GlideTranslate.app/Contents/Resources/.codex/state"
assert_rejected agent-path PROHIBITED_AGENT_PATH "$agent_path"

private_endpoint="$(make_archive private-endpoint)"
printf -v private_ipv4 '%s.%s.%s.%s' 192 168 1 9
printf 'http://%s/private\n' "$private_ipv4" > "$private_endpoint/Products/Applications/GlideTranslate.app/Contents/Resources/endpoint.txt"
assert_rejected private-endpoint PROHIBITED_PRIVATE_ENDPOINT "$private_endpoint"
test "$(/bin/cat "$fixture_root/private-endpoint.stderr")" != *192.168.1.9*

credential="$(make_archive credential)"
printf '%s\n' secret > "$credential/Products/Applications/GlideTranslate.app/Contents/Resources/export.p12"
assert_rejected credential PROHIBITED_CREDENTIAL_FILE "$credential"

runtime_state="$(make_archive runtime-state)"
printf '%s\n' state > "$runtime_state/Products/Applications/GlideTranslate.app/Contents/Resources/history.sqlite"
assert_rejected runtime-state PROHIBITED_RUNTIME_STATE "$runtime_state"

model_cache="$(make_archive model-cache)"
/bin/mkdir -p "$model_cache/Products/Applications/GlideTranslate.app/Contents/Resources/model-cache"
printf '%s\n' weights > "$model_cache/Products/Applications/GlideTranslate.app/Contents/Resources/model-cache/data.bin"
assert_rejected model-cache PROHIBITED_MODEL_CACHE "$model_cache"

build_path="$(make_archive build-path)"
printf '%s\n' '/private/var/folders/example/DerivedData/Build' > "$build_path/Products/Applications/GlideTranslate.app/Contents/Resources/build.txt"
assert_rejected build-path PROHIBITED_BUILD_PATH "$build_path"

oversized="$(make_archive oversized)"
/usr/bin/truncate -s 67108865 "$oversized/Products/Applications/GlideTranslate.app/Contents/Resources/large.bin"
assert_rejected oversized OVERSIZED_PAYLOAD "$oversized"

symlink="$(make_archive symlink)"
/bin/ln -s Info.plist "$symlink/linked-plist"
assert_rejected symlink PROHIBITED_SYMLINK "$symlink"

compiled_marker="$fixture_root/compiled-marker.c"
printf -v compiled_ipv4 '%s.%s.%s.%s' 10 9 8 7
printf 'const char *marker = "http://%s/private"; int main(void) { return marker[0]; }\n' \
  "$compiled_ipv4" > "$compiled_marker"
compiled_archive="$(make_archive compiled-marker)"
/usr/bin/clang -arch arm64 "$compiled_marker" -o "$compiled_archive/Products/Applications/GlideTranslate.app/Contents/MacOS/GlideTranslate"
assert_rejected compiled-marker PROHIBITED_PRIVATE_ENDPOINT "$compiled_archive"
test "$(/bin/cat "$fixture_root/compiled-marker.stderr")" != *10.9.8.7*

unsupported="$(make_archive unsupported)"
printf '%s\n' nested > "$fixture_root/nested-source.txt"
/usr/bin/ditto -c -k "$fixture_root/nested-source.txt" \
  "$unsupported/Products/Applications/GlideTranslate.app/Contents/Resources/nested.zip"
assert_rejected unsupported UNVERIFIABLE_PAYLOAD_TYPE "$unsupported"

assert_absolute_tool_failure() {
  name="$1"
  tool_path="$2"
  expected="$3"
  injected="$fixture_root/$name-inspector"
  wrapper="$fixture_root/$name-tool"
  printf '%s\n' '#!/usr/bin/env bash' \
    'printf "%s\n" INJECTED_PRIVATE_DIAGNOSTIC >&2' 'exit 9' > "$wrapper"
  /bin/chmod 755 "$wrapper"
  /usr/bin/sed "s#${tool_path}#${wrapper}#g" "$inspector" > "$injected"
  /bin/chmod 755 "$injected"
  probe_status=0
  GT_APPROVED_BUNDLE_ID=com.zaryolabs.GlideTranslate \
    "$injected" "$accepted" "$fixture_root/$name-output" \
    > "$fixture_root/$name.stdout" 2> "$fixture_root/$name.stderr" \
    || probe_status=$?
  test "$probe_status" -ne 0
  test "$(/bin/cat "$fixture_root/$name.stderr")" = "$expected"
  ! rg -q 'INJECTED_PRIVATE_DIAGNOSTIC' "$fixture_root/$name.stderr"
}

assert_absolute_tool_failure find /usr/bin/find UNVERIFIABLE_ARCHIVE_INVENTORY
assert_absolute_tool_failure sort /usr/bin/sort \
  UNVERIFIABLE_ARCHIVE_INVENTORY:app
assert_absolute_tool_failure file /usr/bin/file UNVERIFIABLE_PAYLOAD_TYPE
assert_absolute_tool_failure lipo /usr/bin/lipo UNVERIFIABLE_MACHO_ARCH
assert_absolute_tool_failure otool /usr/bin/otool UNVERIFIABLE_MACHO_LINKAGE
assert_absolute_tool_failure strings /usr/bin/strings UNVERIFIABLE_PAYLOAD_STRINGS

linkage_inspector="$fixture_root/linkage-inspector"
linkage_tool="$fixture_root/linkage-tool"
printf '%s\n' '#!/usr/bin/env bash' \
  'printf "%s:\n" "$2"' \
  'printf "\t/opt/homebrew/lib/libInjected.dylib (compatibility version 1.0.0, current version 1.0.0)\n"' \
  > "$linkage_tool"
/bin/chmod 755 "$linkage_tool"
/usr/bin/sed "s#/usr/bin/otool#${linkage_tool}#g" "$inspector" \
  > "$linkage_inspector"
/bin/chmod 755 "$linkage_inspector"
probe_status=0
GT_APPROVED_BUNDLE_ID=com.zaryolabs.GlideTranslate \
  "$linkage_inspector" "$accepted" "$fixture_root/linkage-output" \
  > "$fixture_root/linkage.stdout" 2> "$fixture_root/linkage.stderr" \
  || probe_status=$?
test "$probe_status" -eq 1
rg -q '^ARCHIVE_LINKAGE_UNAPPROVED:' "$fixture_root/linkage.stderr"

assert_path_tool_failure() {
  name="$1"
  tool="$2"
  expected="$3"
  fake_bin="$fixture_root/$name-bin"
  /bin/mkdir -p "$fake_bin"
  printf '%s\n' '#!/usr/bin/env bash' \
    'printf "%s\n" INJECTED_PRIVATE_DIAGNOSTIC >&2' 'exit 9' \
    > "$fake_bin/$tool"
  /bin/chmod 755 "$fake_bin/$tool"
  probe_status=0
  PATH="$fake_bin:$PATH" GT_APPROVED_BUNDLE_ID=com.zaryolabs.GlideTranslate \
    "$inspector" "$accepted" "$fixture_root/$name-output" \
    > "$fixture_root/$name.stdout" 2> "$fixture_root/$name.stderr" \
    || probe_status=$?
  test "$probe_status" -eq 2
  test "$(/bin/cat "$fixture_root/$name.stderr")" = "$expected"
  ! rg -q 'INJECTED_PRIVATE_DIAGNOSTIC' "$fixture_root/$name.stderr"
}

assert_path_tool_failure rg rg UNVERIFIABLE_PAYLOAD_SCAN
assert_path_tool_failure gitleaks gitleaks UNVERIFIABLE_SECRET_SCAN

assert_gitleaks_report() {
  name="$1"
  report_content="$2"
  expected="$3"
  fake_bin="$fixture_root/gitleaks-$name-bin"
  /bin/mkdir -p "$fake_bin"
  printf '%s\n' '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    'report=""' \
    'while [ "$#" -gt 0 ]; do' \
    '  case "$1" in --report-path) report="$2"; shift 2 ;; *) shift ;; esac' \
    'done' \
    'printf "%s\n" "${GT_FAKE_GITLEAKS_REPORT:?}" > "$report"' \
    'exit 0' > "$fake_bin/gitleaks"
  /bin/chmod 755 "$fake_bin/gitleaks"
  probe_status=0
  PATH="$fake_bin:$PATH" GT_FAKE_GITLEAKS_REPORT="$report_content" \
    GT_APPROVED_BUNDLE_ID=com.zaryolabs.GlideTranslate \
    "$inspector" "$accepted" "$fixture_root/gitleaks-$name-output" \
    > "$fixture_root/gitleaks-$name.stdout" \
    2> "$fixture_root/gitleaks-$name.stderr" || probe_status=$?
  test "$probe_status" -ne 0
  rg -q "^${expected}(:|$)" "$fixture_root/gitleaks-$name.stderr"
}

assert_gitleaks_report finding '[{"RuleID":"synthetic"}]' \
  PROHIBITED_SECRET_SCAN
assert_gitleaks_report malformed '{' UNVERIFIABLE_SECRET_SCAN
assert_gitleaks_report multidoc $'[]\n[]' UNVERIFIABLE_SECRET_SCAN

make_fake_developer_dir() {
  name="$1"
  mode="$2"
  fake="$fixture_root/$name-developer"
  /bin/mkdir -p "$fake/usr/bin"
  printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail' > "$fake/usr/bin/xcodebuild"
  case "$mode" in
    producer-failure)
      printf '%s\n' 'printf "%s\n" "/private/diagnostic" >&2' 'exit 7' >> "$fake/usr/bin/xcodebuild"
      ;;
    *)
      printf '%s\n' \
        'if printf "%s\n" "$*" | /usr/bin/grep -q -- -showBuildSettings; then' \
        "  printf '%s\\n' '$mode'" \
        '  exit 0' \
        'fi' \
        'archive_path=""; result_path=""' \
        'while [ "$#" -gt 0 ]; do' \
        '  case "$1" in -archivePath) archive_path="$2"; shift 2 ;; -resultBundlePath) result_path="$2"; shift 2 ;; *) shift ;; esac' \
        'done' \
        '/bin/mkdir -p "$archive_path/Products/Applications/GlideTranslate.app" "$result_path"' \
        'exit 0' >> "$fake/usr/bin/xcodebuild"
      ;;
  esac
  /bin/chmod 755 "$fake/usr/bin/xcodebuild"
  printf '%s\n' "$fake"
}

valid_json='[{"buildSettings":{"MACOSX_DEPLOYMENT_TARGET":"14.0","ENABLE_APP_SANDBOX":"NO","ENABLE_HARDENED_RUNTIME":"YES"}}]'
for row in \
  'malformed:{' \
  'empty:[]' \
  'missing:[{"buildSettings":{}}]' \
  'mismatch:[{"buildSettings":{"MACOSX_DEPLOYMENT_TARGET":"13.0","ENABLE_APP_SANDBOX":"NO","ENABLE_HARDENED_RUNTIME":"YES"}}]'; do
  name="${row%%:*}"
  json="${row#*:}"
  fake="$(make_fake_developer_dir "$name" "$json")"
  probe_status=0
  DEVELOPER_DIR="$fake" "$builder" "$fixture_root/$name-build" \
    > "$fixture_root/$name-build.stdout" 2> "$fixture_root/$name-build.stderr" || probe_status=$?
  test "$probe_status" -eq 1
  test "$(/bin/cat "$fixture_root/$name-build.stderr")" = ARCHIVE_SETTING_MISMATCH
done

fake="$(make_fake_developer_dir producer producer-failure)"
probe_status=0
DEVELOPER_DIR="$fake" "$builder" "$fixture_root/producer-build" \
  > "$fixture_root/producer.stdout" 2> "$fixture_root/producer.stderr" || probe_status=$?
test "$probe_status" -eq 2
test "$(/bin/cat "$fixture_root/producer.stderr")" = ARCHIVE_SETTING_ENUMERATION_FAILED

fake="$(make_fake_developer_dir valid "$valid_json")"
DEVELOPER_DIR="$fake" "$builder" "$fixture_root/valid-build"
test -d "$fixture_root/valid-build/GlideTranslate-arm64.xcarchive"
test -d "$fixture_root/valid-build/Archive.xcresult"

reuse_root="$fixture_root/reuse-build"
/bin/mkdir -p "$reuse_root"
printf '%s\n' retained > "$reuse_root/settings-sentinel"
reuse_status=0
DEVELOPER_DIR="$fake" "$builder" "$reuse_root" \
  > "$fixture_root/reuse.stdout" 2> "$fixture_root/reuse.stderr" \
  || reuse_status=$?
test "$reuse_status" -eq 1
test "$(/bin/cat "$fixture_root/reuse.stderr")" = ARCHIVE_OUTPUT_NOT_EMPTY
test "$(/bin/cat "$reuse_root/settings-sentinel")" = retained

printf '%s\n' RELEASE_PAYLOAD_TESTS_PASSED
