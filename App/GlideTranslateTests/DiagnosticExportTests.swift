import Foundation
import SharedSupport
import XCTest
@testable import GlideTranslate

@MainActor
final class DiagnosticExportTests: XCTestCase {
    func testExportRequiresPreviewApprovalBeforeSavePanel() async throws {
        for approved in [false, true] {
            let fixture = try DiagnosticExportFixture(previewApproved: approved)
            let outcome = await fixture.coordinator.start()
            let writerSnapshot = await fixture.writer.snapshot()

            XCTAssertEqual(fixture.preview.showCount, 1)
            XCTAssertEqual(fixture.savePanel.showCount, approved ? 1 : 0)
            XCTAssertEqual(writerSnapshot.writeCount, approved ? 1 : 0)
            XCTAssertEqual(
                outcome,
                approved ? .saved : .previewCancelled
            )
            if approved {
                XCTAssertEqual(
                    writerSnapshot.lastData,
                    fixture.preview.lastPreview?.reportData
                )
                XCTAssertEqual(
                    writerSnapshot.lastURL,
                    fixture.savePanel.destination
                )
            }
        }
    }

    func testSavePanelCancellationDoesNotWrite() async throws {
        let fixture = try DiagnosticExportFixture(
            previewApproved: true,
            destinationAvailable: false
        )

        let outcome = await fixture.coordinator.start()
        let writerSnapshot = await fixture.writer.snapshot()

        XCTAssertEqual(outcome, .saveCancelled)
        XCTAssertEqual(fixture.preview.showCount, 1)
        XCTAssertEqual(fixture.savePanel.showCount, 1)
        XCTAssertEqual(writerSnapshot.writeCount, 0)
    }

    func testExportIsOneShot() async throws {
        let fixture = try DiagnosticExportFixture(previewApproved: true)

        let first = await fixture.coordinator.start()
        let second = await fixture.coordinator.start()
        let writerSnapshot = await fixture.writer.snapshot()

        XCTAssertEqual(first, .saved)
        XCTAssertEqual(second, .alreadyStarted)

        XCTAssertEqual(fixture.preview.showCount, 1)
        XCTAssertEqual(fixture.savePanel.showCount, 1)
        XCTAssertEqual(writerSnapshot.writeCount, 1)
    }

    func testPreviewDocumentsExactIncludedAndExcludedCategories() async throws {
        let fixture = try DiagnosticExportFixture(previewApproved: false)

        _ = await fixture.coordinator.start()

        let preview = try XCTUnwrap(fixture.preview.lastPreview)
        XCTAssertEqual(preview.included, DiagnosticIncludedField.allCases)
        XCTAssertEqual(preview.excluded, DiagnosticExcludedField.allCases)
        XCTAssertEqual(preview.included.map(\.rawValue), [
            "schemaVersion",
            "applicationVersion",
            "operatingSystemMajorVersion",
            "architectureCategory",
            "accessibilityPermissionCategory",
            "defaultProviderPrivacyClass",
            "componentHealthCategories",
            "recentOutcomeCounts"
        ])
        XCTAssertEqual(preview.excluded.map(\.rawValue), [
            "userAndDeviceNames",
            "buildAndApplicationPaths",
            "modelNamesAndEndpoints",
            "sourceApplicationIdentifiersAndWindowTitles",
            "promptsRequestsResponsesAndHistory",
            "credentialsAndLogExtracts",
            "stackTracesAndExactOperatingSystemBuild"
        ])
    }

    func testWriterFailureIsSanitizedAndDoesNotRetryOrReenter() async throws {
        let fixture = try DiagnosticExportFixture(
            previewApproved: true,
            writerFails: true
        )

        let first = await fixture.coordinator.start()
        let second = await fixture.coordinator.start()
        let writerSnapshot = await fixture.writer.snapshot()

        XCTAssertEqual(first, .failed)
        XCTAssertEqual(second, .alreadyStarted)
        XCTAssertEqual(fixture.preview.showCount, 1)
        XCTAssertEqual(fixture.savePanel.showCount, 1)
        XCTAssertEqual(writerSnapshot.writeCount, 1)
    }

    func testProductionWriterRequestsAtomicFoundationWrite() async throws {
        let performer = DiagnosticAtomicWriteSpy()
        let writer = AtomicDiagnosticFileWriter(performer: performer)
        let data = Data([1, 2, 3])
        let url = URL(fileURLWithPath: "/tmp/synthetic-atomic-report.json")

        try await writer.write(data, to: url)

        let snapshot = performer.snapshot
        XCTAssertEqual(snapshot.callCount, 1)
        XCTAssertEqual(snapshot.data, data)
        XCTAssertEqual(snapshot.url, url)
        XCTAssertTrue(snapshot.options.contains(.atomic))
    }
}

@MainActor
private final class DiagnosticExportFixture {
    let preview: DiagnosticPreviewSpy
    let savePanel: DiagnosticSavePanelSpy
    let writer: DiagnosticWriterSpy
    let coordinator: DiagnosticExportCoordinator

    init(
        previewApproved: Bool,
        destinationAvailable: Bool = true,
        writerFails: Bool = false
    ) throws {
        writer = DiagnosticWriterSpy(shouldThrow: writerFails)
        preview = DiagnosticPreviewSpy(approved: previewApproved)
        savePanel = DiagnosticSavePanelSpy(
            destination: destinationAvailable
                ? URL(fileURLWithPath: "/tmp/synthetic-diagnostic.json")
                : nil
        )
        let builder = try DiagnosticReportBuilder(
            appVersion: "1.0",
            osMajorVersion: 15,
            architecture: .arm64,
            accessibilityPermission: .denied,
            defaultProviderClass: .localOnDevice,
            componentHealth: [.captureOperational],
            recentOutcomeCounts: [.translationSucceeded: 1]
        )
        coordinator = DiagnosticExportCoordinator(
            reportBuilder: builder,
            previewPresenter: preview,
            destinationPicker: savePanel,
            writer: writer
        )
    }
}

@MainActor
private final class DiagnosticPreviewSpy: DiagnosticPreviewPresenting {
    private let approved: Bool
    private(set) var showCount = 0
    private(set) var lastPreview: DiagnosticPreview?

    init(approved: Bool) {
        self.approved = approved
    }

    func show(_ preview: DiagnosticPreview) async -> Bool {
        showCount += 1
        lastPreview = preview
        return approved
    }
}

@MainActor
private final class DiagnosticSavePanelSpy: DiagnosticDestinationPicking {
    let destination: URL?
    private(set) var showCount = 0

    init(destination: URL?) {
        self.destination = destination
    }

    func chooseDestination() async -> URL? {
        showCount += 1
        return destination
    }
}

private actor DiagnosticWriterSpy: DiagnosticFileWriting {
    private enum SyntheticWriteFailure: Error {
        case failed
    }

    private let shouldThrow: Bool
    private(set) var writeCount = 0
    private(set) var lastData: Data?
    private(set) var lastURL: URL?

    init(shouldThrow: Bool = false) {
        self.shouldThrow = shouldThrow
    }

    func write(_ data: Data, to url: URL) async throws {
        writeCount += 1
        lastData = data
        lastURL = url
        if shouldThrow {
            throw SyntheticWriteFailure.failed
        }
    }

    func snapshot() -> (writeCount: Int, lastData: Data?, lastURL: URL?) {
        (writeCount, lastData, lastURL)
    }
}

private final class DiagnosticAtomicWriteSpy:
    DiagnosticAtomicWritePerforming,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var callCount = 0
    private var data: Data?
    private var url: URL?
    private var options: Data.WritingOptions = []

    var snapshot: (
        callCount: Int,
        data: Data?,
        url: URL?,
        options: Data.WritingOptions
    ) {
        lock.withLock { (callCount, data, url, options) }
    }

    func write(
        _ data: Data,
        to url: URL,
        options: Data.WritingOptions
    ) throws {
        lock.withLock {
            callCount += 1
            self.data = data
            self.url = url
            self.options = options
        }
    }
}
