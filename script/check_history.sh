#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C
repository="${1:-$(git rev-parse --show-toplevel)}"
repository="$(cd "$repository" && pwd)"
history_root="$(mktemp -d)"
trap '/bin/rm -rf "$history_root"' EXIT

check_history_content_object() {
  repository="$1"; object="$2"; commit="$3"; relative_path="$4"
  object_file="$(mktemp "$history_root/object.XXXXXX")"
  if ! git -C "$repository" cat-file blob "$object" > "$object_file" 2> "$history_root/cat-file.private"; then
    /bin/rm -f "$object_file"; printf 'HISTORY_OBJECT_READ_FAILED:%s:%s\n' "$commit" "$relative_path" >&2; exit 2
  fi
  users_prefix='/'"Users/"; home_prefix='/'"home/"
  content_pattern="${users_prefix}[^/[:space:]]+|${home_prefix}[^/[:space:]]+|https?://[^/@[:space:]]+:[^/@[:space:]]+@|https?://(10[.]|169[.]254[.]|172[.](1[6-9]|2[0-9]|3[01])[.]|192[.]168[.])|BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY|Authorization:[[:space:]]*(Bearer|Basic)"
  rg_status=0
  LC_ALL=C rg -a -q --regexp "$content_pattern" "$object_file" 2> "$history_root/rg.private" || rg_status=$?
  case "$rg_status" in
    0) /bin/rm -f "$object_file"; printf 'HISTORY_PROHIBITED_CONTENT:%s:%s\n' "$commit" "$relative_path" >&2; exit 1;;
    1) ;;
    *) /bin/rm -f "$object_file"; printf 'HISTORY_CONTENT_SCAN_FAILED:%s:%s\n' "$commit" "$relative_path" >&2; exit 2;;
  esac
  loopback_pattern='https?://127[.]0[.]0[.]1(:[0-9]+)?'
  case "$relative_path" in Sources/SharedSupport/Domain/ProviderTypes.swift|Sources/ModelProviders/*|Tests/ModelProvidersTests/*|App/GlideTranslate/Onboarding/*|App/GlideTranslate/Settings/*|Sources/PrivacyStorage/ProviderVault/*|Tests/PrivacyStorageTests/OffDeviceAuthorizationTests.swift|Tests/PrivacyStorageTests/PrivacyStorageFactoryTests.swift|Tests/PrivacyStorageTests/ProviderMetadataRepositoryTests.swift|Tests/PrivacyStorageTests/ProviderVaultHandleTests.swift|Tests/PrivacyStorageTests/ProviderVaultStateMachineTests.swift|script/check_local_ollama_preflight.sh) ;;
    *)
      rg_status=0
      LC_ALL=C rg -a -q --regexp "$loopback_pattern" "$object_file" 2>> "$history_root/rg.private" || rg_status=$?
      case "$rg_status" in
        0) /bin/rm -f "$object_file"; printf 'HISTORY_PROHIBITED_CONTENT:%s:%s\n' "$commit" "$relative_path" >&2; exit 1;;
        1) ;;
        *) /bin/rm -f "$object_file"; printf 'HISTORY_CONTENT_SCAN_FAILED:%s:%s\n' "$commit" "$relative_path" >&2; exit 2;;
      esac;;
  esac
  /bin/rm -f "$object_file"
}

commit_metadata="$history_root/commit-metadata"
commits="$history_root/commits"
git -C "$repository" log --all --format='%H%x09%aE%x09%cE%x09%s' > "$commit_metadata" 2> "$history_root/log.private" || { printf '%s\n' HISTORY_ENUMERATION_FAILED >&2; exit 2; }
/usr/bin/awk -F '\t' '$2 !~ /@users[.]noreply[.]github[.]com$/ || $3 !~ /@users[.]noreply[.]github[.]com$/ {print "UNSAFE_COMMIT_IDENTITY:" $1 > "/dev/stderr"; bad=1} /\/Users\/|\/home\// {print "UNSAFE_COMMIT_MESSAGE:" $1 > "/dev/stderr"; bad=1} END {exit bad}' "$commit_metadata"
git -C "$repository" rev-list --all > "$commits" 2> "$history_root/rev-list.private" || { printf '%s\n' HISTORY_ENUMERATION_FAILED >&2; exit 2; }
while IFS= read -r commit; do
  tree_inventory="$history_root/tree-$commit"
  git -C "$repository" ls-tree -rlz "$commit" > "$tree_inventory" 2> "$history_root/ls-tree.private" || { printf 'HISTORY_TREE_ENUMERATION_FAILED:%s\n' "$commit" >&2; exit 2; }
  if [ -s "$tree_inventory" ]; then
    if ! final_byte="$(/usr/bin/tail -c 1 "$tree_inventory" 2>> "$history_root/helpers.private" | /usr/bin/od -An -tu1 2>> "$history_root/helpers.private" | /usr/bin/tr -d '[:space:]' 2>> "$history_root/helpers.private")" || [ "$final_byte" != 0 ]; then
      printf 'HISTORY_TREE_ENUMERATION_FAILED:%s\n' "$commit" >&2; exit 2
    fi
  fi
  while IFS= read -r -d '' entry; do
    metadata="${entry%%$'\t'*}"; relative_path="${entry#*$'\t'}"
    if [[ ! "$metadata" =~ ^(100644|100755|120000|160000)[[:space:]](blob|commit)[[:space:]][0-9a-f]{40}[[:space:]]+([0-9]+|-)$ ]] || [ "$relative_path" = "$entry" ]; then
      printf 'HISTORY_TREE_ENUMERATION_FAILED:%s\n' "$commit" >&2; exit 2
    fi
    case "$relative_path" in ''|/*|.|..|./*|../*|*/./*|*/../*|*[[:cntrl:]]*) printf 'HISTORY_PROHIBITED_PATH_ENCODING:%s\n' "$commit" >&2; exit 1;; esac
    mode="${metadata%% *}"; rest="${metadata#* }"; type="${rest%% *}"; rest="${rest#* }"; object="${rest%% *}"; size="${rest##* }"
    case "$mode:$type:$size" in
      100644:blob:*|100755:blob:*|120000:blob:*)
        case "$size" in ''|*[!0-9]*) printf 'HISTORY_TREE_ENUMERATION_FAILED:%s\n' "$commit" >&2; exit 2;; esac
        ;;
      160000:commit:-) ;;
      *) printf 'HISTORY_TREE_ENUMERATION_FAILED:%s\n' "$commit" >&2; exit 2 ;;
    esac
    case "/$relative_path" in /docs/superpowers/*|/.codex/*|/.superpowers/*|*/xcuserdata/*|*.xcarchive/*) printf 'HISTORY_PROHIBITED_PATH:%s:%s\n' "$commit" "$relative_path" >&2; exit 1;; esac
    case "$relative_path" in .env|.env.*|*/.env|*/.env.*|*.sqlite|*.sqlite-shm|*.sqlite-wal|*.log|*.p12|*.provisionprofile|*.mobileprovision|*.gguf) printf 'HISTORY_PROHIBITED_EXTENSION:%s:%s\n' "$commit" "$relative_path" >&2; exit 1;; esac
    if [ "$mode" = 120000 ]; then printf 'HISTORY_PROHIBITED_SYMLINK:%s:%s\n' "$commit" "$relative_path" >&2; exit 1; fi
    [ "$type" = blob ] || continue
    if [ "$size" -gt 10485760 ]; then printf 'HISTORY_OVERSIZED_BLOB:%s:%s\n' "$commit" "$relative_path" >&2; exit 1; fi
    check_history_content_object "$repository" "$object" "$commit" "$relative_path"
  done < "$tree_inventory"
done < "$commits"
gitleaks_report="$history_root/gitleaks.json"
gitleaks git --no-banner --redact --exit-code 0 --report-format json \
  --report-path "$gitleaks_report" "$repository" \
  >/dev/null 2> "$history_root/gitleaks.private" || {
  printf '%s\n' HISTORY_GITLEAKS_FAILED >&2; exit 2;
}
if ! jq -s -e 'length == 1 and (.[0] | type == "array")' "$gitleaks_report" >/dev/null 2> "$history_root/gitleaks-jq.private"; then
  printf '%s\n' HISTORY_GITLEAKS_FAILED >&2; exit 2
fi
if ! jq -s -e '.[0] | length == 0' "$gitleaks_report" >/dev/null 2>> "$history_root/gitleaks-jq.private"; then
  printf '%s\n' HISTORY_GITLEAKS_FINDING >&2; exit 1
fi
