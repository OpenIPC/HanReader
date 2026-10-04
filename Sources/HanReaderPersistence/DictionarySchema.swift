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
    static let formatVersion = 1

    static func migrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1_initial") { db in
            try createMetaTable(db)
            try createEntryTable(db)
            try createLexemeTable(db)
            try createCharReadingTable(db)
            try createSyllableBaseTable(db)
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
}
