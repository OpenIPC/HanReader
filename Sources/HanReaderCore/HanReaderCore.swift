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
/// Apple's closed `NLTokenizer`, and it gives the architecture a boundary a
/// build can check.
///
/// Three CI checks enforce it together, because no one of them is sufficient:
/// an import allowlist proves the Foundation-only rule itself; compiling this
/// target inside a Linux container proves it genuinely builds off-Apple; and a
/// check against the package manifest catches a dependency added to
/// `Package.swift` that no source file has started using yet. A Linux build
/// alone would happily accept `import Dispatch`.
///
/// - Note: This is scaffolding. The domain model arrives in milestone M2.
public enum HanReaderCore {

    /// The HanReader version, and the single source of truth for it.
    ///
    /// Read by `hanreader-dictgen --version` and recorded in generated
    /// dictionary containers so a database can be traced to the build that
    /// produced it. The application targets' `MARKETING_VERSION` is derived
    /// from this value rather than maintained separately.
    public static let version = "0.1.0-dev"
}
