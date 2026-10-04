// HanReader — MIT licensed. See LICENSE.

import Testing

@testable import HanReaderCore

/// Asserts the package graph links as `Package.swift` declares.
///
/// These are scaffolding tests for milestone M1. Their job is narrow but real:
/// prove that all nine targets compile and link, and that a module's declared
/// dependencies match its actual ones. They are expected to be replaced as each
/// module gains behaviour worth testing instead.
@Suite("Module graph")
struct ModuleGraphTests {
    @Test("Core declares no HanReader dependencies")
    func coreIsALeaf() {
        #expect(HanReaderCore.moduleName == "HanReaderCore")
        #expect(HanReaderCore.moduleDependencies.isEmpty)
    }
}
