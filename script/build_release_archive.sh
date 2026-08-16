#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

developer_dir="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
output_root="${1:?output root required}"
xcodebuild_bin="$developer_dir/usr/bin/xcodebuild"

if [ -e "$output_root" ]; then
  test -d "$output_root" || {
    printf '%s\n' ARCHIVE_OUTPUT_INVALID >&2
    exit 1
  }
  test -z "$(/bin/ls -A "$output_root" 2>/dev/null)" || {
    printf '%s\n' ARCHIVE_OUTPUT_NOT_EMPTY >&2
    exit 1
  }
else
  /bin/mkdir -m 700 "$output_root"
fi

archive="$output_root/GlideTranslate-arm64.xcarchive"
result="$output_root/Archive.xcresult"
settings_json="$output_root/build-settings.json"
settings_errors="$output_root/build-settings.private"
settings_jq_errors="$output_root/build-settings-jq.private"
test ! -e "$archive" && test ! -e "$result" || {
  printf '%s\n' ARCHIVE_OUTPUT_EXISTS >&2
  exit 1
}

if ! "$xcodebuild_bin" \
    -project GlideTranslate.xcodeproj \
    -scheme GlideTranslate \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -showBuildSettings -json \
    > "$settings_json" 2> "$settings_errors"; then
  printf '%s\n' ARCHIVE_SETTING_ENUMERATION_FAILED >&2
  exit 2
fi
if ! /usr/bin/jq -e '
  type == "array" and
  length > 0 and
  all(.[];
    (.buildSettings | type) == "object" and
    .buildSettings.MACOSX_DEPLOYMENT_TARGET == "14.0" and
    .buildSettings.ENABLE_APP_SANDBOX == "NO" and
    .buildSettings.ENABLE_HARDENED_RUNTIME == "YES"
  )
' "$settings_json" >/dev/null 2> "$settings_jq_errors"; then
  printf '%s\n' ARCHIVE_SETTING_MISMATCH >&2
  exit 1
fi

if ! "$xcodebuild_bin" \
    -project GlideTranslate.xcodeproj \
    -scheme GlideTranslate \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -archivePath "$archive" \
    -resultBundlePath "$result" \
    ARCHS=arm64 \
    ONLY_ACTIVE_ARCH=NO \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    SWIFT_SUPPRESS_WARNINGS=NO \
    SWIFT_TREAT_WARNINGS_AS_ERRORS=YES \
    GCC_TREAT_WARNINGS_AS_ERRORS=YES \
    archive > "$output_root/archive.stdout.private" \
    2> "$output_root/archive.stderr.private"; then
  printf '%s\n' ARCHIVE_BUILD_FAILED >&2
  exit 1
fi

test -d "$archive" && test -d "$result" || {
  printf '%s\n' ARCHIVE_OUTPUT_MISSING >&2
  exit 1
}
printf '%s\n' ARCHIVE_BUILD_PASSED
