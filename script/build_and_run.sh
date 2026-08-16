#!/usr/bin/env bash
set -euo pipefail

mode="${1:-run}"
app_name="GlideTranslate"
root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
derived_data="$root_dir/.build/xcode-derived-data"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

"$root_dir/script/check_full_xcode.sh" >/dev/null
xcodebuild \
  -project "$root_dir/GlideTranslate.xcodeproj" \
  -scheme GlideTranslate \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath "$derived_data" \
  CODE_SIGNING_ALLOWED=NO \
  build
app_bundle="$derived_data/Build/Products/Debug/$app_name.app"
app_executable="$app_bundle/Contents/MacOS/$app_name"

case "$mode" in
  run)
    "$app_executable" > /dev/null 2>&1 &
    launched_pid=$!
    disown "$launched_pid" 2>/dev/null || true
    ;;
  --debug|debug)
    /usr/bin/lldb -- "$app_bundle/Contents/MacOS/$app_name"
    ;;
  --logs|logs)
    "$app_executable" > /dev/null 2>&1 &
    launched_pid=$!
    /usr/bin/log stream --info --style compact --predicate "processIdentifier == $launched_pid"
    ;;
  --telemetry|telemetry)
    "$app_executable" > /dev/null 2>&1 &
    /usr/bin/log stream --info --style compact --predicate 'subsystem == "com.zaryolabs.GlideTranslate"'
    ;;
  --verify|verify)
    "$app_executable" > /dev/null 2>&1 &
    launched_pid=$!
    for attempt in $(/usr/bin/jot 20); do
      resolved_executable="$(/usr/sbin/lsof -a -p "$launched_pid" -d txt -Fn 2>/dev/null \
        | /usr/bin/sed -n 's/^n//p' | /usr/bin/head -n 1)"
      if /bin/kill -0 "$launched_pid" 2>/dev/null &&
         test "$resolved_executable" = "$app_executable"; then
        /bin/kill "$launched_pid"
        wait "$launched_pid" 2>/dev/null || true
        exit 0
      fi
      /bin/sleep 0.1
    done
    echo "GlideTranslate did not launch" >&2
    exit 1
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
