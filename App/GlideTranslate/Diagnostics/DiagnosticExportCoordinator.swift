import AppKit
import Foundation

enum DiagnosticIncludedField: String, CaseIterable, Equatable, Sendable {
    case schemaVersion
    case applicationVersion
    case operatingSystemMajorVersion
    case architectureCategory
    case accessibilityPermissionCategory
    case defaultProviderPrivacyClass
    case componentHealthCategories
    case recentOutcomeCounts
}

enum DiagnosticExcludedField: String, CaseIterable, Equatable, Sendable {
    case userAndDeviceNames
    case buildAndApplicationPaths
    case modelNamesAndEndpoints
    case sourceApplicationIdentifiersAndWindowTitles
    case promptsRequestsResponsesAndHistory
    case credentialsAndLogExtracts
    case stackTracesAndExactOperatingSystemBuild
}

struct DiagnosticPreview: Equatable, Sendable {
    let reportData: Data
    let included: [DiagnosticIncludedField]
    let excluded: [DiagnosticExcludedField]
}

@MainActor
protocol DiagnosticPreviewPresenting: AnyObject {
    func show(_ preview: DiagnosticPreview) async -> Bool
}

@MainActor
protocol DiagnosticDestinationPicking: AnyObject {
    func chooseDestination() async -> URL?
}

protocol DiagnosticFileWriting: Sendable {
    func write(_ data: Data, to url: URL) async throws
}

enum DiagnosticExportOutcome: Equatable, Sendable {
    case saved
    case previewCancelled
    case saveCancelled
    case failed
    case alreadyStarted
}

@MainActor
final class DiagnosticExportCoordinator {
    private let reportBuilder: DiagnosticReportBuilder
    private let previewPresenter: any DiagnosticPreviewPresenting
    private let destinationPicker: any DiagnosticDestinationPicking
    private let writer: any DiagnosticFileWriting
    private var hasStarted = false

    init(
        reportBuilder: DiagnosticReportBuilder,
        previewPresenter: any DiagnosticPreviewPresenting,
        destinationPicker: any DiagnosticDestinationPicking,
        writer: any DiagnosticFileWriting
    ) {
        self.reportBuilder = reportBuilder
        self.previewPresenter = previewPresenter
        self.destinationPicker = destinationPicker
        self.writer = writer
    }

    func start() async -> DiagnosticExportOutcome {
        guard !hasStarted else {
            return .alreadyStarted
        }
        hasStarted = true

        let reportData: Data
        do {
            reportData = try reportBuilder.encodedPreview()
        } catch {
            return .failed
        }

        let preview = DiagnosticPreview(
            reportData: reportData,
            included: DiagnosticIncludedField.allCases,
            excluded: DiagnosticExcludedField.allCases
        )
        guard await previewPresenter.show(preview) else {
            return .previewCancelled
        }
        guard let destination = await destinationPicker.chooseDestination() else {
            return .saveCancelled
        }
        do {
            try await writer.write(reportData, to: destination)
            return .saved
        } catch {
            return .failed
        }
    }
}

@MainActor
final class NSSavePanelDiagnosticDestinationPicker: DiagnosticDestinationPicking {
    func chooseDestination() async -> URL? {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = "GlideTranslate-Diagnostics.json"
        return panel.runModal() == .OK ? panel.url : nil
    }
}

protocol DiagnosticAtomicWritePerforming: Sendable {
    func write(
        _ data: Data,
        to url: URL,
        options: Data.WritingOptions
    ) throws
}

private struct FoundationDiagnosticAtomicWriter: DiagnosticAtomicWritePerforming {
    func write(
        _ data: Data,
        to url: URL,
        options: Data.WritingOptions
    ) throws {
        try data.write(to: url, options: options)
    }
}

actor AtomicDiagnosticFileWriter: DiagnosticFileWriting {
    private let performer: any DiagnosticAtomicWritePerforming

    init() {
        performer = FoundationDiagnosticAtomicWriter()
    }

    init(performer: any DiagnosticAtomicWritePerforming) {
        self.performer = performer
    }

    func write(_ data: Data, to url: URL) async throws {
        try performer.write(data, to: url, options: .atomic)
    }
}
