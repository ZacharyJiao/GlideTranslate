#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

candidate_input="${1:-.}"
architecture_root="$(mktemp -d)"
trap '/bin/rm -rf "$architecture_root"' EXIT

if ! candidate_root="$(cd "$candidate_input" 2> "$architecture_root/root.private" && pwd)"; then
  printf '%s\n' ARCHITECTURE_SCAN_ROOT_MISSING >&2
  exit 2
fi
test -d "$candidate_root/Sources" || {
  printf '%s\n' ARCHITECTURE_SCAN_ROOT_MISSING >&2
  exit 2
}

scan_paths=("$candidate_root/Sources")
if test -d "$candidate_root/App"; then
  scan_paths+=("$candidate_root/App")
fi

relative_path() {
  path="$1"
  case "$path" in
    "$candidate_root"/*) relative="${path#"$candidate_root"/}" ;;
    *) printf '%s\n' ARCHITECTURE_PATH_INVALID >&2; exit 2 ;;
  esac
  case "$relative" in
    ''|/*|..|../*|*/../*|*[[:cntrl:]]*)
      printf '%s\n' ARCHITECTURE_PATH_INVALID >&2
      exit 2
      ;;
  esac
  printf '%s\n' "$relative"
}

scan_rule() {
  pattern="$1"
  category="$2"
  allowed_pattern="$3"
  matches="$architecture_root/$category.matches"
  rg_status=0
  rg -l --multiline --hidden --glob '*.swift' --regexp "$pattern" "${scan_paths[@]}" \
    > "$matches" 2> "$architecture_root/$category.rg.private" || rg_status=$?
  case "$rg_status" in
    0|1) ;;
    *) printf '%s\n' ARCHITECTURE_SCAN_FAILED >&2; exit 2 ;;
  esac

  while IFS= read -r path; do
    test -n "$path" || continue
    relative="$(relative_path "$path")"
    filter_status=0
    printf '%s\n' "$relative" | rg -q --regexp "$allowed_pattern" \
      || filter_status=$?
    case "$filter_status" in
      0) ;;
      1)
        printf '%s:%s\n' "$category" "$relative" >&2
        finding=1
        ;;
      *) printf '%s\n' ARCHITECTURE_SCAN_FAILED >&2; exit 2 ;;
    esac
  done < "$matches"
}

scan_coordinator_identity_parameters() {
  coordinator="$candidate_root/App/GlideTranslate/Coordinator/AppCoordinator.swift"
  test -f "$coordinator" || return 0
  matches="$architecture_root/coordinator-identity.matches"
  rg_status=0
  rg -n --regexp '\bApplicationIdentity\b' "$coordinator" > "$matches" \
    2> "$architecture_root/coordinator-identity.rg.private" \
    || rg_status=$?
  case "$rg_status" in
    0|1) ;;
    *) printf '%s\n' ARCHITECTURE_SCAN_FAILED >&2; exit 2 ;;
  esac
  while IFS= read -r match; do
    test -n "$match" || continue
    source_line="${match#*:}"
    allowed_status=0
    printf '%s\n' "$source_line" | rg -q \
      '^[[:space:]]*let trustedSourceApplication:[[:space:]]*ApplicationIdentity[?][[:space:]]*$' \
      || allowed_status=$?
    case "$allowed_status" in
      0) ;;
      1)
        printf '%s:%s\n' COORDINATOR_CALLER_IDENTITY_INJECTION \
          App/GlideTranslate/Coordinator/AppCoordinator.swift >&2
        finding=1
        ;;
      *) printf '%s\n' ARCHITECTURE_SCAN_FAILED >&2; exit 2 ;;
    esac
  done < "$matches"
}

finding=0
scan_rule \
  'mintAfterAuthorization' \
  UNAUTHORIZED_INTENT_MINT \
  '^(Sources/(SelectionCapture/|SharedSupport/Authorization/AuthorizedTranslationIntent[.]swift$)|App/GlideTranslateTests/AppCoordinatorAuthorizationTests[.]swift$)'
scan_rule \
  '\bmintAfterPromptValidation\b' \
  UNAUTHORIZED_VALIDATED_PRESET_MINT \
  '^(Sources/(SharedSupport/Domain/PresetTypes[.]swift$|TranslationCore/Prompt/(PresetValidator|DefaultPromptPresetValidationService)[.]swift$)|App/GlideTranslateTests/AppCoordinatorAuthorizationTests[.]swift$)'
scan_rule \
  '[.]authorizeSystemSelection\b' \
  UNAUTHORIZED_SYSTEM_AUTHORIZATION \
  '^Sources/SelectionCapture/'
scan_rule \
  '[.]payload\b' \
  UNAUTHORIZED_INTENT_PAYLOAD_READ \
  '^(Sources/(SharedSupport/Authorization/AuthorizedTranslationIntent[.]swift$|SelectionCapture/|TranslationCore/)|App/GlideTranslateTests/AppCoordinatorAuthorizationTests[.]swift$)'
scan_rule \
  'mintAfterResolution' \
  UNAUTHORIZED_DESTINATION_SNAPSHOT_MINT \
  '^(Sources/(SharedSupport/Domain/ProviderTypes[.]swift$|ModelProviders/Destination/)|App/GlideTranslateTests/AppCoordinatorAuthorizationTests[.]swift$)'
scan_rule \
  'ProviderDestinationSnapshot[[:space:]]*\(' \
  UNAUTHORIZED_DESTINATION_SNAPSHOT_INIT \
  '^Sources/(SharedSupport/Domain/ProviderTypes[.]swift$|ModelProviders/Destination/)'
scan_rule \
  'ProviderDestinationSnapshot[[:space:]]*[.][[:space:]]*init[[:space:]]*\(' \
  UNAUTHORIZED_DESTINATION_SNAPSHOT_INIT \
  '^Sources/(SharedSupport/Domain/ProviderTypes[.]swift$|ModelProviders/Destination/)'
scan_rule \
  '[.]init[[:space:]]*\([[:space:]]*configurationID[[:space:]]*:' \
  UNAUTHORIZED_DESTINATION_SNAPSHOT_INIT \
  '^Sources/(SharedSupport/Domain/ProviderTypes[.]swift$|ModelProviders/Destination/)'
scan_rule \
  '\bModelProviders\b' \
  PRIVACY_STORAGE_REVERSE_DEPENDENCY \
  '^(Sources/(SharedSupport/|SelectionCapture/|ModelProviders/|TranslationCore/)|App/)'
scan_rule \
  '\bwithCredentialLease\b' \
  UNAUTHORIZED_CREDENTIAL_LEASE_USE \
  '^Sources/(ModelProviders/|PrivacyStorage/ProviderVault/)'
scan_rule \
  '\bwithValidatedDestination\b' \
  UNAUTHORIZED_DESTINATION_VALIDATION_USE \
  '^Sources/(ModelProviders/|PrivacyStorage/ProviderVault/)'
scan_rule \
  '\bCredentialHeaderValue\b' \
  UNAUTHORIZED_CREDENTIAL_VALUE_USE \
  '^Sources/(PrivacyStorage/ProviderVault/|ModelProviders/Transport/ProviderTransportRequest[.]swift$)'
scan_rule \
  '\bRedirectDestinationSnapshotMinter\b' \
  UNAUTHORIZED_REDIRECT_SNAPSHOT_MINT \
  '^Sources/ModelProviders/(Destination/DefaultProviderPreflight[.]swift$|Transport/RedirectingTransport[.]swift$)'
scan_rule \
  '\bDefaultProviderService\b' \
  UNAUTHORIZED_PROVIDER_SERVICE_COMPOSITION \
  '^Sources/ModelProviders/Public/(DefaultProviderService|ModelProviderFactory)[.]swift$'
scan_coordinator_identity_parameters

exit "$finding"
