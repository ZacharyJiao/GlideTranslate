import Foundation
import SharedSupport

enum ArchitectureCategory: String, Codable, Equatable, Sendable {
    case arm64
    case x86_64
    case other

    static var current: Self {
        #if arch(arm64)
        .arm64
        #elseif arch(x86_64)
        .x86_64
        #else
        .other
        #endif
    }
}

enum ComponentHealthCategory: String, Codable, CaseIterable, Equatable, Sendable {
    case captureOperational
    case providerOperational
    case storageOperational
    case permissionLimited
    case providerUnavailable
    case storageUnrecoverable
}

enum OutcomeCategory: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case captureRejected
    case translationSucceeded
    case translationFailed
    case translationCancelled
    case historyStored
    case historyFailed
}

enum DiagnosticReportError: Error, Equatable, Sendable {
    case invalidAppVersion
    case invalidOperatingSystemVersion
    case invalidOutcomeCount
    case encodingFailed
}

struct DiagnosticReport: Codable, Equatable, Sendable {
    let schemaVersion: UInt16
    let appVersion: String
    let osMajorVersion: Int
    let architecture: ArchitectureCategory
    let accessibilityPermission: AccessibilityPermissionCategory
    let defaultProviderClass: DestinationPrivacyClass
    let componentHealth: [ComponentHealthCategory]
    let recentOutcomeCounts: [OutcomeCategory: Int]

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case appVersion
        case osMajorVersion
        case architecture
        case accessibilityPermission
        case defaultProviderClass
        case componentHealth
        case recentOutcomeCounts
    }

    fileprivate init(
        schemaVersion: UInt16,
        appVersion: String,
        osMajorVersion: Int,
        architecture: ArchitectureCategory,
        accessibilityPermission: AccessibilityPermissionCategory,
        defaultProviderClass: DestinationPrivacyClass,
        componentHealth: [ComponentHealthCategory],
        recentOutcomeCounts: [OutcomeCategory: Int]
    ) {
        self.schemaVersion = schemaVersion
        self.appVersion = appVersion
        self.osMajorVersion = osMajorVersion
        self.architecture = architecture
        self.accessibilityPermission = accessibilityPermission
        self.defaultProviderClass = defaultProviderClass
        self.componentHealth = componentHealth
        self.recentOutcomeCounts = recentOutcomeCounts
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(UInt16.self, forKey: .schemaVersion)
        appVersion = try container.decode(String.self, forKey: .appVersion)
        osMajorVersion = try container.decode(Int.self, forKey: .osMajorVersion)
        architecture = try container.decode(
            ArchitectureCategory.self,
            forKey: .architecture
        )
        accessibilityPermission = try container.decode(
            AccessibilityPermissionCategory.self,
            forKey: .accessibilityPermission
        )
        defaultProviderClass = try container.decode(
            DestinationPrivacyClass.self,
            forKey: .defaultProviderClass
        )
        componentHealth = try container.decode(
            [ComponentHealthCategory].self,
            forKey: .componentHealth
        )
        let rawCounts = try container.decode(
            [String: Int].self,
            forKey: .recentOutcomeCounts
        )
        let expectedCountKeys = Set(OutcomeCategory.allCases.map(\.rawValue))
        guard Set(rawCounts.keys) == expectedCountKeys else {
            throw DecodingError.dataCorruptedError(
                forKey: .recentOutcomeCounts,
                in: container,
                debugDescription: "outcome categories must use the exact schema"
            )
        }
        recentOutcomeCounts = try Dictionary(
            uniqueKeysWithValues: rawCounts.map { rawKey, value in
                guard let key = OutcomeCategory(rawValue: rawKey) else {
                    throw DecodingError.dataCorruptedError(
                        forKey: .recentOutcomeCounts,
                        in: container,
                        debugDescription: "unknown outcome category"
                    )
                }
                return (key, value)
            }
        )
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(appVersion, forKey: .appVersion)
        try container.encode(osMajorVersion, forKey: .osMajorVersion)
        try container.encode(architecture, forKey: .architecture)
        try container.encode(
            accessibilityPermission,
            forKey: .accessibilityPermission
        )
        try container.encode(defaultProviderClass, forKey: .defaultProviderClass)
        try container.encode(componentHealth, forKey: .componentHealth)
        try container.encode(
            Dictionary(uniqueKeysWithValues: recentOutcomeCounts.map {
                ($0.key.rawValue, $0.value)
            }),
            forKey: .recentOutcomeCounts
        )
    }
}

struct DiagnosticReportBuilder: Equatable, Sendable {
    private static let schemaVersion: UInt16 = 1
    private let report: DiagnosticReport

    init(
        appVersion: String,
        osMajorVersion: Int,
        architecture: ArchitectureCategory,
        accessibilityPermission: AccessibilityPermissionCategory,
        defaultProviderClass: DestinationPrivacyClass,
        componentHealth: [ComponentHealthCategory],
        recentOutcomeCounts: [OutcomeCategory: Int]
    ) throws {
        guard Self.isValidAppVersion(appVersion) else {
            throw DiagnosticReportError.invalidAppVersion
        }
        guard (1...999).contains(osMajorVersion) else {
            throw DiagnosticReportError.invalidOperatingSystemVersion
        }
        guard recentOutcomeCounts.values.allSatisfy({ $0 >= 0 }) else {
            throw DiagnosticReportError.invalidOutcomeCount
        }

        let normalizedHealth = Array(Set(componentHealth)).sorted {
            $0.rawValue < $1.rawValue
        }
        let normalizedCounts = Dictionary(uniqueKeysWithValues:
            OutcomeCategory.allCases.map { category in
                (category, recentOutcomeCounts[category, default: 0])
            }
        )
        report = DiagnosticReport(
            schemaVersion: Self.schemaVersion,
            appVersion: appVersion,
            osMajorVersion: osMajorVersion,
            architecture: architecture,
            accessibilityPermission: accessibilityPermission,
            defaultProviderClass: defaultProviderClass,
            componentHealth: normalizedHealth,
            recentOutcomeCounts: normalizedCounts
        )
    }

    @MainActor
    static func current(
        bundle: Bundle = .main,
        accessibilityPermission: AccessibilityPermissionCategory,
        defaultProviderClass: DestinationPrivacyClass,
        componentHealth: [ComponentHealthCategory],
        recentOutcomeCounts: [OutcomeCategory: Int]
    ) throws -> Self {
        guard let appVersion = bundle.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String else {
            throw DiagnosticReportError.invalidAppVersion
        }
        return try Self(
            appVersion: appVersion,
            osMajorVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion,
            architecture: .current,
            accessibilityPermission: accessibilityPermission,
            defaultProviderClass: defaultProviderClass,
            componentHealth: componentHealth,
            recentOutcomeCounts: recentOutcomeCounts
        )
    }

    func encodedPreview() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do {
            return try encoder.encode(report)
        } catch {
            throw DiagnosticReportError.encodingFailed
        }
    }

    private static func isValidAppVersion(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 32 else {
            return false
        }
        let components = value.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(components.count) else {
            return false
        }
        return components.allSatisfy { component in
            !component.isEmpty && component.utf8.allSatisfy { byte in
                (48...57).contains(byte)
            }
        }
    }
}
