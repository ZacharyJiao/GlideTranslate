#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

script_dir="$(cd "$(dirname "$0")" 2>/dev/null && pwd)" || {
  printf '%s\n' UNVERIFIABLE_SURFACE_ROOT >&2
  exit 2
}
surface_mode=generic
if [ "${1:-}" = --release-payload ]; then
  surface_mode=release-payload
  shift
fi
surface_input="${1:?surface root required}"
test "$#" -eq 1 || {
  printf '%s\n' UNVERIFIABLE_SURFACE_ROOT >&2
  exit 2
}
test -d "$surface_input" || {
  printf '%s\n' UNVERIFIABLE_SURFACE_ROOT >&2
  exit 2
}
test ! -L "$surface_input" || {
  printf '%s\n' UNVERIFIABLE_SURFACE_ROOT >&2
  exit 2
}
if ! surface_root="$(cd "$surface_input" 2>/dev/null && pwd)"; then
  printf '%s\n' UNVERIFIABLE_SURFACE_ROOT >&2
  exit 2
fi
private_root="$(mktemp -d)"
cleanup_private() {
  prior_status=$?
  trap - EXIT INT TERM HUP
  /bin/rm -rf "$private_root" >/dev/null 2>&1 || true
  exit "$prior_status"
}
trap cleanup_private EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

metadata_failure() {
  printf '%s\n' UNVERIFIABLE_SURFACE_METADATA >&2
  exit 2
}

hash_private_value() {
  local value="$1"
  local hash_input="$private_root/hash-input"
  local digest_output digest
  if ! printf '%s' "$value" > "$hash_input"; then
    metadata_failure
  fi
  digest_output="$(/usr/bin/shasum -a 256 "$hash_input" \
    2>> "$private_root/hash.private")" || metadata_failure
  digest="${digest_output%% *}"
  case "$digest" in
    [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]*) ;;
    *) metadata_failure ;;
  esac
  printf '%s' "${digest%${digest#????????????}}"
}

surface_id="surface-$(hash_private_value "$surface_root")"
finding_count=0
report() {
  local category="$1"
  local relative_path="$2"
  local file_id="file-$(hash_private_value "$relative_path")"
  printf '%s:%s:%s\n' "$category" "$surface_id" "$file_id" >&2
  finding_count=$((finding_count + 1))
}

entries="$private_root/entries.nul"
if ! /usr/bin/find "$surface_root" -mindepth 1 -print0 > "$entries" \
     2> "$private_root/find.private"; then
  printf '%s\n' UNVERIFIABLE_SURFACE_ENUMERATION >&2
  exit 2
fi

users_prefix='/'"Users/"
home_prefix='/'"home/"
absolute_pattern="${users_prefix}[^/[:space:]]+|${home_prefix}[^/[:space:]]+|/private/(tmp|var)(/|[[:space:]])|/tmp(/|[[:space:]])|/Volumes(/|[[:space:]])|/opt/homebrew(/|[[:space:]])"
agent_pattern='(^|/|[[:space:]])([.]codex|[.]superpowers|docs/superpowers|AGENTS[.]md|CLAUDE[.]md)(/|$|[[:space:]])'
private_endpoint_pattern='https?://[^/@[:space:]]+:[^/@[:space:]]+@|https?://(localhost|127([.][0-9]{1,3}){3}|10[.]|169[.]254[.]|172[.](1[6-9]|2[0-9]|3[01])[.]|192[.]168[.]|\[?::1\]?|\[?fe80:|\[?f[cd][0-9a-f]{2}:)'
private_key_pattern='BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY'
content_marker_pattern='GT_PRIVATE_(USER_CONTENT|MODEL_CACHE|DIAGNOSTIC)|GLIDETRANSLATE_PRIVATE_CONTENT'
email_pattern='[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+[.][A-Za-z]{2,}'
release_main_path=GlideTranslate.app/Contents/MacOS/GlideTranslate
release_uri_classifier="${RELEASE_URI_CLASSIFIER:-$script_dir/classify_release_uris.py}"

is_allowed_email() {
  local email="$1"
  local lower_email lower_allowed allowed old_ifs
  lower_email="$(printf '%s' "$email" | /usr/bin/tr '[:upper:]' '[:lower:]')" || metadata_failure
  case "$lower_email" in *@users.noreply.github.com) return 0 ;; esac
  case "$lower_email" in git@github.com) return 0 ;; esac
  old_ifs="$IFS"
  IFS=','
  for allowed in ${GT_PUBLIC_LOGIN_ALLOWLIST:-}; do
    lower_allowed="$(printf '%s' "$allowed" | /usr/bin/tr '[:upper:]' '[:lower:]')" || metadata_failure
    if [ "$lower_email" = "$lower_allowed" ]; then IFS="$old_ifs"; return 0; fi
  done
  IFS="$old_ifs"
  return 1
}

scan_status_for() {
  local pattern="$1"
  local scan_path="$2"
  local rg_status=0
  LC_ALL=C rg -a -i -q -- "$pattern" "$scan_path" \
    2>> "$private_root/rg.private" || rg_status=$?
  case "$rg_status" in 0) return 0 ;; 1) return 1 ;; *) printf '%s\n' UNVERIFIABLE_SURFACE_SCAN >&2; exit 2 ;; esac
}

scan_case_sensitive_status_for() {
  local pattern="$1"
  local scan_path="$2"
  local rg_status=0
  LC_ALL=C rg -a -q -- "$pattern" "$scan_path" \
    2>> "$private_root/rg.private" || rg_status=$?
  case "$rg_status" in 0) return 0 ;; 1) return 1 ;; *) printf '%s\n' UNVERIFIABLE_SURFACE_SCAN >&2; exit 2 ;; esac
}

scan_absolute_path_status_for() {
  local scan_path="$1"
  local relative_path="$2"
  local rg_status=0
  if [[ ! "$relative_path" =~ ^run-[0-9]+[.]log$ ]]; then
    scan_case_sensitive_status_for "$absolute_pattern" "$scan_path"
    return $?
  fi
  local hosted_action_absolute_pattern
  hosted_action_absolute_pattern="${users_prefix}(?!runner(?:/|[[:space:]]|$))[^/[:space:]]+|${home_prefix}[^/[:space:]]+|/private/(tmp|var)(/|[[:space:]])|/tmp(/|[[:space:]])|/Volumes(/|[[:space:]])"
  LC_ALL=C rg -a -q -P -- \
    "$hosted_action_absolute_pattern" \
    "$scan_path" 2>> "$private_root/rg.private" || rg_status=$?
  case "$rg_status" in 0) return 0 ;; 1) return 1 ;; *) printf '%s\n' UNVERIFIABLE_SURFACE_SCAN >&2; exit 2 ;; esac
}

scan_private_endpoint_status_for() {
  local scan_path="$1"
  local relative_path="$2"
  if [ "$surface_mode" != release-payload ]; then
    scan_status_for "$private_endpoint_pattern" "$scan_path"
    return $?
  fi

  test -x "$release_uri_classifier" || {
    printf '%s\n' UNVERIFIABLE_SURFACE_SCAN >&2
    exit 2
  }
  test ! -L "$release_uri_classifier" || {
    printf '%s\n' UNVERIFIABLE_SURFACE_SCAN >&2
    exit 2
  }
  local classification_output="$private_root/release-uri-classification"
  local classifier_status=0
  local classifier_args=(--no-allow-exact "$scan_path")
  if [ "$relative_path" = "$release_main_path" ]; then
    classifier_args=(--allow-exact "$scan_path")
  fi
  "$release_uri_classifier" "${classifier_args[@]}" \
    > "$classification_output" 2>> "$private_root/uri-classifier.private" \
    || classifier_status=$?
  local output_size output_lines classification
  output_size="$(/usr/bin/stat -f '%z' "$classification_output" \
    2>> "$private_root/stat.private")" || metadata_failure
  case "$output_size" in ''|*[!0-9]*) metadata_failure ;; esac
  [ "$output_size" -le 128 ] || {
    printf '%s\n' UNVERIFIABLE_SURFACE_SCAN >&2
    exit 2
  }
  output_lines="$(/usr/bin/awk 'END { print NR + 0 }' "$classification_output" \
    2>> "$private_root/awk.private")" || metadata_failure
  [ "$output_lines" -eq 1 ] || {
    printf '%s\n' UNVERIFIABLE_SURFACE_SCAN >&2
    exit 2
  }
  IFS= read -r classification < "$classification_output" || {
    printf '%s\n' UNVERIFIABLE_SURFACE_SCAN >&2
    exit 2
  }
  case "$classifier_status:$classification" in
    0:PASS) return 1 ;;
    1:PROHIBITED_PRIVATE_ENDPOINT) return 0 ;;
    2:UNVERIFIABLE_SURFACE_URI)
      report UNVERIFIABLE_SURFACE_URI "$relative_path"
      exit 2
      ;;
    *)
      printf '%s\n' UNVERIFIABLE_SURFACE_SCAN >&2
      exit 2
      ;;
  esac
}

scan_unmasked_credential_status_for() {
  local scan_path="$1"
  local rg_status=0
  LC_ALL=C rg -a -i -q -P -- \
    'Authorization:[[:space:]]*(Bearer|Basic)(?![[:space:]]+[*][*][*](?:[^*[:alnum:]]|$))' \
    "$scan_path" 2>> "$private_root/rg.private" || rg_status=$?
  case "$rg_status" in 0) return 0 ;; 1) return 1 ;; *) printf '%s\n' UNVERIFIABLE_SURFACE_SCAN >&2; exit 2 ;; esac
}

scan_email_status_for() {
  local scan_path="$1"
  local relative_path="$2"
  local email_matches="$private_root/emails"
  local email_status email
  : > "$email_matches"
  email_status=0
  LC_ALL=C rg -a -i -o --no-filename -- "$email_pattern" "$scan_path" \
    > "$email_matches" 2>> "$private_root/rg.private" || email_status=$?
  case "$email_status" in
    0)
      while IFS= read -r email; do
        if [ "$surface_mode" = release-payload ] &&
           [ "$relative_path" = GlideTranslate.app/Contents/Resources/Assets.car ] &&
           [[ "$email" =~ ^[A-Za-z0-9._-]+@[123]x[.]png$ ]]; then
          continue
        fi
        is_allowed_email "$email" || return 0
      done < "$email_matches"
      return 1
      ;;
    1) return 1 ;;
    *) printf '%s\n' UNVERIFIABLE_SURFACE_SCAN >&2; exit 2 ;;
  esac
}

scan_categories() {
  local scan_target="$1"
  local relative_path="$2"
  if scan_absolute_path_status_for "$scan_target" "$relative_path"; then report PROHIBITED_ABSOLUTE_PATH "$relative_path"; fi
  if scan_status_for "$agent_pattern" "$scan_target"; then report PROHIBITED_AGENT_SURFACE "$relative_path"; fi
  if scan_private_endpoint_status_for "$scan_target" "$relative_path"; then report PROHIBITED_PRIVATE_ENDPOINT "$relative_path"; fi
  if scan_status_for "$private_key_pattern" "$scan_target" || \
     scan_unmasked_credential_status_for "$scan_target"; then
    report PROHIBITED_CREDENTIAL_CONTENT "$relative_path"
  fi
  if scan_status_for "$content_marker_pattern" "$scan_target"; then report PROHIBITED_CONTENT_MARKER "$relative_path"; fi
  if scan_email_status_for "$scan_target" "$relative_path"; then report PROHIBITED_PUBLIC_IDENTITY "$relative_path"; fi
}

while IFS= read -r -d '' path; do
  relative_path="${path#"$surface_root"/}"
  relative_private="$private_root/relative-path"
  if ! printf '%s' "$relative_path" > "$relative_private"; then
    metadata_failure
  fi
  scan_categories "$relative_private" "$relative_path"

  lower_relative="$(/usr/bin/tr '[:upper:]' '[:lower:]' < "$relative_private")" || metadata_failure
  case "/$lower_relative/" in
    */.codex/*|*/.superpowers/*|*/docs/superpowers/*|*/agents.md/*|*/claude.md/*)
      report PROHIBITED_AGENT_SURFACE "$relative_path"
      ;;
  esac
  case "$lower_relative" in
    *.p12|*.pfx|*.key|*.mobileprovision|*.provisionprofile)
      report PROHIBITED_CREDENTIAL_SURFACE "$relative_path"
      ;;
    *.sqlite|*.sqlite-shm|*.sqlite-wal|*.db|*/runtime/*|runtime/*)
      report PROHIBITED_RUNTIME_SURFACE "$relative_path"
      ;;
    *.log)
      if [[ ! "$lower_relative" =~ ^run-[0-9]+[.]log$ ]]; then
        report PROHIBITED_RUNTIME_SURFACE "$relative_path"
      fi
      ;;
    *.gguf|*.safetensors|*/models/*|models/*|*/model-cache/*|model-cache/*)
      report PROHIBITED_MODEL_SURFACE "$relative_path"
      ;;
  esac

  kind="$(/usr/bin/stat -f '%HT' "$path" 2>> "$private_root/stat.private")" || metadata_failure
  if [ -L "$path" ]; then
    report PROHIBITED_SURFACE_SYMLINK "$relative_path"
    continue
  fi
  if [ -d "$path" ]; then
    test "$kind" = Directory || metadata_failure
    continue
  fi
  if [ ! -f "$path" ]; then
    report PROHIBITED_SURFACE_SPECIAL_FILE "$relative_path"
    continue
  fi
  test "$kind" = "Regular File" || metadata_failure

  size="$(/usr/bin/stat -f '%z' "$path" 2>> "$private_root/stat.private")" || metadata_failure
  case "$size" in ''|*[!0-9]*) metadata_failure ;; esac
  if [ "$size" -gt 67108864 ]; then
    report OVERSIZED_SURFACE "$relative_path"
    continue
  fi
  file_kind="$(/usr/bin/file -b "$path" 2>> "$private_root/file.private")" || {
    printf '%s\n' UNVERIFIABLE_SURFACE_TYPE >&2
    exit 2
  }
  case "$file_kind" in
    *ASCII\ text*|*UTF-8\ Unicode\ text*|*Unicode\ text*|*JSON*|*XML*|*property\ list*|*Zip\ archive*|*gzip\ compressed*|*tar\ archive*|*Mach-O*|*empty*) ;;
    *Mac\ OS\ X\ icon*)
      if [ "$surface_mode" != release-payload ] ||
         [ "$relative_path" != GlideTranslate.app/Contents/Resources/AppIcon.icns ]; then
        report UNVERIFIABLE_SURFACE_TYPE "$relative_path"
        continue
      fi
      ;;
    *Mac\ OS\ X\ bill\ of\ materials*)
      if [ "$surface_mode" != release-payload ] ||
         [ "$relative_path" != GlideTranslate.app/Contents/Resources/Assets.car ]; then
        report UNVERIFIABLE_SURFACE_TYPE "$relative_path"
        continue
      fi
      ;;
    *) report UNVERIFIABLE_SURFACE_TYPE "$relative_path"; continue ;;
  esac
  scan_categories "$path" "$relative_path"
done < "$entries"

test "$finding_count" -eq 0 || exit 1
printf '%s\n' EXTERNAL_SURFACE_SCAN_PASSED
