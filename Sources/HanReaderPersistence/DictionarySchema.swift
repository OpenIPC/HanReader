// HanReader — MIT licensed. See LICENSE.

import Foundation
import GRDB

/// Migrations for a dictionary container.
///
/// A dictionary is a self-contained SQLite file — the `.hanreaderdict` format.
/// One file per dictionary, which is what makes CC-CEDICT and an imported BKRS
/// peers rather than one being special: same schema, same query path, same
/// code, different files.
///
/// It also gives licensing a physical boundary. A database generated from
/// CC-CEDICT is an Adapted Work under CC BY-SA 4.0, and keeping it in its own
/// file with its own `meta` table means the terms travel with the data instead
/// of being asserted somewhere else.
enum DictionarySchema {
    /// Bumped when the *schema* changes.
    ///
    /// Distinct from a parser version: no schema migration can repair data
    /// that was parsed wrongly, so a parser fix invalidates a container
    /// through `meta.parserVersion` and triggers a rebuild instead.
    static let formatVersion = 2

    static func migrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1_initial") { db in
            try createMetaTable(db)
            try createEntryTable(db)
            try createLexemeTable(db)
            try createCharReadingTable(db)
            try createSyllableBaseTable(db)
        }

        // A separate migration rather than an edit to v1, even though nothing
        // has been released yet. A container is a file on a reader's disk the
        // moment they import a dictionary, and the habit of editing the
        // migration that built it is the one that eventually destroys
        // somebody's data.
        migrator.registerMigration("v2_resumable_import") { db in
            try addSourceAnchors(db)
            try createImportJobTable(db)
        }

        return migrator
    }

    // MARK: - v1 tables

    /// Provenance and attribution, carried inside the file.
    ///
    /// The in-app Acknowledgements screen renders licence and attribution from
    /// here rather than from a hardcoded list, so it is correct by
    /// construction for user-imported dictionaries too — which is what
    /// CC BY-SA compliance actually requires.
    private static func createMetaTable(_ db: Database) throws {
        try db.create(table: "meta") { table in
            table.column("key", .text).notNull().primaryKey()
            table.column("value", .text).notNull()
        }
    }

    private static func createEntryTable(_ db: Database) throws {
        try db.create(table: "entry") { table in
            table.autoIncrementedPrimaryKey("id")
            table.column("simplified", .text).notNull()
            table.column("traditional", .text)

            // The cross-dictionary merge key. BKRS stores diacritics and
            // CC-CEDICT numerals; both normalise to this so that 了's two
            // readings group as two, not four.
            table.column("readingNumeric", .text).notNull()
            table.column("readingDisplay", .text).notNull()

            table.column("senses", .blob).notNull()

            // First gloss, denormalised. Lets a result list render without
            // decoding the sense payload of every row.
            table.column("summary", .text).notNull()
        }

        // Lookup is by headword, and must return ALL matching entries: 和 has
        // eight. The prototype's `LIMIT 1` is what this index exists to make
        // unnecessary.
        try db.create(index: "entry_on_simplified", on: "entry", columns: ["simplified"])
        try db.create(
            index: "entry_on_traditional",
            on: "entry",
            columns: ["traditional"],
            condition: Column("traditional") != nil,
        )
    }

    /// The segmentation word list, deliberately separate from `entry`.
    ///
    /// Measured on BKRS: 532,881 of its headwords are seven characters or
    /// longer — idioms, proper nouns and phrase-level entries. Maximum-matching
    /// over a raw headword set would therefore swallow whole clauses. This
    /// table holds only what is genuinely word-like, with a weight that
    /// penalises length.
    private static func createLexemeTable(_ db: Database) throws {
        try db.create(table: "lexeme") { table in
            table.column("word", .text).notNull().primaryKey()
            table.column("charLength", .integer).notNull()
            table.column("weight", .double).notNull()
        }
        try db.create(index: "lexeme_on_charLength", on: "lexeme", columns: ["charLength"])
    }

    /// Per-character readings, for words no dictionary lists as a unit.
    ///
    /// Not optional. 77% of BKRS entries (2,650,218 of 3,434,222) store no
    /// reading at all, so without a character-level fallback a
    /// Russian-preferring reader would see pinyin on almost nothing.
    private static func createCharReadingTable(_ db: Database) throws {
        try db.create(table: "charReading") { table in
            table.column("character", .text).notNull()
            table.column("readingNumeric", .text).notNull()
            table.column("readingDisplay", .text).notNull()
            // 0 is the best candidate. CC-CEDICT carries no frequency data, so
            // this is a heuristic ranking, not ground truth.
            table.column("rank", .integer).notNull()
            table.primaryKey(["character", "rank"])
        }
    }

    /// The toneless syllable inventory observed in this dictionary.
    ///
    /// Feeds the syllabifier, which needs a base set to split a run-together
    /// BKRS reading such as `sānbǐxīhé`. Derived from real data rather than
    /// from a table written out by hand.
    private static func createSyllableBaseTable(_ db: Database) throws {
        try db.create(table: "syllableBase") { table in
            table.column("base", .text).notNull().primaryKey()
        }
    }

    // MARK: - v2: resumable import

    /// Where each entry came from in the source.
    ///
    /// Only an import that can be interrupted needs these, which is why they
    /// are not in v1. A resumed import deletes everything at or past its
    /// checkpoint before writing again, so a batch that was partly committed
    /// cannot leave duplicates behind — the belt to the braces of writing the
    /// rows and the checkpoint in one transaction.
    private static func addSourceAnchors(_ db: Database) throws {
        try db.alter(table: "entry") { table in
            table.add(column: "sourceFile", .integer).notNull().defaults(to: 0)
            table.add(column: "sourceOffset", .integer).notNull().defaults(to: 0)
        }
        try db.create(
            index: "entry_on_source",
            on: "entry",
            columns: ["sourceFile", "sourceOffset"],
        )
    }

    /// The one in-progress import, if there is one.
    ///
    /// Resumability is a requirement rather than a refinement: a BKRS set is
    /// ~350 MB of UTF-16, and on iOS the app will be suspended or killed part
    /// way through. One row, because a container holds one dictionary.
    ///
    /// The source is identified by name, size and modification time rather
    /// than by path. A path is the wrong anchor on iOS, where the container
    /// directory's UUID changes across installs and restores — the same
    /// mistake the predecessor made storing absolute audio paths. Size and
    /// mtime are what answer the question that actually matters on resume:
    /// is this the same file I was part way through?
    private static func createImportJobTable(_ db: Database) throws {
        try db.create(table: "importJob") { table in
            // A single row, enforced rather than assumed.
            table.column("id", .integer).notNull().primaryKey().check { $0 == 1 }

            table.column("fileIndex", .integer).notNull()
            table.column("byteOffset", .integer).notNull()
            table.column("fileCount", .integer).notNull()

            table.column("sourceName", .text).notNull()
            table.column("sourceSize", .integer).notNull()
            table.column("sourceModified", .double).notNull()
            table.column("totalBytes", .integer).notNull()

            // A parser fix invalidates what was already written, so a resume
            // across versions starts again rather than stitching output from
            // two parsers together.
            table.column("parserVersion", .integer).notNull()

            table.column("entriesWritten", .integer).notNull()
            table.column("cardsRead", .integer).notNull()
            table.column("diagnostics", .integer).notNull()

            // A headword at the end of a file whose article is at the start of
            // the next one. Zero for a card-aligned set; carried across the
            // seam for a set someone split on a byte boundary.
            table.column("leadingHeadwords", .text).notNull()

            table.column("updatedAt", .double).notNull()
        }
    }
}
