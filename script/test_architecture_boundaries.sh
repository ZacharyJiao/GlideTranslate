#!/usr/bin/env bash
set -euo pipefail

workspace_root="$(cd "$(dirname "$0")/.." && pwd)"
checker="$workspace_root/script/check_architecture_boundaries.sh"
fixture_root="$(mktemp -d)"
trap '/bin/rm -rf "$fixture_root"' EXIT

make_root() {
  root="$1"
  /bin/mkdir -p \
    "$root/Sources/SharedSupport/Authorization" \
    "$root/Sources/SharedSupport/Domain" \
    "$root/Sources/SelectionCapture/Authorization" \
    "$root/Sources/TranslationCore/Engine" \
    "$root/Sources/TranslationCore/Prompt" \
    "$root/Sources/ModelProviders/Destination" \
    "$root/Sources/ModelProviders/Transport" \
    "$root/Sources/PrivacyStorage/ProviderVault" \
    "$root/App/GlideTranslate/Coordinator" \
    "$root/App/Fixture"
  printf '%s\n' \
    'struct AuthorizedTranslationIntent {' \
    '  static func mintAfterAuthorization() {}' \
    '  let payload: String' \
    '}' > "$root/Sources/SharedSupport/Authorization/AuthorizedTranslationIntent.swift"
  printf '%s\n' \
    'struct ProviderDestinationSnapshot {' \
    '  init() {}' \
    '  static func mintAfterResolution() -> Self { Self() }' \
    '}' > "$root/Sources/SharedSupport/Domain/ProviderTypes.swift"
  printf '%s\n' \
    'struct ValidatedPromptPreset {' \
    '  static func mintAfterPromptValidation() -> Self { Self() }' \
    '}' > "$root/Sources/SharedSupport/Domain/PresetTypes.swift"
}

allowed="$fixture_root/allowed"
make_root "$allowed"
printf '%s\n' \
  'func build() {' \
  '  AuthorizedTranslationIntent.mintAfterAuthorization()' \
  '}' > "$allowed/Sources/SelectionCapture/Authorization/Gate.swift"
printf '%s\n' \
  'func consume(_ intent: AuthorizedTranslationIntent) {' \
  '  _ = intent.payload' \
  '}' > "$allowed/Sources/TranslationCore/Engine.swift"
printf '%s\n' \
  'func validatePreset() {' \
  '  _ = ValidatedPromptPreset.mintAfterPromptValidation()' \
  '}' > "$allowed/Sources/TranslationCore/Prompt/PresetValidator.swift"
printf '%s\n' \
  'func render(_ preset: ValidatedPromptPreset) {' \
  '  _ = preset.id' \
  '}' > "$allowed/App/Fixture/PresetView.swift"
printf '%s\n' \
  'func resolve() {' \
  '  _ = ProviderDestinationSnapshot.mintAfterResolution()' \
  '  _ = ProviderDestinationSnapshot()' \
  '}' > "$allowed/Sources/ModelProviders/Destination/Preflight.swift"
printf '%s\n' \
  'struct CredentialHeaderValue {}' \
  'protocol ProviderAccess {' \
  '  func withValidatedDestination()' \
  '  func withCredentialLease()' \
  '}' > "$allowed/Sources/PrivacyStorage/ProviderVault/ProviderAccess.swift"
printf '%s\n' \
  'func apply(_ access: ProviderAccess) {' \
  '  access.withValidatedDestination()' \
  '  access.withCredentialLease()' \
  '}' \
  'extension Request {' \
  '  func set(_ value: CredentialHeaderValue) {}' \
  '}' > "$allowed/Sources/ModelProviders/Transport/ProviderTransportRequest.swift"
"$checker" "$allowed"

assert_rejected() {
  name="$1"
  category="$2"
  relative_path="$3"
  source_line="$4"
  root="$fixture_root/$name"
  make_root "$root"
  printf '%s\n' "$source_line" > "$root/$relative_path"
  status=0
  "$checker" "$root" > "$fixture_root/$name.out" 2>&1 || status=$?
  if test "$status" -eq 0; then
    printf 'ARCHITECTURE_CASE_UNEXPECTED_PASS:%s\n' "$name" >&2
    exit 1
  fi
  test "$status" -eq 1
  rg -q "^${category}:" "$fixture_root/$name.out"
  ! rg -q "$fixture_root" "$fixture_root/$name.out"
}

assert_rejected mint-outside UNAUTHORIZED_INTENT_MINT \
  Sources/TranslationCore/Bad.swift \
  'func bad() { AuthorizedTranslationIntent.mintAfterAuthorization() }'
assert_rejected preset-mint-outside UNAUTHORIZED_VALIDATED_PRESET_MINT \
  Sources/SelectionCapture/Authorization/Bad.swift \
  'func bad() { _ = ValidatedPromptPreset.mintAfterPromptValidation() }'
assert_rejected preset-mint-app UNAUTHORIZED_VALIDATED_PRESET_MINT \
  App/Fixture/Bad.swift \
  'func bad() { _ = ValidatedPromptPreset.mintAfterPromptValidation() }'
assert_rejected preset-mint-unrelated-core UNAUTHORIZED_VALIDATED_PRESET_MINT \
  Sources/TranslationCore/Engine/Bad.swift \
  'func bad() { _ = ValidatedPromptPreset.mintAfterPromptValidation() }'
assert_rejected preset-mint-inferred UNAUTHORIZED_VALIDATED_PRESET_MINT \
  Sources/ModelProviders/Bad.swift \
  'func bad() -> ValidatedPromptPreset { .mintAfterPromptValidation() }'
assert_rejected preset-mint-alias UNAUTHORIZED_VALIDATED_PRESET_MINT \
  Sources/PrivacyStorage/Bad.swift \
  'typealias Preset = ValidatedPromptPreset; func bad() { _ = Preset.mintAfterPromptValidation() }'
assert_rejected app-system-gate UNAUTHORIZED_SYSTEM_AUTHORIZATION \
  App/Fixture/Bad.swift \
  'func bad(_ gate: SelectionAuthorizationGate) async { _ = await gate.authorizeSystemSelection() }'
assert_rejected app-system-reference UNAUTHORIZED_SYSTEM_AUTHORIZATION \
  App/Fixture/Bad.swift \
  'func bad(_ gate: SelectionAuthorizationGate) { let authorize = gate.authorizeSystemSelection }'
assert_rejected coordinator-identity-parameter COORDINATOR_CALLER_IDENTITY_INJECTION \
  App/GlideTranslate/Coordinator/AppCoordinator.swift \
  $'func start(\n  sourceApplication: ApplicationIdentity?\n) {}'
assert_rejected coordinator-inline-identity-parameter COORDINATOR_CALLER_IDENTITY_INJECTION \
  App/GlideTranslate/Coordinator/AppCoordinator.swift \
  'func start(sourceApplication: ApplicationIdentity?) {}'
assert_rejected coordinator-labeled-identity-parameter COORDINATOR_CALLER_IDENTITY_INJECTION \
  App/GlideTranslate/Coordinator/AppCoordinator.swift \
  'func start(_ sourceApplication: ApplicationIdentity?) {}'
assert_rejected app-payload UNAUTHORIZED_INTENT_PAYLOAD_READ \
  App/Fixture/Bad.swift \
  'func bad(_ intent: AuthorizedTranslationIntent) { _ = intent.payload }'
assert_rejected provider-payload UNAUTHORIZED_INTENT_PAYLOAD_READ \
  Sources/ModelProviders/Bad.swift \
  'func bad(_ intent: AuthorizedTranslationIntent) { _ = intent.payload }'
assert_rejected storage-payload UNAUTHORIZED_INTENT_PAYLOAD_READ \
  Sources/PrivacyStorage/Bad.swift \
  'func bad(_ intent: AuthorizedTranslationIntent) { _ = intent.payload }'
assert_rejected app-optional-payload UNAUTHORIZED_INTENT_PAYLOAD_READ \
  App/Fixture/Bad.swift \
  'func bad(_ intent: AuthorizedTranslationIntent?) { _ = intent?.payload }'
assert_rejected app-subscript-payload UNAUTHORIZED_INTENT_PAYLOAD_READ \
  App/Fixture/Bad.swift \
  'func bad(_ intents: [AuthorizedTranslationIntent]) { _ = intents[0].payload }'
assert_rejected app-call-payload UNAUTHORIZED_INTENT_PAYLOAD_READ \
  App/Fixture/Bad.swift \
  'func bad() { _ = makeIntent().payload }'
assert_rejected app-parenthesized-payload UNAUTHORIZED_INTENT_PAYLOAD_READ \
  App/Fixture/Bad.swift \
  'func bad(_ intent: AuthorizedTranslationIntent) { _ = (intent).payload }'
assert_rejected app-keypath-payload UNAUTHORIZED_INTENT_PAYLOAD_READ \
  App/Fixture/Bad.swift \
  'let bad = \AuthorizedTranslationIntent.payload'
assert_rejected provider-arbitrary-name-payload UNAUTHORIZED_INTENT_PAYLOAD_READ \
  Sources/ModelProviders/Bad.swift \
  'func bad(_ authorized: AuthorizedTranslationIntent) { _ = authorized.payload }'
assert_rejected storage-arbitrary-call-payload UNAUTHORIZED_INTENT_PAYLOAD_READ \
  Sources/PrivacyStorage/Bad.swift \
  'func bad() { _ = loadAuthorized().payload }'
assert_rejected app-destination-mint UNAUTHORIZED_DESTINATION_SNAPSHOT_MINT \
  App/Fixture/Bad.swift \
  'func bad() { _ = ProviderDestinationSnapshot.mintAfterResolution() }'
assert_rejected selection-destination-init UNAUTHORIZED_DESTINATION_SNAPSHOT_INIT \
  Sources/SelectionCapture/Authorization/Bad.swift \
  'func bad() { _ = ProviderDestinationSnapshot() }'
assert_rejected multiline-destination-init UNAUTHORIZED_DESTINATION_SNAPSHOT_INIT \
  Sources/TranslationCore/Bad.swift \
  $'func bad() { _ = ProviderDestinationSnapshot\n() }'
assert_rejected qualified-destination-init UNAUTHORIZED_DESTINATION_SNAPSHOT_INIT \
  Sources/TranslationCore/Bad.swift \
  'func bad() { _ = ProviderDestinationSnapshot.init(configurationID: id, privacyClass: kind, configurationRevision: 1, confirmationRevision: 1, origin: origin, resolutionFingerprint: [], protocolKind: protocolKind, model: model) }'
assert_rejected inferred-destination-init UNAUTHORIZED_DESTINATION_SNAPSHOT_INIT \
  Sources/SelectionCapture/Authorization/Bad.swift \
  'let bad: ProviderDestinationSnapshot = .init(configurationID: id, privacyClass: kind, configurationRevision: 1, confirmationRevision: 1, origin: origin, resolutionFingerprint: [], protocolKind: protocolKind, model: model)'

assert_snapshot_alias_does_not_compile() {
  name="$1"
  alias_declaration="$2"
  constructor_name="$3"
  source="$fixture_root/$name.swift"
  module_path="$(find "$workspace_root/.build" -path '*/debug/Modules/SharedSupport.swiftmodule' -print -quit)"
  if test -z "$module_path"; then
    printf 'ARCHITECTURE_SHARED_SUPPORT_MODULE_MISSING\n' >&2
    exit 2
  fi
  module_dir="$(dirname "$module_path")"
  printf '%s\n' \
    'package import SharedSupport' \
    "$alias_declaration" \
    'func forge(id: ProviderConfigurationID, kind: DestinationPrivacyClass, origin: ProviderOrigin, protocolKind: ProviderProtocolKind) -> ProviderDestinationSnapshot {' \
    "  $constructor_name(configurationID: id, privacyClass: kind, configurationRevision: 1, confirmationRevision: 1, origin: origin, resolutionFingerprint: [], protocolKind: protocolKind, model: \"model\")" \
    '}' > "$source"
  status=0
  xcrun swiftc -typecheck -swift-version 6 -package-name glidetranslate \
    -I "$module_dir" "$source" > "$fixture_root/$name.compile.out" 2>&1 \
    || status=$?
  if test "$status" -eq 0; then
    printf 'ARCHITECTURE_ALIAS_CONSTRUCTOR_UNEXPECTED_PASS:%s\n' "$name" >&2
    exit 1
  fi
}

assert_snapshot_alias_does_not_compile \
  direct-destination-alias \
  'typealias ForgedDestinationSnapshot = ProviderDestinationSnapshot' \
  'ForgedDestinationSnapshot'
assert_snapshot_alias_does_not_compile \
  generic-destination-alias \
  'typealias Identity<T> = T' \
  'Identity<ProviderDestinationSnapshot>'

assert_rejected storage-destination-mint UNAUTHORIZED_DESTINATION_SNAPSHOT_MINT \
  Sources/PrivacyStorage/Bad.swift \
  'func bad() { _ = ProviderDestinationSnapshot.mintAfterResolution() }'
assert_rejected storage-reverse-import PRIVACY_STORAGE_REVERSE_DEPENDENCY \
  Sources/PrivacyStorage/Bad.swift \
  'import ModelProviders'
assert_rejected storage-implementation-only-import PRIVACY_STORAGE_REVERSE_DEPENDENCY \
  Sources/PrivacyStorage/Bad.swift \
  '@_implementationOnly import ModelProviders'
assert_rejected storage-private-import PRIVACY_STORAGE_REVERSE_DEPENDENCY \
  Sources/PrivacyStorage/Bad.swift \
  'private import ModelProviders'
assert_rejected storage-package-import PRIVACY_STORAGE_REVERSE_DEPENDENCY \
  Sources/PrivacyStorage/Bad.swift \
  'package import ModelProviders'
assert_rejected storage-comment-separated-import PRIVACY_STORAGE_REVERSE_DEPENDENCY \
  Sources/PrivacyStorage/Bad.swift \
  'private/* boundary */ import ModelProviders'
assert_rejected storage-semicolon-import PRIVACY_STORAGE_REVERSE_DEPENDENCY \
  Sources/PrivacyStorage/Bad.swift \
  'import PrivacyStorage; import ModelProviders'
assert_rejected app-credential-lease UNAUTHORIZED_CREDENTIAL_LEASE_USE \
  App/Fixture/Bad.swift \
  'func bad(_ access: ProviderAccess) async throws { try await access.withCredentialLease() }'
assert_rejected app-destination-validation UNAUTHORIZED_DESTINATION_VALIDATION_USE \
  App/Fixture/Bad.swift \
  'func bad(_ access: ProviderAccess) async throws { try await access.withValidatedDestination() }'
assert_rejected app-spaced-credential-lease UNAUTHORIZED_CREDENTIAL_LEASE_USE \
  App/Fixture/Bad.swift \
  'func bad(_ access: ProviderAccess) async throws { try await access . withCredentialLease() }'
assert_rejected app-post-comment-credential-lease UNAUTHORIZED_CREDENTIAL_LEASE_USE \
  App/Fixture/Bad.swift \
  'func bad(_ access: ProviderAccess) async throws { try await access.withCredentialLease /* boundary */ () }'
assert_rejected app-backticked-credential-lease UNAUTHORIZED_CREDENTIAL_LEASE_USE \
  App/Fixture/Bad.swift \
  'func bad(_ access: ProviderAccess) async throws { try await access.`withCredentialLease`() }'
assert_rejected shared-commented-credential-lease UNAUTHORIZED_CREDENTIAL_LEASE_USE \
  Sources/SharedSupport/Bad.swift \
  'func bad(_ access: ProviderAccess) async throws { try await access/* boundary */.withCredentialLease() }'
assert_rejected selection-spaced-credential-lease UNAUTHORIZED_CREDENTIAL_LEASE_USE \
  Sources/SelectionCapture/Bad.swift \
  'func bad(_ access: ProviderAccess) async throws { try await access . withCredentialLease() }'
assert_rejected translation-spaced-credential-lease UNAUTHORIZED_CREDENTIAL_LEASE_USE \
  Sources/TranslationCore/Bad.swift \
  'func bad(_ access: ProviderAccess) async throws { try await access . withCredentialLease() }'
assert_rejected storage-unrelated-spaced-credential-lease UNAUTHORIZED_CREDENTIAL_LEASE_USE \
  Sources/PrivacyStorage/Bad.swift \
  'func bad(_ access: ProviderAccess) async throws { try await access . withCredentialLease() }'
assert_rejected storage-unrelated-credential-value UNAUTHORIZED_CREDENTIAL_VALUE_USE \
  Sources/PrivacyStorage/Bad.swift \
  'func bad(_ value: CredentialHeaderValue) {}'
assert_rejected provider-unrelated-credential-value UNAUTHORIZED_CREDENTIAL_VALUE_USE \
  Sources/ModelProviders/Bad.swift \
  'func bad(_ value: CredentialHeaderValue) {}'
assert_rejected provider-unapproved-redirect-mint UNAUTHORIZED_REDIRECT_SNAPSHOT_MINT \
  Sources/ModelProviders/Bad.swift \
  'func bad() { _ = RedirectDestinationSnapshotMinter.mint(previous: old, endpoint: endpoint, addresses: addresses) }'
assert_rejected provider-unapproved-service-composition UNAUTHORIZED_PROVIDER_SERVICE_COMPOSITION \
  Sources/ModelProviders/Bad.swift \
  'func bad() { _ = DefaultProviderService(preflight: p, access: a, ollama: o, compatible: c) }'
assert_rejected provider-qualified-service-composition UNAUTHORIZED_PROVIDER_SERVICE_COMPOSITION \
  Sources/ModelProviders/Bad.swift \
  'func bad() { _ = DefaultProviderService.init(preflight: p, access: a, ollama: o, compatible: c) }'
assert_rejected provider-inferred-service-composition UNAUTHORIZED_PROVIDER_SERVICE_COMPOSITION \
  Sources/ModelProviders/Bad.swift \
  'let bad: DefaultProviderService = .init(preflight: p, access: a, ollama: o, compatible: c)'
assert_rejected provider-multiline-service-composition UNAUTHORIZED_PROVIDER_SERVICE_COMPOSITION \
  Sources/ModelProviders/Bad.swift \
  $'func bad() { _ = DefaultProviderService\n(preflight: p, access: a, ollama: o, compatible: c) }'
assert_rejected provider-aliased-service-composition UNAUTHORIZED_PROVIDER_SERVICE_COMPOSITION \
  Sources/ModelProviders/Bad.swift \
  'typealias AlternateService = DefaultProviderService'

missing="$fixture_root/missing"
/bin/mkdir -p "$missing"
status=0
"$checker" "$missing" > "$fixture_root/missing.out" 2>&1 || status=$?
if test "$status" -eq 0; then
  printf '%s\n' ARCHITECTURE_MISSING_ROOT_UNEXPECTED_PASS >&2
  exit 1
fi
test "$status" -eq 2
rg -q '^ARCHITECTURE_SCAN_ROOT_MISSING$' "$fixture_root/missing.out"

failing_bin="$fixture_root/failing-bin"
/bin/mkdir -p "$failing_bin"
printf '%s\n' '#!/usr/bin/env bash' 'exit 2' > "$failing_bin/rg"
chmod +x "$failing_bin/rg"
status=0
PATH="$failing_bin:$PATH" "$checker" "$allowed" \
  > "$fixture_root/failing-rg.out" 2>&1 || status=$?
if test "$status" -eq 0; then
  printf '%s\n' ARCHITECTURE_SCANNER_FAILURE_UNEXPECTED_PASS >&2
  exit 1
fi
test "$status" -eq 2
rg -q '^ARCHITECTURE_SCAN_FAILED$' "$fixture_root/failing-rg.out"
! rg -q "$fixture_root" "$fixture_root/failing-rg.out"

filter_bin="$fixture_root/filter-bin"
/bin/mkdir -p "$filter_bin"
real_rg="$(command -v rg)"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'count_file="${GT_RG_COUNT_FILE:?}"' \
  'count=0' \
  'test ! -f "$count_file" || count="$(<"$count_file")"' \
  'count=$((count + 1))' \
  'printf "%s\\n" "$count" > "$count_file"' \
  'if test "$count" -eq 2; then exit 2; fi' \
  "exec \"$real_rg\" \"\$@\"" > "$filter_bin/rg"
chmod +x "$filter_bin/rg"
status=0
GT_RG_COUNT_FILE="$fixture_root/rg-count" PATH="$filter_bin:$PATH" \
  "$checker" "$allowed" > "$fixture_root/filter-rg.out" 2>&1 || status=$?
test "$status" -eq 2
rg -q '^ARCHITECTURE_SCAN_FAILED$' "$fixture_root/filter-rg.out"

external="$fixture_root/external"
/bin/mkdir -p "$external/Sources/External"
escaped_workspace="${workspace_root//\\/\\\\}"
escaped_workspace="${escaped_workspace//\"/\\\"}"
printf '%s\n' \
  '// swift-tools-version: 6.1' \
  'import PackageDescription' \
  'let package = Package(' \
  '  name: "External",' \
  '  platforms: [.macOS(.v14)],' \
  "  dependencies: [.package(path: \"$escaped_workspace\")]," \
  '  targets: [.executableTarget(name: "External", dependencies: [.product(name: "SharedSupport", package: "GlideTranslate")])]' \
  ')' > "$external/Package.swift"
printf '%s\n' \
  'import SharedSupport' \
  'func attempt(_ payload: AuthorizedTranslationPayload) {' \
  '  _ = AuthorizedTranslationIntent.mintAfterAuthorization(requestID: TranslationRequestID(), payload: payload)' \
  '}' > "$external/Sources/External/main.swift"
if DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
    swift build --package-path "$external" > "$fixture_root/external.out" 2>&1; then
  printf '%s\n' EXTERNAL_MINT_UNEXPECTED_PASS >&2
  exit 1
fi
if ! rg -q 'mintAfterAuthorization' "$fixture_root/external.out"; then
  rg 'error:' "$fixture_root/external.out" >&2 || true
  exit 1
fi
if ! rg -q "(inaccessible|not accessible) due to 'package' protection level" \
    "$fixture_root/external.out"; then
  rg 'error:' "$fixture_root/external.out" >&2 || true
  exit 1
fi
! rg -q 'no such module|unknown package|not found' "$fixture_root/external.out"

external_storage="$fixture_root/external-storage"
/bin/mkdir -p "$external_storage/Sources/ExternalStorage"
printf '%s\n' \
  '// swift-tools-version: 6.1' \
  'import PackageDescription' \
  'let package = Package(' \
  '  name: "ExternalStorage",' \
  '  platforms: [.macOS(.v14)],' \
  "  dependencies: [.package(path: \"$escaped_workspace\")]," \
  '  targets: [.executableTarget(name: "ExternalStorage", dependencies: [.product(name: "PrivacyStorage", package: "GlideTranslate")])]' \
  ')' > "$external_storage/Package.swift"
printf '%s\n' \
  'import PrivacyStorage' \
  'func attempt(_ handle: ProviderVaultHandle) {' \
  '  let _: (any ProviderAccess)? = nil' \
  '  _ = handle.access' \
  '  _ = handle.confirmation' \
  '}' > "$external_storage/Sources/ExternalStorage/main.swift"
if DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
    swift build --package-path "$external_storage" \
    > "$fixture_root/external-storage.out" 2>&1; then
  printf '%s\n' EXTERNAL_PROVIDER_ACCESS_UNEXPECTED_PASS >&2
  exit 1
fi
for symbol in ProviderAccess access confirmation; do
  if ! rg -q "$symbol" "$fixture_root/external-storage.out"; then
    rg 'error:' "$fixture_root/external-storage.out" >&2 || true
    exit 1
  fi
done
if ! rg -q "(inaccessible|not accessible) due to 'package' protection level" \
    "$fixture_root/external-storage.out"; then
  rg 'error:' "$fixture_root/external-storage.out" >&2 || true
  exit 1
fi
! rg -q 'no such module|unknown package|not found' \
  "$fixture_root/external-storage.out"

external_engine="$fixture_root/external-engine"
/bin/mkdir -p "$external_engine/Sources/ExternalEngine"
printf '%s\n' \
  '// swift-tools-version: 6.1' \
  'import PackageDescription' \
  'let package = Package(' \
  '  name: "ExternalEngine",' \
  '  platforms: [.macOS(.v14)],' \
  "  dependencies: [.package(path: \"$escaped_workspace\")]," \
  '  targets: [.executableTarget(name: "ExternalEngine", dependencies: [' \
  '    .product(name: "SharedSupport", package: "GlideTranslate"),' \
  '    .product(name: "ModelProviders", package: "GlideTranslate"),' \
  '    .product(name: "TranslationCore", package: "GlideTranslate")' \
  '  ])]' \
  ')' > "$external_engine/Package.swift"
printf '%s\n' \
  'import ModelProviders' \
  'import SharedSupport' \
  'import TranslationCore' \
  'struct Provider: ProviderService {' \
  '  func generate(_ request: TranslationRequest, authorizedDestination: ProviderDestinationSnapshot) async -> AsyncThrowingStream<TranslationChunk, Error> {' \
  '    let pair = AsyncThrowingStream<TranslationChunk, Error>.makeStream()' \
  '    pair.continuation.finish()' \
  '    return pair.stream' \
  '  }' \
  '}' \
  'struct Preflight: ProviderPreflight {' \
  '  func resolveDestination(for configurationID: ProviderConfigurationID) async -> Result<ProviderDestinationSnapshot, SanitizedFailure> {' \
  '    .failure(.destinationReconfirmationRequired)' \
  '  }' \
  '  func currentSnapshot(for id: ProviderConfigurationID) async -> Result<ProviderDestinationSnapshot, SanitizedFailure> {' \
  '    await resolveDestination(for: id)' \
  '  }' \
  '}' \
  'let engine: any TranslationEngine = TranslationCoreFactory.makeEngine(provider: Provider(), preflight: Preflight(), clock: SystemAppClock())' \
  'func render(_ value: CompletedTranslation) -> String {' \
  '  _ = value.requestID; _ = value.sourceText; _ = value.presetID' \
  '  _ = value.sourceLanguage; _ = value.targetLanguage; _ = value.providerClass' \
  '  return value.resultText' \
  '}' > "$external_engine/Sources/ExternalEngine/main.swift"
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift build --package-path "$external_engine" \
  > "$fixture_root/external-engine.out" 2>&1
printf '%s\n' \
  'func forge() -> CompletedTranslation {' \
  '  CompletedTranslation(requestID: TranslationRequestID(), sourceText: "x", resultText: "y", presetID: PresetID(rawValue: "p"), sourceLanguage: .automatic, targetLanguage: .automatic, providerClass: .localOnDevice)' \
  '}' >> "$external_engine/Sources/ExternalEngine/main.swift"
if DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
    swift build --package-path "$external_engine" \
    > "$fixture_root/external-engine-forge.out" 2>&1; then
  printf '%s\n' EXTERNAL_COMPLETION_INIT_UNEXPECTED_PASS >&2
  exit 1
fi
rg -q 'CompletedTranslation' "$fixture_root/external-engine-forge.out"
rg -q "(inaccessible|not accessible) due to 'package' protection level" \
  "$fixture_root/external-engine-forge.out"
! rg -q 'no such module|unknown package|not found' \
  "$fixture_root/external-engine-forge.out"

printf '%s\n' ARCHITECTURE_BOUNDARY_TESTS_PASS
