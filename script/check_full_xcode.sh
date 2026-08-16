#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

developer_dir="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
if [[ ! -x "$developer_dir/usr/bin/xcodebuild" ]]; then
  echo "full Xcode developer directory is unavailable" >&2
  exit 1
fi
DEVELOPER_DIR="$developer_dir" xcodebuild -version
DEVELOPER_DIR="$developer_dir" xcrun --sdk macosx --show-sdk-path >/dev/null
DEVELOPER_DIR="$developer_dir" xcodebuild -checkFirstLaunchStatus
