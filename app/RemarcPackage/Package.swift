// swift-tools-version: 6.0

import PackageDescription
import Foundation

// Opt in explicitly: the upstream build retains its full speech backend.
let venturaBuild = Context.environment["REMARC_VENTURA"] == "1"

let package = Package(
    name: "RemarcFeature",
    platforms: [.macOS(venturaBuild ? .v13 : .v14)],
    products: [
        .library(
            name: "RemarcFeature",
            targets: ["RemarcFeature"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.5"),
        .package(url: "https://github.com/linearmouse/AppMover", branch: "master"),
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", from: "3.0.1"),
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift", from: "1.0.0")
    ] + (venturaBuild ? [] : [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.15.5")
    ]),
    targets: [
        .target(name: "CorePlatform", path: "Sources/Core/Platform"),
        .target(name: "CoreLocalization", path: "Sources/Core/Localization", resources: [.process("Resources")]),
        .target(name: "CoreTheme", path: "Sources/Core/Theme"),
        .target(name: "CoreUI", dependencies: ["CorePlatform", "CoreLocalization", "CoreTheme"], path: "Sources/Core/UI"),
        .target(name: "FeatureComments", dependencies: ["CorePlatform", "CoreLocalization"], path: "Sources/Features/Comments", exclude: ["UI"]),
        .target(name: "FeatureCapture", dependencies: ["CorePlatform", "CoreLocalization", "CoreTheme", "CoreUI"], path: "Sources/Features/Capture", exclude: ["UI"]),
        .target(
            name: "FeatureVoice",
            dependencies: ["CorePlatform", "CoreLocalization",
                .product(name: "WhisperKit", package: "argmax-oss-swift")
            ] + (venturaBuild ? [] : [.product(name: "FluidAudio", package: "FluidAudio")]),
            path: "Sources/Features/Voice", exclude: ["UI"],
            swiftSettings: venturaBuild ? [.define("REMARC_VENTURA")] : []
        ),
        .target(name: "FeatureIntegrations", dependencies: ["CorePlatform", "CoreLocalization"], path: "Sources/Features/Integrations", exclude: ["UI"]),
        .target(name: "FeatureSnapshotSync", dependencies: ["CorePlatform", "CoreLocalization", "FeatureComments", "FeatureCapture"], path: "Sources/Features/SnapshotSync", exclude: ["UI"]),
        .target(name: "FeatureUpdates", dependencies: ["CorePlatform", "CoreLocalization",
            .product(name: "Sparkle", package: "Sparkle")], path: "Sources/Features/Updates"),
        .target(name: "FeatureSettings", dependencies: ["CorePlatform", "CoreLocalization", "CoreUI",
            "FeatureComments", "FeatureCapture", "FeatureVoice", "FeatureIntegrations",
            .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts")]
            + (venturaBuild ? [] : [.product(name: "FluidAudio", package: "FluidAudio")]),
            path: "Sources/Features/Settings", exclude: ["UI"]),
        .target(name: "FeatureOnboarding", dependencies: ["CorePlatform", "CoreLocalization", "CoreTheme", "CoreUI", "FeatureCapture", "FeatureIntegrations"], path: "Sources/Features/Onboarding"),
        // Application composition and UI workflows. The Xcode app retains its
        // existing product, signing identity and stable RemarcFeature entry point.
        .target(
            name: "RemarcFeature",
            dependencies: [
                "CorePlatform", "CoreLocalization", "CoreTheme", "CoreUI", "FeatureComments", "FeatureCapture",
                "FeatureVoice", "FeatureIntegrations", "FeatureSnapshotSync", "FeatureUpdates", "FeatureSettings", "FeatureOnboarding",
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "AppMover", package: "AppMover"),
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts")
            ] + (venturaBuild ? [] : [.product(name: "FluidAudio", package: "FluidAudio")]),
            path: "Sources",
            exclude: [
                "Core",
                "Features/Capture/Annotation",
                "Features/Capture/Model",
                "Features/Capture/Permission",
                "Features/Capture/Storage",
                "Features/Capture/View",
                "Features/Comments/Model",
                "Features/Comments/Policy",
                "Features/Comments/Repository",
                "Features/Integrations/Agents",
                "Features/Integrations/Browser",
                "Features/Integrations/Model",
                "Features/Integrations/Webhooks",
                "Features/Onboarding",
                "Features/Settings/Model",
                "Features/Settings/SettingsManager.swift",
                "Features/SnapshotSync/SnapshotArchive.swift",
                "Features/SnapshotSync/SnapshotCloudLocation.swift",
                "Features/SnapshotSync/SnapshotDisk.swift",
                "Features/SnapshotSync/SnapshotDocumentStore.swift",
                "Features/SnapshotSync/SnapshotRollbackStore.swift",
                "Features/SnapshotSync/SnapshotSyncManager.swift",
                "Features/SnapshotSync/SnapshotSyncState.swift",
                "Features/Updates",
                "Features/Voice/Audio",
                "Features/Voice/Model",
                "Features/Voice/Transcription",
            ],
            resources: [.process("App/Resources")],
            swiftSettings: venturaBuild ? [.define("REMARC_VENTURA")] : []
        ),
        .testTarget(
            name: "RemarcFeatureTests",
            dependencies: ["RemarcFeature", "CorePlatform", "CoreLocalization", "CoreTheme", "CoreUI",
                "FeatureComments", "FeatureCapture", "FeatureVoice", "FeatureIntegrations",
                "FeatureSnapshotSync", "FeatureUpdates", "FeatureSettings", "FeatureOnboarding"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
