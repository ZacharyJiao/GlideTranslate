#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

candidate_input="${1:?candidate root required}"
policy_root="$(mktemp -d)"
cleanup_policy_on_exit() {
  prior_status=$?
  trap - EXIT
  cleanup_status=0
  /bin/rm -rf "$policy_root" >/dev/null 2>&1 || cleanup_status=$?
  if [ "$prior_status" -ne 0 ]; then
    exit "$prior_status"
  fi
  if [ "$cleanup_status" -ne 0 ]; then
    printf '%s\n' POLICY_CLEANUP_FAILED >&2
    exit 2
  fi
  exit 0
}
trap cleanup_policy_on_exit EXIT

if ! candidate_root="$(cd "$candidate_input" \
       2> "$policy_root/resolve.private" && \
       pwd 2>> "$policy_root/resolve.private")"; then
  printf '%s\n' POLICY_ROOT_INVALID >&2
  exit 2
fi
finding_count=0

report() {
  category="$1"
  relative_path="$2"
  printf '%s:%s\n' "$category" "$relative_path" >&2
  finding_count=$((finding_count + 1))
}

path_inventory="$policy_root/all.nul"
regular_files="$policy_root/files.nul"
symlink_files="$policy_root/symlinks.nul"
content_matches="$policy_root/content.nul"
loopback_matches="$policy_root/loopback.nul"
metadata_errors="$policy_root/stat.private"
/usr/bin/find "$candidate_root" -path "$candidate_root/.git" -type d -prune -o \
  -mindepth 1 -print0 \
  > "$path_inventory" 2> "$policy_root/find-all.private" || {
  printf '%s\n' POLICY_ENUMERATION_FAILED >&2
  exit 2
}
/usr/bin/find "$candidate_root" -path "$candidate_root/.git" -type d -prune -o \
  -type f -print0 \
  > "$regular_files" 2> "$policy_root/find-files.private" || {
  printf '%s\n' POLICY_ENUMERATION_FAILED >&2
  exit 2
}
/usr/bin/find "$candidate_root" -path "$candidate_root/.git" -type d -prune -o \
  -type l -print0 \
  > "$symlink_files" 2> "$policy_root/find-symlinks.private" || {
  printf '%s\n' POLICY_ENUMERATION_FAILED >&2
  exit 2
}

validate_nul_termination() {
  stream="$1"
  if [ -s "$stream" ]; then
    if ! final_byte="$(/usr/bin/tail -c 1 "$stream" \
      2>> "$policy_root/helpers.private" \
      | /usr/bin/od -An -tu1 2>> "$policy_root/helpers.private" \
      | /usr/bin/tr -d '[:space:]' 2>> "$policy_root/helpers.private")"; then
      printf '%s\n' POLICY_ENUMERATION_FAILED >&2
      exit 2
    fi
    if [ "$final_byte" != 0 ]; then
      printf '%s\n' POLICY_ENUMERATION_FAILED >&2
      exit 2
    fi
  fi
}
validate_nul_termination "$path_inventory"
validate_nul_termination "$regular_files"
validate_nul_termination "$symlink_files"

all_lines="$policy_root/all.lines"
file_lines="$policy_root/files.lines"
symlink_lines="$policy_root/symlinks.lines"
: > "$all_lines"
: > "$file_lines"
: > "$symlink_lines"

while IFS= read -r -d '' path; do
  case "$path" in
    "$candidate_root"/*) ;;
    *) printf '%s\n' POLICY_ENUMERATION_FAILED >&2; exit 2 ;;
  esac
  case "/$path/" in
    */../*|*/./*) printf '%s\n' POLICY_ENUMERATION_FAILED >&2; exit 2 ;;
  esac
  if [ ! -e "$path" ] && [ ! -L "$path" ]; then
    printf '%s\n' POLICY_ENUMERATION_FAILED >&2
    exit 2
  fi
  relative_path="${path#"$candidate_root"/}"
  case "$relative_path" in
    *[[:cntrl:]]*)
      printf '%s\n' PROHIBITED_PATH_ENCODING >&2
      exit 1
      ;;
  esac
  printf '%s\n' "$path" >> "$all_lines"
done < "$path_inventory"

while IFS= read -r -d '' path; do
  case "$path" in
    "$candidate_root"/*) ;;
    *) printf '%s\n' POLICY_ENUMERATION_FAILED >&2; exit 2 ;;
  esac
  case "/$path/" in
    */../*|*/./*) printf '%s\n' POLICY_ENUMERATION_FAILED >&2; exit 2 ;;
  esac
  if [ ! -f "$path" ] || [ -L "$path" ]; then
    printf '%s\n' POLICY_ENUMERATION_FAILED >&2
    exit 2
  fi
  relative_path="${path#"$candidate_root"/}"
  case "$relative_path" in
    *[[:cntrl:]]*) printf '%s\n' PROHIBITED_PATH_ENCODING >&2; exit 1 ;;
  esac
  printf '%s\n' "$path" >> "$file_lines"
done < "$regular_files"

while IFS= read -r -d '' path; do
  case "$path" in
    "$candidate_root"/*) ;;
    *) printf '%s\n' POLICY_ENUMERATION_FAILED >&2; exit 2 ;;
  esac
  case "/$path/" in
    */../*|*/./*) printf '%s\n' POLICY_ENUMERATION_FAILED >&2; exit 2 ;;
  esac
  if [ ! -L "$path" ]; then
    printf '%s\n' POLICY_ENUMERATION_FAILED >&2
    exit 2
  fi
  relative_path="${path#"$candidate_root"/}"
  case "$relative_path" in
    *[[:cntrl:]]*) printf '%s\n' PROHIBITED_PATH_ENCODING >&2; exit 1 ;;
  esac
  printf '%s\n' "$path" >> "$symlink_lines"
done < "$symlink_files"

LC_ALL=C /usr/bin/sort -u "$all_lines" -o "$all_lines" \
  2>> "$policy_root/helpers.private" || {
  printf '%s\n' POLICY_ENUMERATION_FAILED >&2; exit 2;
}
LC_ALL=C /usr/bin/sort -u "$file_lines" -o "$file_lines" \
  2>> "$policy_root/helpers.private" || {
  printf '%s\n' POLICY_ENUMERATION_FAILED >&2; exit 2;
}
LC_ALL=C /usr/bin/sort -u "$symlink_lines" -o "$symlink_lines" \
  2>> "$policy_root/helpers.private" || {
  printf '%s\n' POLICY_ENUMERATION_FAILED >&2; exit 2;
}
if ! missing_files="$(LC_ALL=C /usr/bin/comm -23 "$file_lines" "$all_lines" \
     2>> "$policy_root/helpers.private")"; then
  printf '%s\n' POLICY_ENUMERATION_FAILED >&2
  exit 2
fi
if ! missing_symlinks="$(LC_ALL=C /usr/bin/comm -23 "$symlink_lines" "$all_lines" \
     2>> "$policy_root/helpers.private")"; then
  printf '%s\n' POLICY_ENUMERATION_FAILED >&2
  exit 2
fi
if [ -n "$missing_files" ] || [ -n "$missing_symlinks" ]; then
  printf '%s\n' POLICY_ENUMERATION_FAILED >&2
  exit 2
fi

while IFS= read -r -d '' path; do
  relative_path="${path#"$candidate_root"/}"
  case "/$relative_path" in
    /docs/superpowers/*|/.codex/*|/.superpowers/*|*/xcuserdata/*|*.xcarchive/*)
      report PROHIBITED_PATH "$relative_path"
      ;;
  esac
  case "$relative_path" in
    .env|.env.*|*/.env|*/.env.*|*.sqlite|*.sqlite-shm|*.sqlite-wal|*.log|*.p12|*.provisionprofile|*.mobileprovision|*.gguf)
      report PROHIBITED_EXTENSION "$relative_path"
      ;;
  esac
  if ! file_size="$(/usr/bin/stat -f '%z' "$path" 2>> "$metadata_errors")"; then
    printf '%s\n' POLICY_METADATA_FAILED >&2
    exit 2
  fi
  case "$file_size" in
    ''|*[!0-9]*) printf '%s\n' POLICY_METADATA_FAILED >&2; exit 2 ;;
  esac
  if [ "$file_size" -gt 10485760 ]; then
    report OVERSIZED_FILE "$relative_path"
  fi
done < "$regular_files"

while IFS= read -r -d '' path; do
  relative_path="${path#"$candidate_root"/}"
  case "$relative_path" in
    *[[:cntrl:]]*)
      printf '%s\n' PROHIBITED_PATH_ENCODING >&2
      exit 1
      ;;
  esac
  report PROHIBITED_SYMLINK "$relative_path"
done < "$symlink_files"

users_prefix='/'"Users/"
home_prefix='/'"home/"
content_pattern="${users_prefix}[^/[:space:]]+|${home_prefix}[^/[:space:]]+|https?://[^/@[:space:]]+:[^/@[:space:]]+@|https?://(10[.]|169[.]254[.]|172[.](1[6-9]|2[0-9]|3[01])[.]|192[.]168[.])|BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY|Authorization:[[:space:]]*(Bearer|Basic)"
: > "$content_matches"
while IFS= read -r -d '' path; do
  rg_status=0
  : > "$policy_root/content-rg.stdout.private"
  LC_ALL=C rg -a -q --no-ignore --regexp "$content_pattern" -- "$path" \
    > "$policy_root/content-rg.stdout.private" \
    2>> "$policy_root/content-rg.private" || rg_status=$?
  if [ -s "$policy_root/content-rg.stdout.private" ]; then
    printf '%s\n' POLICY_SCAN_FAILED >&2
    exit 2
  fi
  case "$rg_status" in
    0) printf '%s\0' "$path" >> "$content_matches" ;;
    1) ;;
    *) printf '%s\n' POLICY_SCAN_FAILED >&2; exit 2 ;;
  esac
done < "$regular_files"
while IFS= read -r -d '' path; do
  relative_path="${path#"$candidate_root"/}"
  case "$relative_path" in
    *[[:cntrl:]]*)
      printf '%s\n' PROHIBITED_PATH_ENCODING >&2
      exit 1
      ;;
  esac
  report PROHIBITED_CONTENT "$relative_path"
done < "$content_matches"

loopback_pattern='https?://127[.]0[.]0[.]1(:[0-9]+)?'
: > "$loopback_matches"
while IFS= read -r -d '' path; do
  rg_status=0
  : > "$policy_root/loopback-rg.stdout.private"
  LC_ALL=C rg -a -q --no-ignore --regexp "$loopback_pattern" -- "$path" \
    > "$policy_root/loopback-rg.stdout.private" \
    2>> "$policy_root/loopback-rg.private" || rg_status=$?
  if [ -s "$policy_root/loopback-rg.stdout.private" ]; then
    printf '%s\n' POLICY_SCAN_FAILED >&2
    exit 2
  fi
  case "$rg_status" in
    0) printf '%s\0' "$path" >> "$loopback_matches" ;;
    1) ;;
    *) printf '%s\n' POLICY_SCAN_FAILED >&2; exit 2 ;;
  esac
done < "$regular_files"
while IFS= read -r -d '' path; do
  relative_path="${path#"$candidate_root"/}"
  case "$relative_path" in
    *[[:cntrl:]]*)
      printf '%s\n' PROHIBITED_PATH_ENCODING >&2
      exit 1
      ;;
  esac
  case "$relative_path" in
    Sources/SharedSupport/Domain/ProviderTypes.swift|Sources/ModelProviders/*|Tests/ModelProvidersTests/*|App/GlideTranslate/Onboarding/*|App/GlideTranslate/Settings/*|Sources/PrivacyStorage/ProviderVault/*|Tests/PrivacyStorageTests/OffDeviceAuthorizationTests.swift|Tests/PrivacyStorageTests/PrivacyStorageFactoryTests.swift|Tests/PrivacyStorageTests/ProviderMetadataRepositoryTests.swift|Tests/PrivacyStorageTests/ProviderVaultHandleTests.swift|Tests/PrivacyStorageTests/ProviderVaultStateMachineTests.swift|script/check_local_ollama_preflight.sh) ;;
    *) report PROHIBITED_CONTENT "$relative_path" ;;
  esac
done < "$loopback_matches"

if ! command -v gitleaks >/dev/null 2>&1; then
  printf '%s\n' 'TOOL_UNAVAILABLE:gitleaks' >&2
  exit 2
fi
gitleaks_report="$policy_root/gitleaks.json"
gitleaks dir --no-banner --redact \
  --exit-code 0 \
  --report-format json \
  --report-path "$gitleaks_report" \
  "$candidate_root" \
  >/dev/null 2> "$policy_root/gitleaks.private" || {
  printf '%s\n' GITLEAKS_SCAN_FAILED >&2
  exit 2
}
if ! jq -s -e 'length == 1 and (.[0] | type == "array")' "$gitleaks_report" \
    >/dev/null 2> "$policy_root/gitleaks-jq.private"; then
  printf '%s\n' GITLEAKS_SCAN_FAILED >&2
  exit 2
fi
if ! jq -s -e '.[0] | length == 0' "$gitleaks_report" \
    >/dev/null 2>> "$policy_root/gitleaks-jq.private"; then
  printf '%s\n' 'GITLEAKS_FINDING:candidate-tree' >&2
  exit 1
fi

if [ "$finding_count" -ne 0 ]; then
  exit 1
fi
