// HanReader — MIT licensed. See LICENSE.

import Foundation
import HanReaderCore
import HanReaderDictionaryImport
import HanReaderPersistence
import HanReaderPlatform
import HanReaderPlayback
import HanReaderTokenization

/// Namespace for the `HanReaderUI` module.
///
/// Every view and view model, shared by both application targets. Around 85% of
/// the UI is literally one view on both platforms; what diverges is confined to
/// a `Platform/` subdirectory, the only place in this module where `#if os(` is
/// permitted.
///
/// - Note: This is scaffolding. The reader arrives in milestone M5.
public enum HanReaderUI {
    /// Proves at compile time that this module links every engine module.
    ///
    /// Each entry resolves through a different module, so dropping any one
    /// dependency from `Package.swift` stops this compiling. What the package
    /// graph actually *declares* is asserted separately, against the manifest
    /// itself, by the `architecture` CI job.
    public static let linkedVersions = [
        HanReaderCore.version,
        HanReaderTokenization.coreVersion,
        HanReaderPersistence.coreVersion,
        HanReaderDictionaryImport.linkedVersions.first ?? "",
        HanReaderPlayback.coreVersion,
        HanReaderPlatform.coreVersion,
    ]
}
