// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "GlideTranslate",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SharedSupport", targets: ["SharedSupport"]),
        .library(name: "SelectionCapture", targets: ["SelectionCapture"]),
        .library(name: "PrivacyStorage", targets: ["PrivacyStorage"]),
        .library(name: "ModelProviders", targets: ["ModelProviders"]),
        .library(name: "TranslationCore", targets: ["TranslationCore"])
    ],
    targets: [
        .target(name: "SharedSupport"),
        .target(name: "SelectionCapture", dependencies: ["SharedSupport"]),
        .systemLibrary(name: "CSQLite"),
        .target(
            name: "PrivacyStorage",
            dependencies: ["SharedSupport", "CSQLite"],
            linkerSettings: [.linkedFramework("Security"), .linkedLibrary("sqlite3")]
        ),
        .target(
            name: "ModelProviders",
            dependencies: ["SharedSupport", "PrivacyStorage"],
            linkerSettings: [.linkedFramework("Network")]
        ),
        .target(
            name: "TranslationCore",
            dependencies: ["SharedSupport", "ModelProviders"]
        ),
        .target(
            name: "TestSupport",
            dependencies: ["SharedSupport"],
            path: "Tests/TestSupport"
        ),
        .testTarget(
            name: "SharedSupportTests",
            dependencies: ["SharedSupport", "TestSupport"]
        ),
        .testTarget(
            name: "SelectionCaptureTests",
            dependencies: ["SharedSupport", "SelectionCapture", "TestSupport"]
        ),
        .testTarget(
            name: "PrivacyStorageTests",
            dependencies: [
                "SharedSupport", "PrivacyStorage", "TestSupport", "CSQLite"
            ]
        ),
        .testTarget(
            name: "ModelProvidersTests",
            dependencies: [
                "SharedSupport", "PrivacyStorage", "ModelProviders", "TestSupport"
            ]
        ),
        .testTarget(
            name: "TranslationCoreTests",
            dependencies: [
                "SharedSupport", "ModelProviders", "TranslationCore", "TestSupport"
            ]
        )
    ],
    swiftLanguageModes: [.v6]
)
