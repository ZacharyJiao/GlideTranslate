#!/usr/bin/env bash
set -euo pipefail

workspace_root="$(cd "$(dirname "$0")/.." && pwd)"
developer_dir="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
source_root="$workspace_root/assets/brand/app-icon/source"
icon_document="$workspace_root/App/GlideTranslate/Resources/AppIcon.icon"
menu_asset_root="$workspace_root/App/GlideTranslate/Assets.xcassets/MenuBarTemplate.imageset"
derived_data="$(mktemp -d)"
users_prefix='/'"Users/"
home_prefix='/'"home/"
metadata_pattern="creator|generator|author|username|email|session|model|prompt|${users_prefix}|${home_prefix}"
trap '/bin/rm -rf "$derived_data"' EXIT

test -f "$source_root/original-mark-1024.png"
test -f "$source_root/menu-template-1024.png"
test -e "$icon_document"
cmp -s "$source_root/original-mark-1024.png" \
  "$workspace_root/App/GlideTranslate/Assets.xcassets/BrandMark.imageset/BrandMark.png"
test -f "$menu_asset_root/MenuBarTemplate.png"
test -f "$menu_asset_root/MenuBarTemplate@2x.png"
test "$(sips -g pixelWidth "$menu_asset_root/MenuBarTemplate.png" \
  | awk '/pixelWidth/ {print $2}')" = 18
test "$(sips -g pixelHeight "$menu_asset_root/MenuBarTemplate.png" \
  | awk '/pixelHeight/ {print $2}')" = 18
test "$(sips -g pixelWidth "$menu_asset_root/MenuBarTemplate@2x.png" \
  | awk '/pixelWidth/ {print $2}')" = 36
test "$(sips -g pixelHeight "$menu_asset_root/MenuBarTemplate@2x.png" \
  | awk '/pixelHeight/ {print $2}')" = 36

for asset in "$source_root"/*.png; do
  test "$(sips -g pixelWidth "$asset" | awk '/pixelWidth/ {print $2}')" = 1024
  test "$(sips -g pixelHeight "$asset" | awk '/pixelHeight/ {print $2}')" = 1024
  test "$(sips -g hasAlpha "$asset" | awk '/hasAlpha/ {print $2}')" = yes
  ! strings "$asset" \
    | rg -i -q "$metadata_pattern"
done

for asset in "$menu_asset_root"/*.png; do
  test "$(sips -g hasAlpha "$asset" | awk '/hasAlpha/ {print $2}')" = yes
  ! strings "$asset" | rg -i -q "$metadata_pattern"
done

build_settings="$($developer_dir/usr/bin/xcodebuild \
  -project "$workspace_root/GlideTranslate.xcodeproj" \
  -scheme GlideTranslate \
  -configuration Release \
  -showBuildSettings)"
printf '%s\n' "$build_settings" \
  | rg -q '^    ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon$'

$developer_dir/usr/bin/xcodebuild \
  -project "$workspace_root/GlideTranslate.xcodeproj" \
  -scheme GlideTranslate \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$derived_data" \
  CODE_SIGNING_ALLOWED=NO \
  SWIFT_SUPPRESS_WARNINGS=NO \
  SWIFT_TREAT_WARNINGS_AS_ERRORS=YES \
  GCC_TREAT_WARNINGS_AS_ERRORS=YES \
  build >/dev/null

app="$derived_data/Build/Products/Release/GlideTranslate.app"
test -d "$app"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
  "$app/Contents/Info.plist")" = 0.2.1
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' \
  "$app/Contents/Info.plist")" = 2
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconName' \
  "$app/Contents/Info.plist")" = AppIcon
/usr/bin/find "$app/Contents/Resources" -type f \
  \( -name '*.icns' -o -name 'Assets.car' \) -print -quit \
  | rg -q .

printf '%s\n' APP_ICON_CONTRACT_PASS
