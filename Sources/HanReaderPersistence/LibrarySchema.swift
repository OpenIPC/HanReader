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

        migrator.registerMigration("v2_dictionary_preferences") { db in
            try createDictionaryPreferenceTable(db)
        }

        migrator.registerMigration("v3_listening_practice") { db in
            try createPhraseTable(db)
            try createDictationAttemptTable(db)
        }

        return migrator
    }

    // MARK: - v2: what the reader has decided about each dictionary

    /// The reader's choices about an installed dictionary, and nothing else.
    ///
    /// **In the library database, not the dictionary one.** `dictionaries` is
    /// derived data that can be deleted and rebuilt; an ordering someone
    /// dragged into place cannot. It is also the half that belongs in a
    /// backup.
    ///
    /// **No path, and no copy of the dictionary's own metadata.** A container
    /// is found by scanning the dictionaries directory, so there is no stored
    /// path to go stale — which on iOS it would, since the container
    /// directory's UUID changes across installs and restores. And its name,
    /// licence and attribution are read from the container's own `meta` every
    /// time, so the Acknowledgements screen cannot show a licence the file
    /// contradicts. A row here is the reader's opinion; the file is the fact.
    ///
    /// A dictionary with no row is not disabled — it is one the reader has
    /// not had an opinion about yet, and gets sensible defaults from its own
    /// gloss language against theirs.
    private static func createDictionaryPreferenceTable(_ db: Database) throws {
        try db.create(table: "dictionaryPreference") { table in
            table.column("slug", .text).notNull().primaryKey()

            // Three permissions rather than one switch. A reader can turn off
            // CC-CEDICT's English glosses and still need it: 77% of BKRS
            // entries carry no reading, so its single-character headwords are
            // what put pinyin on the page in both language modes.
            table.column("providesGlosses", .boolean).notNull().defaults(to: true)
            table.column("providesReadings", .boolean).notNull().defaults(to: true)
            // Whether its headwords feed the segmenter. Off by default for a
            // dictionary whose headwords are not words: BKRS contributes
            // 1,806,893 lexemes, which is both a quarter of a gigabyte in
            // memory and a word list in which almost every run of Han
            // characters is a word — the condition under which
            // maximum-matching produces confident nonsense.
            table.column("providesLexicon", .boolean).notNull().defaults(to: false)

            table.column("sortOrder", .integer).notNull()
        }
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

    // MARK: - v3: listening and dictation

    /// One practice unit: a span of the text and the span of audio that says
    /// it.
    ///
    /// Derived data — it can always be computed again from the text and the
    /// recording — but not *cheaply*: the audio has to be run through speech
    /// recognition to produce it, which costs seconds and a model download.
    /// Storing it is the difference between opening a text and waiting for
    /// one.
    ///
    /// Keyed on `(textId, idx)` rather than carrying an id of its own.
    /// Phrases have no identity apart from their position in their text, and
    /// re-aligning a recording replaces the lot.
    private static func createPhraseTable(_ db: Database) throws {
        try db.create(table: "phrase") { table in
            table.column("textId", .integer)
                .notNull()
                .references("text", onDelete: .cascade)
            table.column("idx", .integer).notNull()
            // Seconds into the recording.
            table.column("startTime", .double).notNull()
            table.column("endTime", .double).notNull()
            // UTF-16 offsets into `text.content`, the same unit as
            // `readingPosition.characterOffset` and `Token.range`.
            table.column("textStart", .integer).notNull()
            table.column("textEnd", .integer).notNull()
            // How much of this phrase the recogniser actually matched, as
            // against bridged across its own mistakes. Low values are what
            // the UI offers for review rather than silently trusting.
            table.column("confidence", .double).notNull()
            // 'recognised' or 'manual'. A boundary the reader dragged must
            // survive a re-alignment of everything around it, so the two are
            // distinguishable.
            table.column("origin", .text).notNull()
            // NULL until the reader says. A replay filter, not a schedule:
            // this is deliberately not an SRS.
            table.column("grade", .text)
            table.primaryKey(["textId", "idx"])
        }
    }

    /// The last attempt at one phrase.
    ///
    /// The latest rather than a history, and a count beside it. A history is
    /// a reporting feature nobody asked for; what a learner wants to know is
    /// whether they have it *now*.
    private static func createDictationAttemptTable(_ db: Database) throws {
        try db.create(table: "dictationAttempt") { table in
            table.column("textId", .integer)
                .notNull()
                .references("text", onDelete: .cascade)
            table.column("idx", .integer).notNull()
            table.column("typed", .text).notNull()
            table.column("accuracy", .double).notNull()
            table.column("attempts", .integer).notNull()
            table.column("updatedAt", .datetime).notNull()
            table.primaryKey(["textId", "idx"])
        }
    }

    private static func createAppStateTable(_ db: Database) throws {
        try db.create(table: "appState") { table in
            table.column("key", .text).notNull().primaryKey()
            table.column("value", .text).notNull()
        }
    }
}
