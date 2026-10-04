// HanReader — MIT licensed. See LICENSE.

import Foundation
import GRDB

/// Migrations for the library database.
///
/// Versioned from the first release. The prototype created its tables with
/// `CREATE TABLE IF NOT EXISTS` at startup, which cannot express "add a
/// column" — so its first schema change would have been either a data-loss
/// event or a hand-rolled migrator written under pressure.
///
/// Rules for editing this file:
///
/// - **Never change a migration that has shipped.** Add a new one. A shipped
///   migration has already run on real libraries; editing it changes what new
///   installs get without changing what existing ones have.
/// - **Never renumber.** Identifiers are stable strings, not ordinals.
enum LibrarySchema {
    static func migrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()

        #if DEBUG
            // Debug only. In release this would silently delete a user's library
            // the first time a developer forgot to write a migration.
            migrator.eraseDatabaseOnSchemaChange = true
        #endif

        migrator.registerMigration("v1_initial") { db in
            try createTextTable(db)
            try createAudioTable(db)
            try createReadingPositionTable(db)
            try createRevealedWordTable(db)
            try createAppStateTable(db)
        }

        return migrator
    }

    // MARK: - v1 tables

    private static func createTextTable(_ db: Database) throws {
        try db.create(table: "text") { table in
            table.autoIncrementedPrimaryKey("id")
            table.column("title", .text).notNull()
            table.column("content", .text).notNull()

            // Deduplication is on CONTENT, not title. The prototype compared
            // titles and silently did nothing when they matched, so
            // re-importing an edited file looked like a broken button. Two
            // files with the same name are normal; two with identical content
            // are the actual duplicate.
            table.column("contentHash", .blob).notNull()

            table.column("characterCount", .integer).notNull()

            // Materialised at import. Deriving it on read meant loading every
            // document's full body just to draw the sidebar.
            table.column("preview", .text).notNull()

            table.column("sourceName", .text)
            table.column("importedAt", .datetime).notNull()
            table.column("lastOpenedAt", .datetime)
        }
        try db.create(
            index: "text_on_contentHash",
            on: "text",
            columns: ["contentHash"],
            unique: true,
        )
    }

    private static func createAudioTable(_ db: Database) throws {
        try db.create(table: "audioTrack") { table in
            table.column("textId", .integer)
                .notNull()
                .primaryKey()
                .references("text", onDelete: .cascade)
            // Relative to the audio directory. An absolute path embeds the
            // container UUID, which iOS changes across installs and restores.
            table.column("relativePath", .text).notNull()
            table.column("duration", .double)
            table.column("importedAt", .datetime).notNull()
        }
    }

    private static func createReadingPositionTable(_ db: Database) throws {
        try db.create(table: "readingPosition") { table in
            table.column("textId", .integer)
                .notNull()
                .primaryKey()
                .references("text", onDelete: .cascade)
            table.column("blockIndex", .integer).notNull()
            table.column("tokenIndex", .integer).notNull()
            // The durable anchor; the two indices above are derived from it
            // and can be recomputed after re-segmentation.
            table.column("characterOffset", .integer).notNull()
            table.column("audioTime", .double)
            table.column("updatedAt", .datetime).notNull()
        }
    }

    private static func createRevealedWordTable(_ db: Database) throws {
        // Relational, not a newline-joined blob. The prototype packed the set
        // into one string, which breaks on any word containing a newline and
        // rewrites every entry on each tap.
        try db.create(table: "revealedWord") { table in
            table.column("textId", .integer)
                .notNull()
                .references("text", onDelete: .cascade)
            table.column("word", .text).notNull()
            table.column("revealedAt", .datetime).notNull()
            table.primaryKey(["textId", "word"])
        }
    }

    private static func createAppStateTable(_ db: Database) throws {
        try db.create(table: "appState") { table in
            table.column("key", .text).notNull().primaryKey()
            table.column("value", .text).notNull()
        }
    }
}
