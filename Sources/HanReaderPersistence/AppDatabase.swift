// HanReader — MIT licensed. See LICENSE.

public import Foundation
import GRDB
import HanReaderCore

/// Opens and migrates HanReader's databases.
///
/// There are deliberately **two**, with different lifecycles:
///
/// - `library.sqlite` is small, authored by the user, and must be backed up.
/// - `dictionaries.sqlite` runs to a couple of hundred megabytes, is entirely
///   regenerable from its sources, and is **excluded from backup**. Putting
///   200 MB of derived data into every user's iCloud backup would be a real
///   defect, and keeping it separate also means a corrupted dictionary can be
///   deleted and rebuilt without touching anything the user wrote.
/// Why a database could not be opened.
public enum DatabaseOpenError: Error, Sendable, LocalizedError {
    /// The file was written by a newer build of HanReader.
    case createdByNewerVersion

    public var errorDescription: String? {
        switch self {
        case .createdByNewerVersion:
            "This library was created by a newer version of HanReader."
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .createdByNewerVersion:
            "Update HanReader to open it. Opening it with this version could damage it."
        }
    }
}

public enum AppDatabase {
    /// Where the databases live.
    public struct Locations: Sendable {
        public let library: URL
        public let dictionaries: URL
        public let audio: URL

        public init(library: URL, dictionaries: URL, audio: URL) {
            self.library = library
            self.dictionaries = dictionaries
            self.audio = audio
        }

        /// The standard locations inside the application's support directory.
        ///
        /// Identical code on both platforms: `FileManager` already returns the
        /// container on iOS and `~/Library/Application Support` on macOS, so
        /// this needs no platform branch.
        public static func standard(
            fileManager: FileManager = .default,
            applicationName: String = "HanReader",
        ) throws
            -> Self
        {
            let support = try fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true,
            )
            let root = support.appendingPathComponent(applicationName, isDirectory: true)
            return Self(
                library: root.appendingPathComponent("library.sqlite"),
                dictionaries: root.appendingPathComponent("dictionaries.sqlite"),
                audio: root.appendingPathComponent("audio", isDirectory: true),
            )
        }
    }

    // MARK: - Opening

    /// Opens the library database, creating and migrating it as needed.
    ///
    /// Deliberately **not** public: `DatabaseQueue` is a GRDB type, and
    /// returning one would put GRDB in this module's public API. The compiler
    /// rejects that outright thanks to `InternalImportsByDefault`, which is
    /// how the rule in Docs/ARCHITECTURE.md is actually enforced rather than
    /// merely asserted. Callers construct a `LibraryRepository` instead.
    static func openLibrary(at url: URL) throws -> DatabaseQueue {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
        )
        let queue = try DatabaseQueue(path: url.path, configuration: Self.configuration())
        let migrator = LibrarySchema.migrator()
        try Self.refuseFutureSchema(migrator, in: queue)
        try migrator.migrate(queue)
        return queue
    }

    /// Refuses to open a database written by a newer build.
    ///
    /// GRDB does **not** do this on its own: `migrate(_:)` ignores applied
    /// migrations it does not recognise and carries on, so an older build
    /// opening a newer library would read it through the wrong schema and
    /// write to it. For the one database holding the user's own work, failing
    /// to open is much the better outcome.
    private static func refuseFutureSchema(
        _ migrator: DatabaseMigrator,
        in queue: DatabaseQueue,
    ) throws {
        let superseded = try queue.read { db in
            try migrator.hasBeenSuperseded(db)
        }
        guard superseded else { return }
        throw DatabaseOpenError.createdByNewerVersion
    }

    /// An in-memory library, for tests and previews.
    ///
    /// One line, which is a large part of why GRDB was chosen: with the
    /// hand-rolled sqlite3 layer every persistence test needed a temporary
    /// file and careful teardown.
    static func inMemoryLibrary() throws -> DatabaseQueue {
        let queue = try DatabaseQueue(configuration: Self.configuration())
        try LibrarySchema.migrator().migrate(queue)
        return queue
    }

    private static func configuration() -> Configuration {
        var configuration = Configuration()
        // Off by default in SQLite, so the ON DELETE CASCADE rules in the
        // schema would not actually fire. The prototype deleted reading
        // progress by hand and leaked its audio rows entirely.
        configuration.foreignKeysEnabled = true
        configuration.prepareDatabase { db in
            // Durable enough for user data without an fsync per write.
            try db.execute(sql: "PRAGMA journal_mode = WAL")
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
            try db.execute(sql: "PRAGMA busy_timeout = 5000")
        }
        return configuration
    }

    // MARK: - Backup exclusion

    /// Marks a URL as excluded from backup.
    ///
    /// Applied to the dictionary database, which is large and regenerable.
    /// Not applied to the library, which is the user's own work.
    public static func excludeFromBackup(_ url: URL) throws {
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }
}
