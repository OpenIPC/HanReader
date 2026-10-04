// HanReader — MIT licensed. See LICENSE.

import Foundation
public import HanReaderCore

/// Namespace for the `HanReaderTokenization` module.
///
/// The only place `NaturalLanguage` may be imported. `NLTokenizer` is a closed,
/// OS-version-dependent model: its segmentation of a given Chinese sentence can
/// change with a system update, so a test asserting on its exact output is
/// flaky by construction. Isolating it here lets `HanReaderCore` carry a
/// deterministic maximum-matching segmenter that tests *can* pin, with both
/// reachable through the same `Tokenizing` seam.
///
/// - Note: This is scaffolding. The segmenters arrive in milestone M4.
public enum HanReaderTokenization: HanReaderModule {
    public static let moduleName = "HanReaderTokenization"
    public static let moduleDependencies = [HanReaderCore.moduleName]
}
