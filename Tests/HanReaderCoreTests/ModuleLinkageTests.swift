// HanReader — MIT licensed. See LICENSE.

import Testing
@testable import HanReaderCore

/// Proves the target compiles and that its version constant is well formed.
///
/// These tests deliberately claim nothing about the *package graph*. A Swift
/// test cannot read `Package.swift`, so comparing a hand-maintained constant
/// against a hand-written literal would only restate itself. The declared graph
/// is asserted against the manifest by the `architecture` CI job, which reads
/// `swift package dump-package`.
@Suite("Core module")
struct CoreModuleTests {
    @Test("Version is a non-empty semantic-looking string")
    func versionIsWellFormed() {
        let version = HanReaderCore.version
        #expect(!version.isEmpty)
        // Major.minor.patch, optionally with a pre-release suffix.
        #expect(version.split(separator: ".").count >= 3)
        #expect(version.first?.isNumber == true)
    }
}
