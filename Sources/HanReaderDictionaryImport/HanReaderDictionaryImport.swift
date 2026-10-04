// HanReader — MIT licensed. See LICENSE.

import Foundation
import HanReaderCore
import HanReaderPersistence

/// Namespace for the `HanReaderDictionaryImport` module.
///
/// Streaming ingestion for both dictionary formats. The parsers themselves live
/// in `HanReaderCore`, since they are pure functions over bytes; this module
/// owns the I/O around them: chunked reads with a fixed memory ceiling,
/// throttled progress, cancellation, and resumability.
///
/// Resumability is a requirement rather than a refinement. A full BKRS import
/// is roughly 350 MB of UTF-16 source, and on iOS the app will be suspended or
/// killed partway through, so progress is checkpointed at card boundaries
/// inside the same transaction as the batch it describes.
///
/// - Note: This is scaffolding. CC-CEDICT ingestion arrives in M3, DSL in M6.
public enum HanReaderDictionaryImport {
    /// Proves at compile time that this module links both of its dependencies.
    public static let linkedVersions = [
        HanReaderCore.version,
        HanReaderPersistence.coreVersion,
    ]
}
