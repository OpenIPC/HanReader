// HanReader — MIT licensed. See LICENSE.

import Foundation
public import HanReaderCore
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
public enum HanReaderUI: HanReaderModule {
    public static let moduleName = "HanReaderUI"
    public static let moduleDependencies = [
        HanReaderCore.moduleName,
        HanReaderTokenization.moduleName,
        HanReaderPersistence.moduleName,
        HanReaderDictionaryImport.moduleName,
        HanReaderPlayback.moduleName,
        HanReaderPlatform.moduleName,
    ]
}
