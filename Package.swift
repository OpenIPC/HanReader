// swift-tools-version:6.2
// HanReader — MIT licensed. See LICENSE.

import PackageDescription

// MARK: - Shared build settings

/// Applied to every target. `InternalImportsByDefault` is load-bearing rather
/// than stylistic: it makes each `import` internal unless explicitly marked
/// `public import`, which turns "HanReaderPersistence must not leak GRDB types
/// across its module boundary" from a code-review convention into a compiler
/// error.
let baseSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("InternalImportsByDefault"),
]

/// Applied to the UI-facing targets. `defaultIsolation(MainActor.self)` removes
/// the need to annotate nearly every type in these modules, and with it the
/// class of workaround the predecessor prototype was built on
/// (`nonisolated(unsafe) let db`, `MainActor.assumeIsolated` inside an AVPlayer
/// time observer). It is the reason this package requires tools-version 6.2.
let mainActorSettings: [SwiftSetting] = baseSettings + [
    .defaultIsolation(MainActor.self),
]

let package = Package(
    name: "HanReaderKit",
    defaultLocalization: "en",
    // Apple's own recommended deployment targets, and precisely the floors the
    // app needs: @Observable, ContentUnavailableView and .scrollPosition(id:)
    // all require macOS 14 / iOS 17.
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "HanReaderUI", targets: ["HanReaderUI"]),
        .library(name: "HanReaderCore", targets: ["HanReaderCore"]),
        .executable(name: "hanreader-dictgen", targets: ["hanreader-dictgen"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", .upToNextMinor(from: "7.11.1")),
        .package(
            url: "https://github.com/apple/swift-argument-parser",
            .upToNextMinor(from: "1.8.2"),
        ),
    ],
    targets: [
        // MARK: Core — Foundation only

        // Imports nothing but Foundation, so that the bulk of the test suite
        // runs in seconds with no simulator and so the domain logic stays
        // portable. A Linux CI job builds this target in isolation, which is
        // what actually enforces the rule: NaturalLanguage and AVFoundation are
        // just as Apple-only as AppKit, so "no AppKit" would be too weak.
        .target(
            name: "HanReaderCore",
            swiftSettings: baseSettings,
        ),

        // MARK: Engine

        // The only place NaturalLanguage appears. NLTokenizer is a closed model
        // whose segmentation can change between OS releases, so it sits behind
        // HanReaderCore.Tokenizing alongside a deterministic segmenter that
        // tests can actually assert on.
        .target(
            name: "HanReaderTokenization",
            dependencies: ["HanReaderCore"],
            swiftSettings: baseSettings,
        ),

        // Owns every GRDB call and must not expose a GRDB type in its public
        // API. Chosen over hand-rolled sqlite3 for Sendable database handles,
        // a real migration system, and in-memory databases for hermetic tests.
        .target(
            name: "HanReaderPersistence",
            dependencies: [
                "HanReaderCore",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            swiftSettings: baseSettings,
        ),

        // Streaming dictionary ingestion: CC-CEDICT and ABBYY DSL, with
        // progress reporting, cancellation and resumability.
        .target(
            name: "HanReaderDictionaryImport",
            dependencies: ["HanReaderCore", "HanReaderPersistence"],
            swiftSettings: baseSettings,
        ),

        // MARK: Media

        .target(
            name: "HanReaderPlayback",
            dependencies: ["HanReaderCore"],
            swiftSettings: mainActorSettings,
        ),

        // MARK: Platform and UI

        // The AppKit/UIKit shim, and deliberately small. SwiftUI's own
        // .fileImporter works identically on both platforms, so file import
        // does not belong here; neither do menu commands, which go through
        // FocusedValue. If this module grows large, the UI layer has leaked.
        .target(
            name: "HanReaderPlatform",
            dependencies: ["HanReaderCore"],
            swiftSettings: mainActorSettings,
        ),

        .target(
            name: "HanReaderUI",
            dependencies: [
                "HanReaderCore",
                "HanReaderTokenization",
                "HanReaderPersistence",
                "HanReaderDictionaryImport",
                "HanReaderPlayback",
                "HanReaderPlatform",
            ],
            swiftSettings: mainActorSettings,
        ),

        // MARK: Tools

        // Compiles a source dictionary into the distributable container.
        // Load-bearing for three separate requirements: a reproducible bundled
        // CC-CEDICT, CI verification that a parser change did not silently
        // halve the dictionary, and an iOS import path that never parses DSL.
        .executableTarget(
            name: "hanreader-dictgen",
            dependencies: [
                "HanReaderCore",
                "HanReaderPersistence",
                "HanReaderDictionaryImport",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            swiftSettings: baseSettings,
        ),

        // MARK: Tests

        .testTarget(
            name: "HanReaderCoreTests",
            dependencies: ["HanReaderCore"],
            // Small slices of the real CC-CEDICT and 大БКРС data, each
            // extracted by a committed script (Scripts/extract-cedict-fixture.py
            // and Scripts/extract-dsl-fixture.py) so their provenance is
            // documented and they can be regenerated rather than hand-edited.
            //
            // Kept inside the target directory rather than at Tests/Fixtures:
            // a resource path reaching outside the target works on the current
            // toolchain but is not something SwiftPM documents as supported,
            // and sharing one fixture across targets is not worth that bet.
            resources: [.copy("Fixtures")],
            swiftSettings: baseSettings,
        ),
        .testTarget(
            name: "HanReaderTokenizationTests",
            dependencies: ["HanReaderTokenization"],
            swiftSettings: baseSettings,
        ),
        .testTarget(
            name: "HanReaderPersistenceTests",
            dependencies: ["HanReaderPersistence"],
            swiftSettings: baseSettings,
        ),
        .testTarget(
            name: "HanReaderDictionaryImportTests",
            dependencies: ["HanReaderDictionaryImport"],
            swiftSettings: baseSettings,
        ),
        // Apple-only by nature: this target exists to test the conversions
        // that cannot live in HanReaderCore because Linux has no encoding
        // tables for them, so there is nothing here that could run anywhere
        // else.
        // Apple-only by nature, like the platform tests: speech synthesis
        // has no equivalent anywhere else.
        .testTarget(
            name: "HanReaderPlaybackTests",
            dependencies: ["HanReaderPlayback"],
            swiftSettings: mainActorSettings,
        ),
        .testTarget(
            name: "HanReaderPlatformTests",
            dependencies: ["HanReaderPlatform"],
            swiftSettings: mainActorSettings,
        ),
        .testTarget(
            name: "HanReaderUITests",
            dependencies: ["HanReaderUI"],
            swiftSettings: mainActorSettings,
        ),
    ],
)
