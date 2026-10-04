// HanReader — MIT licensed. See LICENSE.

import Foundation

/// Namespace for the `HanReaderCore` module.
///
/// This module owns the domain: value types, both dictionary-format parsers,
/// the pinyin engine, the token model, and the pure line-breaking algorithm the
/// reader's layout is built on.
///
/// It imports **only Foundation**. That constraint is not stylistic — it keeps
/// the bulk of the test suite runnable in seconds with no simulator, it keeps
/// segmentation testable against a deterministic engine rather than against
/// Apple's closed `NLTokenizer`, and it gives the architecture a boundary that
/// a build can check. A Linux CI job compiles this target in isolation, which
/// is what actually enforces the rule: `NaturalLanguage` and `AVFoundation` are
/// every bit as Apple-only as `AppKit`, so forbidding only `AppKit` would be
/// too weak a test.
///
/// - Note: This is scaffolding. The domain model arrives in milestone M2.
public enum HanReaderCore: HanReaderModule {
    public static let moduleName = "HanReaderCore"
    public static let moduleDependencies: [String] = []
}

/// Describes a module's position in the package graph.
///
/// Conformances exist so that the linkage tests can assert the dependency graph
/// matches what `Package.swift` declares, catching a module that silently loses
/// or gains a dependency during a refactor.
///
/// - Note: Scaffolding for milestone M1; expected to be removed once each
///   module carries real public API worth asserting against instead.
public protocol HanReaderModule: Sendable {
    /// The module's own name.
    static var moduleName: String { get }
    /// The names of the HanReader modules this one links against directly.
    static var moduleDependencies: [String] { get }
}
