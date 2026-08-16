#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

input="${1:?archive or extracted payload required}"
output="${2:?inspection output required}"
if [ -z "${GT_APPROVED_BUNDLE_ID:-}" ]; then
  printf '%s\n' ARCHIVE_BUNDLE_ID_MISMATCH >&2
  exit 1
fi
test -d "$input" || {
  printf '%s\n' PAYLOAD_INPUT_INVALID >&2
  exit 1
}
test ! -e "$output" || {
  printf '%s\n' PAYLOAD_OUTPUT_EXISTS >&2
  exit 1
}
/bin/mkdir -m 700 "$output"
private_strings="$output/private-strings"
/bin/mkdir -m 700 "$private_strings"

finding_count=0
report() {
  category="$1"
  relative_path="$2"
  printf '%s:%s\n' "$category" "$relative_path" >&2
  finding_count=$((finding_count + 1))
}

paths_nul="$output/paths.nul.private"
files_nul="$output/files.nul.private"
links_nul="$output/links.nul.private"
directories_nul="$output/directories.nul.private"
if ! /usr/bin/find "$input" -mindepth 1 -print0 > "$paths_nul" \
     2> "$output/find.private" ||
   ! /usr/bin/find "$input" -type f -print0 > "$files_nul" \
     2>> "$output/find.private" ||
   ! /usr/bin/find "$input" -type l -print0 > "$links_nul" \
     2>> "$output/find.private" ||
   ! /usr/bin/find "$input" -mindepth 1 -type d -print0 \
     > "$directories_nul" \
     2>> "$output/find.private"; then
  printf '%s\n' UNVERIFIABLE_ARCHIVE_INVENTORY >&2
  exit 2
fi

validate_nul() {
  stream="$1"
  if [ -s "$stream" ]; then
    byte="$(/usr/bin/tail -c 1 "$stream" | /usr/bin/od -An -tu1 | /usr/bin/tr -d '[:space:]')" || {
      printf '%s\n' UNVERIFIABLE_ARCHIVE_INVENTORY >&2
      exit 2
    }
    test "$byte" = 0 || {
      printf '%s\n' UNVERIFIABLE_ARCHIVE_INVENTORY >&2
      exit 2
    }
  fi
}
validate_nul "$paths_nul"
validate_nul "$files_nul"
validate_nul "$links_nul"
validate_nul "$directories_nul"

archive_app="$input/Products/Applications/GlideTranslate.app"
extracted_app="$input/GlideTranslate.app"
if [ -d "$archive_app" ] && [ -d "$extracted_app" ]; then
  printf '%s\n' ARCHIVE_LAYOUT_AMBIGUOUS >&2
  exit 1
elif [ -d "$archive_app" ]; then
  payload_layout=archive
  app="$archive_app"
elif [ -d "$extracted_app" ]; then
  payload_layout=extracted
  app="$extracted_app"
else
  printf '%s\n' ARCHIVE_APP_MISSING >&2
  exit 1
fi

while IFS= read -r -d '' path; do
  relative_path="${path#"$input"/}"
  case "$relative_path" in
    *[[:cntrl:]]*) printf '%s\n' PROHIBITED_PATH_ENCODING >&2; exit 1 ;;
  esac
  directory_allowed=0
  if [ "$payload_layout" = archive ]; then
    case "$relative_path" in
      Products|\
      Products/Applications|\
      Products/Applications/GlideTranslate.app|\
      Products/Applications/GlideTranslate.app/Contents|\
      Products/Applications/GlideTranslate.app/Contents/MacOS|\
      Products/Applications/GlideTranslate.app/Contents/Resources|\
      Products/Applications/GlideTranslate.app/Contents/Resources/en.lproj|\
      Products/Applications/GlideTranslate.app/Contents/Resources/zh-Hans.lproj|\
      dSYMs|\
      dSYMs/GlideTranslate.app.dSYM|\
      dSYMs/GlideTranslate.app.dSYM/Contents|\
      dSYMs/GlideTranslate.app.dSYM/Contents/Resources|\
      dSYMs/GlideTranslate.app.dSYM/Contents/Resources/DWARF|\
      dSYMs/GlideTranslate.app.dSYM/Contents/Resources/Relocations|\
      dSYMs/GlideTranslate.app.dSYM/Contents/Resources/Relocations/*)
        directory_allowed=1 ;;
    esac
  else
    case "$relative_path" in
      GlideTranslate.app|\
      GlideTranslate.app/Contents|\
      GlideTranslate.app/Contents/MacOS|\
      GlideTranslate.app/Contents/_CodeSignature|\
      GlideTranslate.app/Contents/Resources|\
      GlideTranslate.app/Contents/Resources/en.lproj|\
      GlideTranslate.app/Contents/Resources/zh-Hans.lproj)
        directory_allowed=1 ;;
    esac
  fi
  if [ "$directory_allowed" -ne 1 ]; then
    report UNEXPECTED_PAYLOAD_PATH "$relative_path"
  fi
done < "$directories_nul"

plist_errors="$output/plist-inspection.private"
if ! bundle_identifier="$(/usr/libexec/PlistBuddy \
       -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist" \
       2>> "$plist_errors")" ||
   [ "$bundle_identifier" != "$GT_APPROVED_BUNDLE_ID" ]; then
  printf '%s\n' ARCHIVE_BUNDLE_ID_MISMATCH >&2
  exit 1
fi
if ! minimum_system="$(/usr/libexec/PlistBuddy \
       -c 'Print :LSMinimumSystemVersion' "$app/Contents/Info.plist" \
       2>> "$plist_errors")" ||
   [ "$minimum_system" != 14.0 ]; then
  printf '%s\n' ARCHIVE_MINIMUM_OS_MISMATCH >&2
  exit 1
fi
if ! ui_element="$(/usr/libexec/PlistBuddy \
       -c 'Print :LSUIElement' "$app/Contents/Info.plist" \
       2>> "$plist_errors")" ||
   [ "$ui_element" != true ]; then
  printf '%s\n' ARCHIVE_ACCESSORY_BEHAVIOR_MISMATCH >&2
  exit 1
fi
main_binary="$app/Contents/MacOS/GlideTranslate"
test -f "$main_binary" || {
  printf '%s\n' ARCHIVE_ARCHITECTURE_MISMATCH >&2
  exit 1
}
if ! main_archs="$(/usr/bin/lipo -archs "$main_binary" \
       2>> "$output/lipo.private")"; then
  printf '%s\n' UNVERIFIABLE_MACHO_ARCH >&2
  exit 2
fi
if [ "$main_archs" != arm64 ]; then
  printf '%s\n' ARCHIVE_ARCHITECTURE_MISMATCH >&2
  exit 1
fi

while IFS= read -r -d '' path; do
  relative_path="${path#"$input"/}"
  case "$relative_path" in
    *[[:cntrl:]]*) printf '%s\n' PROHIBITED_PATH_ENCODING >&2; exit 1 ;;
  esac
  report PROHIBITED_SYMLINK "$relative_path"
done < "$links_nul"

for inventory in app dsyms archive; do
  case "$inventory" in
    app) inventory_root="$app" ;;
    dsyms) inventory_root="$input/dSYMs" ;;
    archive) inventory_root="$input" ;;
  esac
  unsorted="$output/$inventory-files.unsorted.private"
  sorted="$output/$inventory-files.txt.private"
  if [ "$inventory" = dsyms ] && [ ! -d "$inventory_root" ]; then
    : > "$unsorted"
  elif ! /usr/bin/find "$inventory_root" -type f -print > "$unsorted" \
      2>> "$output/find.private"; then
    printf 'UNVERIFIABLE_ARCHIVE_INVENTORY:%s\n' "$inventory" >&2
    exit 2
  fi
  if ! LC_ALL=C /usr/bin/sort "$unsorted" > "$sorted" \
      2>> "$output/sort.private"; then
    printf 'UNVERIFIABLE_ARCHIVE_INVENTORY:%s\n' "$inventory" >&2
    exit 2
  fi
done

users_prefix='/'"Users/"
home_prefix='/'"home/"
content_pattern="${users_prefix}[^/[:space:]]+|${home_prefix}[^/[:space:]]+"
agent_pattern='(^|/)([.]codex|[.]superpowers|docs/superpowers)(/|$)|(^|/)(AGENTS[.]md|CLAUDE[.]md)$'
private_endpoint_pattern='https?://[^/@[:space:]]+:[^/@[:space:]]+@|https?://(10[.]|169[.]254[.]|172[.](1[6-9]|2[0-9]|3[01])[.]|192[.]168[.])'
credential_pattern='BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY|Authorization:[[:space:]]*(Bearer|Basic)'
build_pattern='(/private)?/var/folders/[^[:space:]]*(DerivedData|Build)|/DerivedData/'
scan_pair() {
  category="$1"
  pattern="$2"
  relative_path="$3"
  first="$4"
  second="$5"
  for scan_target in "$first" "$second"; do
    scan_status=0
    LC_ALL=C rg -a -q -- "$pattern" "$scan_target" \
      2>> "$output/rg.private" || scan_status=$?
    case "$scan_status" in
      0) report "$category" "$relative_path"; return ;;
      1) ;;
      *) printf '%s\n' UNVERIFIABLE_PAYLOAD_SCAN >&2; exit 2 ;;
    esac
  done
}
index=0
while IFS= read -r -d '' path; do
  index=$((index + 1))
  relative_path="${path#"$input"/}"
  case "$relative_path" in
    *[[:cntrl:]]*) printf '%s\n' PROHIBITED_PATH_ENCODING >&2; exit 1 ;;
  esac
  case "/$relative_path/" in
    */.codex/*|*/.superpowers/*|*/docs/superpowers/*)
      report PROHIBITED_AGENT_PATH "$relative_path"
      ;;
  esac
  case "$relative_path" in
    AGENTS.md|CLAUDE.md|*/AGENTS.md|*/CLAUDE.md)
      report PROHIBITED_AGENT_PATH "$relative_path"
      ;;
    *.p12|*.pfx|*.cer|*.key|*.mobileprovision|*.provisionprofile|*ExportOptions.plist|*notary*.json)
      report PROHIBITED_CREDENTIAL_FILE "$relative_path"
      ;;
    *.sqlite|*.sqlite-shm|*.sqlite-wal|*.db|*.log|*/logs/*|*/diagnostics/*)
      report PROHIBITED_RUNTIME_STATE "$relative_path"
      ;;
    *.gguf|*.safetensors|*/model-cache/*|*/models/*|*/cache/*)
      report PROHIBITED_MODEL_CACHE "$relative_path"
      ;;
  esac
  path_allowed=0
  if [ "$payload_layout" = archive ]; then
    case "$relative_path" in
      Info.plist|\
      Products/Applications/GlideTranslate.app/Contents/Info.plist|\
      Products/Applications/GlideTranslate.app/Contents/PkgInfo|\
      Products/Applications/GlideTranslate.app/Contents/MacOS/GlideTranslate|\
      Products/Applications/GlideTranslate.app/Contents/Resources/en.lproj/InfoPlist.strings|\
      Products/Applications/GlideTranslate.app/Contents/Resources/en.lproj/Localizable.strings|\
      Products/Applications/GlideTranslate.app/Contents/Resources/zh-Hans.lproj/InfoPlist.strings|\
      Products/Applications/GlideTranslate.app/Contents/Resources/zh-Hans.lproj/Localizable.strings|\
      dSYMs/GlideTranslate.app.dSYM/Contents/Info.plist|\
      dSYMs/GlideTranslate.app.dSYM/Contents/Resources/DWARF/GlideTranslate|\
      dSYMs/GlideTranslate.app.dSYM/Contents/Resources/Relocations/*/GlideTranslate.yml)
        path_allowed=1 ;;
    esac
  else
    case "$relative_path" in
      GlideTranslate.app/Contents/Info.plist|\
      GlideTranslate.app/Contents/PkgInfo|\
      GlideTranslate.app/Contents/MacOS/GlideTranslate|\
      GlideTranslate.app/Contents/_CodeSignature/CodeResources|\
      GlideTranslate.app/Contents/Resources/en.lproj/InfoPlist.strings|\
      GlideTranslate.app/Contents/Resources/en.lproj/Localizable.strings|\
      GlideTranslate.app/Contents/Resources/zh-Hans.lproj/InfoPlist.strings|\
      GlideTranslate.app/Contents/Resources/zh-Hans.lproj/Localizable.strings)
        path_allowed=1 ;;
    esac
  fi
  if [ "$path_allowed" -ne 1 ]; then
    report UNEXPECTED_PAYLOAD_PATH "$relative_path"
  fi
  size="$(/usr/bin/stat -f '%z' "$path" 2>> "$output/stat.private")" || {
    printf '%s\n' UNVERIFIABLE_PAYLOAD_METADATA >&2
    exit 2
  }
  case "$size" in ''|*[!0-9]*) printf '%s\n' UNVERIFIABLE_PAYLOAD_METADATA >&2; exit 2 ;; esac
  if [ "$size" -gt 67108864 ]; then
    report OVERSIZED_PAYLOAD "$relative_path"
    continue
  fi

  kind="$(/usr/bin/file -b "$path" 2>> "$output/file.private")" || {
    printf '%s\n' UNVERIFIABLE_PAYLOAD_TYPE >&2
    exit 2
  }
  case "$kind" in
    *Mach-O*)
      if ! binary_archs="$(/usr/bin/lipo -archs "$path" \
          2>> "$output/lipo.private")"; then
        printf '%s\n' UNVERIFIABLE_MACHO_ARCH >&2
        exit 2
      fi
      printf '%s\n' "$binary_archs" >> "$output/macho-architectures.private"
      if [ "$binary_archs" != arm64 ]; then
        report ARCHIVE_MACHO_ARCH_MISMATCH "$relative_path"
      fi
      linkage_file="$private_strings/$index.linkage"
      if ! /usr/bin/otool -L "$path" > "$linkage_file" \
          2>> "$output/otool.private"; then
        printf '%s\n' UNVERIFIABLE_MACHO_LINKAGE >&2
        exit 2
      fi
      /bin/cat "$linkage_file" >> "$output/macho-linkage.private"
      while IFS= read -r dependency_line; do
        dependency="${dependency_line#${dependency_line%%[![:space:]]*}}"
        dependency="${dependency%% *}"
        case "$dependency" in
          /System/Library/*|/usr/lib/*) ;;
          *) report ARCHIVE_LINKAGE_UNAPPROVED "$relative_path" ;;
        esac
      done < <(/usr/bin/tail -n +2 "$linkage_file")
      ;;
    *Zip\ archive*|*gzip\ compressed*|*tar\ archive*|*executable*)
      report UNVERIFIABLE_PAYLOAD_TYPE "$relative_path"
      ;;
    *ASCII\ text*|*UTF-8\ Unicode\ text*|*Unicode\ text*|*XML*|*JSON*|*property\ list*|*empty*)
      ;;
    *)
      report UNVERIFIABLE_PAYLOAD_TYPE "$relative_path"
      ;;
  esac

  strings_file="$private_strings/$index.txt"
  if ! /usr/bin/strings -a "$path" > "$strings_file" \
       2>> "$output/strings.private"; then
    printf '%s\n' UNVERIFIABLE_PAYLOAD_STRINGS >&2
    exit 2
  fi
  scan_pair PROHIBITED_USER_PATH "$content_pattern" "$relative_path" \
    "$path" "$strings_file"
  scan_pair PROHIBITED_AGENT_PATH "$agent_pattern" "$relative_path" \
    "$path" "$strings_file"
  scan_pair PROHIBITED_PRIVATE_ENDPOINT "$private_endpoint_pattern" \
    "$relative_path" "$path" "$strings_file"
  scan_pair PROHIBITED_CREDENTIAL_CONTENT "$credential_pattern" \
    "$relative_path" "$path" "$strings_file"
  scan_pair PROHIBITED_BUILD_PATH "$build_pattern" "$relative_path" \
    "$path" "$strings_file"
done < "$files_nul"

gitleaks_report="$output/gitleaks-report.private.json"
if ! gitleaks dir --no-banner --redact --exit-code 0 \
    --report-format json --report-path "$gitleaks_report" "$input" \
    > "$output/gitleaks.stdout.private" 2> "$output/gitleaks.stderr.private"; then
  printf '%s\n' UNVERIFIABLE_SECRET_SCAN >&2
  exit 2
fi
if ! /usr/bin/jq -s -e 'length == 1 and (.[0] | type == "array")' \
    "$gitleaks_report" \
    >/dev/null 2> "$output/gitleaks-jq.private"; then
  printf '%s\n' UNVERIFIABLE_SECRET_SCAN >&2
  exit 2
fi
if ! /usr/bin/jq -s -e 'length == 1 and (.[0] | length == 0)' \
    "$gitleaks_report" \
    >/dev/null 2>> "$output/gitleaks-jq.private"; then
  report PROHIBITED_SECRET_SCAN .
fi

if [ "$finding_count" -ne 0 ]; then
  exit 1
fi

/bin/rm -rf "$private_strings" || {
  printf '%s\n' PAYLOAD_PRIVATE_CLEANUP_FAILED >&2
  exit 2
}
printf '%s\n' \
  'PAYLOAD_INSPECTION:PASS' \
  'SYMLINKS:PASS' \
  'PATH_AND_CONTENT_CATEGORIES:PASS' \
  'MACHO_METADATA:PASS' \
  'SECRET_SCAN:PASS' > "$output/inspection.txt"
printf '%s\n' PAYLOAD_INSPECTION_PASSED
