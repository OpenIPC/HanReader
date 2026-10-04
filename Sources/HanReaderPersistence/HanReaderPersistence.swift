// HanReader — MIT licensed. See LICENSE.

import Foundation
public import HanReaderCore

/// Namespace for the `HanReaderPersistence` module.
///
/// Owns every GRDB call in the project, the schema, and its migrations. No GRDB
/// type may appear in this module's public API; `InternalImportsByDefault`
/// makes such a leak a compile error rather than a review comment, which keeps
/// the storage engine replaceable with a blast radius of one directory.
///
/// GRDB was chosen over hand-rolled `sqlite3` for three concrete reasons: its
/// database handles are `Sendable`, so the `nonisolated(unsafe) let db:
/// OpaquePointer` escape hatch the prototype needed simply does not arise; it
/// provides a real migration system, which the prototype lacked entirely; and
/// an in-memory database is one line, making persistence tests hermetic.
///
/// - Note: This is scaffolding. The schema and migrations arrive in M2.
public enum HanReaderPersistence: HanReaderModule {
    public static let moduleName = "HanReaderPersistence"
    public static let moduleDependencies = [HanReaderCore.moduleName]
}
