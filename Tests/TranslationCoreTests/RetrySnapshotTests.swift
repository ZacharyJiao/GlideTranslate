import SharedSupport
import TestSupport
@testable import TranslationCore
import XCTest

final class RetrySnapshotTests: XCTestCase {
    func testEveryDestinationMutationRejectsRetryBeforeSecondProviderCall() async {
        for mutation in DestinationMutation.allCases {
            let fixture = EngineFixture(chunks: [.connected, .content("first"), .done])
            _ = await fixture.runToTerminal()
            fixture.preflight.current = .success(fixture.destination.mutating(mutation))

            let updates = await collect(await fixture.engine.retry(fixture.intent.requestID))

            XCTAssertEqual(updates.last, .failed(.destinationReconfirmationRequired), String(describing: mutation))
            XCTAssertEqual(fixture.provider.generateCount, 1)
        }
    }

    func testUnchangedRetryUsesExactImmutableSnapshot() async {
        let fixture = EngineFixture(chunks: [.connected, .content("same"), .done])
        let original = await fixture.runToTerminal()
        let retried = await collect(await fixture.engine.retry(fixture.intent.requestID))

        XCTAssertEqual(original.last, retried.last)
        XCTAssertEqual(fixture.provider.generateCount, 2)
        XCTAssertEqual(fixture.provider.requests.map(\.requestID), [fixture.intent.requestID, fixture.intent.requestID])
        XCTAssertEqual(fixture.provider.requests.map(\.userContent), [EngineFixture.sourceText, EngineFixture.sourceText])
        XCTAssertEqual(fixture.provider.requests.map(\.model), [fixture.destination.model, fixture.destination.model])
        XCTAssertEqual(fixture.provider.requests.map(\.timeouts), [fixture.intent.payload.options.timeouts, fixture.intent.payload.options.timeouts])
    }

    func testEditedPresetMintsNewRequestWhilePriorRetryKeepsPresetAndTimeoutSnapshot() async throws {
        let destination = ProviderDestinationSnapshot.fixture()
        let provider = EngineProviderSpy(
            chunks: [.connected, .content("result"), .done],
            failure: nil,
            manual: false
        )
        let preflight = EnginePreflightSpy(current: .success(destination))
        let engine = DefaultTranslationEngine(
            provider: provider,
            preflight: preflight,
            clock: ManualAppClock()
        )
        let validation = DefaultPromptPresetValidationService()
        let presetID = PresetID(
            rawValue: "custom-44444444-4444-4444-4444-444444444444"
        )
        let original = CustomPreset(
            id: presetID,
            name: "Mutable",
            explanation: "Original",
            template: "Original instruction: {text}",
            targetLanguage: .identified("ja"),
            action: .translate
        )
        let edited = CustomPreset(
            id: presetID,
            name: "Mutable",
            explanation: "Edited",
            template: "Edited instruction: {text}",
            targetLanguage: .identified("ja"),
            action: .translate
        )
        let originalTimeouts = TranslationTimeoutPolicy(
            connection: .seconds(5),
            firstToken: .seconds(120),
            streamIdle: .seconds(30)
        )
        let editedTimeouts = TranslationTimeoutPolicy(
            connection: .seconds(7),
            firstToken: .seconds(140),
            streamIdle: .seconds(40)
        )
        let originalIntent = AuthorizedTranslationIntent.fixture(
            destination: destination,
            preset: try validation.validate(original),
            timeouts: originalTimeouts
        )

        _ = await collect(await engine.translate(originalIntent))
        let editedIntent = AuthorizedTranslationIntent.fixture(
            destination: destination,
            preset: try validation.validate(edited),
            timeouts: editedTimeouts
        )
        _ = await collect(await engine.retry(originalIntent.requestID))
        _ = await collect(await engine.translate(editedIntent))

        XCTAssertEqual(provider.requests.count, 3)
        XCTAssertEqual(
            provider.requests.map(\.requestID),
            [originalIntent.requestID, originalIntent.requestID, editedIntent.requestID]
        )
        XCTAssertEqual(
            provider.requests.map(\.timeouts),
            [originalTimeouts, originalTimeouts, editedTimeouts]
        )
        XCTAssertEqual(provider.requests[0].instruction, provider.requests[1].instruction)
        XCTAssertNotEqual(provider.requests[1].instruction, provider.requests[2].instruction)
    }

    func testUnknownRequestCannotRetry() async {
        let fixture = EngineFixture(chunks: [.connected, .content("first"), .done])
        _ = await fixture.runToTerminal()

        let updates = await collect(await fixture.engine.retry(TranslationRequestID()))

        XCTAssertEqual(updates, [.failed(.providerProtocolFailure)])
        XCTAssertEqual(fixture.provider.generateCount, 1)
    }

    func testFailedProviderRequestIsRetryable() async {
        let fixture = EngineFixture(chunks: [.connected], providerFailure: SanitizedFailure.modelUnavailable)
        let original = await fixture.runToTerminal()
        let retried = await collect(await fixture.engine.retry(fixture.intent.requestID))

        XCTAssertEqual(original.last, .failed(.modelUnavailable))
        XCTAssertEqual(retried.last, .failed(.modelUnavailable))
        XCTAssertEqual(fixture.provider.generateCount, 2)
    }

    func testOnlyMostRecentCompletedRequestCanRetry() async {
        let fixture = EngineFixture(chunks: [.connected, .content("result"), .done])
        _ = await fixture.runToTerminal()
        let second = AuthorizedTranslationIntent.fixture(
            destination: fixture.destination,
            text: "Most recent source",
            timeouts: fixture.intent.payload.options.timeouts
        )
        _ = await collect(await fixture.engine.translate(second))

        let staleRetry = await collect(await fixture.engine.retry(fixture.intent.requestID))
        let currentRetry = await collect(await fixture.engine.retry(second.requestID))
        XCTAssertEqual(staleRetry, [.failed(.providerProtocolFailure)])
        XCTAssertEqual(currentRetry.last?.simple, .completed("result"))
        XCTAssertEqual(fixture.provider.generateCount, 3)
    }

    func testCancellingNewRequestPreservesPriorCompletedSnapshot() async {
        let fixture = EngineFixture(chunks: [.connected, .content("saved"), .done])
        _ = await fixture.runToTerminal()
        fixture.provider.setManual(true)
        let second = AuthorizedTranslationIntent.fixture(
            destination: fixture.destination,
            text: "Cancelled source",
            timeouts: fixture.intent.payload.options.timeouts
        )
        let cancelledStream = await fixture.engine.translate(second)
        await fixture.provider.waitForGenerateCount(2)
        await fixture.engine.cancel(second.requestID)
        _ = await collect(cancelledStream)
        fixture.provider.setManual(false)

        let retried = await collect(await fixture.engine.retry(fixture.intent.requestID))
        XCTAssertEqual(retried.last?.simple, .completed("saved"))
    }

    private func collect(_ stream: AsyncStream<TranslationUpdate>) async -> [TranslationUpdate] {
        var updates: [TranslationUpdate] = []
        for await update in stream { updates.append(update) }
        return updates
    }
}

enum DestinationMutation: CaseIterable {
    case configurationRevision
    case confirmationRevision
    case origin
    case resolutionFingerprint
    case privacyClass
    case protocolKind
    case model
}

extension ProviderDestinationSnapshot {
    func mutating(_ mutation: DestinationMutation) -> Self {
        switch mutation {
        case .configurationRevision:
            .fixture(configurationID: configurationID, privacyClass: privacyClass, configurationRevision: configurationRevision + 1, confirmationRevision: confirmationRevision, origin: origin, resolutionFingerprint: resolutionFingerprint, protocolKind: protocolKind, model: model)
        case .confirmationRevision:
            .fixture(configurationID: configurationID, privacyClass: privacyClass, configurationRevision: configurationRevision, confirmationRevision: confirmationRevision + 1, origin: origin, resolutionFingerprint: resolutionFingerprint, protocolKind: protocolKind, model: model)
        case .origin:
            .fixture(configurationID: configurationID, privacyClass: privacyClass, configurationRevision: configurationRevision, confirmationRevision: confirmationRevision, origin: ProviderOrigin(scheme: "https", host: "changed.invalid", effectivePort: 443), resolutionFingerprint: resolutionFingerprint, protocolKind: protocolKind, model: model)
        case .resolutionFingerprint:
            .fixture(configurationID: configurationID, privacyClass: privacyClass, configurationRevision: configurationRevision, confirmationRevision: confirmationRevision, origin: origin, resolutionFingerprint: ["203.0.113.2"], protocolKind: protocolKind, model: model)
        case .privacyClass:
            .fixture(configurationID: configurationID, privacyClass: .cloud, configurationRevision: configurationRevision, confirmationRevision: confirmationRevision, origin: origin, resolutionFingerprint: resolutionFingerprint, protocolKind: protocolKind, model: model)
        case .protocolKind:
            .fixture(configurationID: configurationID, privacyClass: privacyClass, configurationRevision: configurationRevision, confirmationRevision: confirmationRevision, origin: origin, resolutionFingerprint: resolutionFingerprint, protocolKind: .openAICompatible, model: model)
        case .model:
            .fixture(configurationID: configurationID, privacyClass: privacyClass, configurationRevision: configurationRevision, confirmationRevision: confirmationRevision, origin: origin, resolutionFingerprint: resolutionFingerprint, protocolKind: protocolKind, model: "changed-model")
        }
    }
}
