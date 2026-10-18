// HanReader — MIT licensed. See LICENSE.

public import Foundation
import GRDB
public import HanReaderCore

/// A compiled dictionary: one `.hanreaderdict` file.
///
/// Writing and reading are both here because they share the schema, but they
/// run in different places — writing in `hanreader-dictgen` at build time,
/// reading in the app.
public struct DictionaryContainer: Sendable {
    private let dbQueue: DatabaseQueue

    // MARK: - Opening

    /// Opens an existing container for reading.
    public init(contentsOf url: URL) throws {
        var configuration = Configuration()
        configuration.readonly = true
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA query_only = ON")
        }
        dbQueue = try DatabaseQueue(path: url.path, configuration: configuration)
    }

    private init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    // MARK: - Writing

    /// Compiles entries into a new container at `url`, replacing any existing
    /// file.
    ///
    /// Durability pragmas are deliberately off during the write. The output is
    /// a build artefact regenerated from its source in seconds, so there is
    /// nothing to protect against a crash — and leaving them on costs an fsync
    /// per transaction for no benefit.
    public static func write(
        entries: [DictionaryEntry],
        metadata: DictionaryMetadata,
        to url: URL,
        batchSize: Int = 5000,
        progress: (@Sendable (Double) -> Void)? = nil,
    ) throws {
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
        )

        var configuration = Configuration()
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode = OFF")
            try db.execute(sql: "PRAGMA synchronous = OFF")
        }
        let queue = try DatabaseQueue(path: url.path, configuration: configuration)
        try DictionarySchema.migrator().migrate(queue)

        let codec = SensePayloadCodecs.current
        var written = 0

        for chunk in entries.chunked(into: batchSize) {
            // One transaction per batch rather than per row. With a row at a
            // time this takes minutes; batched it takes seconds.
            try queue.write { db in
                for entry in chunk {
                    try db.execute(sql: """
                        INSERT INTO entry
                            (simplified, traditional, readingNumeric,
                             readingDisplay, senses)
                        VALUES (?, ?, ?, ?, ?)
                    """, arguments: [
                        entry.headword.simplified,
                        entry.headword.traditional,
                        entry.readingKey,
                        entry.readingDisplay,
                        codec.encode(entry.senses),
                    ])
                }
            }
            written += chunk.count
            progress?(Double(written) / Double(max(entries.count, 1)))
        }

        try writeDerivedTables(entries: entries, to: queue, batchSize: batchSize)
        try writeMetadata(metadata, to: queue)

        // Cheap, and it is what lets the planner choose the headword index
        // rather than scanning a hundred thousand rows.
        try queue.write { db in try db.execute(sql: "ANALYZE") }
    }

    private static func writeDerivedTables(
        entries: [DictionaryEntry],
        to queue: DatabaseQueue,
        batchSize: Int,
    ) throws {
        for chunk in LexiconBuilder.lexicon(from: entries).chunked(into: batchSize) {
            try queue.write { db in
                for lexeme in chunk {
                    try db.execute(
                        sql: "INSERT INTO lexeme (word, charLength, weight) VALUES (?, ?, ?)",
                        arguments: [
                            lexeme.word,
                            lexeme.characterLength,
                            lexeme.weight,
                        ],
                    )
                }
            }
        }

        for chunk in LexiconBuilder.characterReadings(from: entries).chunked(into: batchSize) {
            try queue.write { db in
                for reading in chunk {
                    try db.execute(sql: """
                        INSERT INTO charReading (character, readingNumeric, readingDisplay, rank)
                        VALUES (?, ?, ?, ?)
                    """, arguments: [
                        String(reading.character), reading.numeric, reading.display, reading.rank,
                    ])
                }
            }
        }

        let bases = LexiconBuilder.syllableBases(from: entries)
        try queue.write { db in
            for base in bases.sorted() {
                try db.execute(sql: "INSERT INTO syllableBase (base) VALUES (?)", arguments: [base])
            }
        }
    }

    static func writeMetadata(
        _ metadata: DictionaryMetadata,
        to queue: DatabaseQueue,
    ) throws {
        let values: [String: String?] = [
            "formatVersion": String(DictionarySchema.formatVersion),
            // Which codec wrote the sense payloads, so a reader picks the one
            // that can read them rather than assuming the current one.
            "sensePayloadCodec": type(of: SensePayloadCodecs.current).identifier,
            "slug": metadata.slug,
            "displayName": metadata.displayName,
            "format": metadata.format,
            "indexLanguage": metadata.indexLanguage,
            "glossLanguage": metadata.glossLanguage,
            "licence": metadata.licence,
            "attribution": metadata.attribution,
            "sourceURL": metadata.sourceURL,
            "sourceVersion": metadata.sourceVersion,
            "parserVersion": String(metadata.parserVersion),
            "entryCount": String(metadata.entryCount),
            "generatedAt": ISO8601DateFormatter().string(from: metadata.generatedAt),
        ]
        try queue.write { db in
            for (key, value) in values.sorted(by: { $0.key < $1.key }) {
                guard let value else { continue }
                try db.execute(
                    sql: "INSERT INTO meta (key, value) VALUES (?, ?)",
                    arguments: [key, value],
                )
            }
        }
    }

    // MARK: - Reading

    /// The codec this container's sense payloads were written with.
    ///
    /// Read from the file rather than assumed, which is what lets a new codec
    /// land without invalidating the dictionaries already on disk — and what
    /// makes a container written by a *newer* build say so plainly instead of
    /// decoding into plausible nonsense.
    public func sensePayloadCodec() throws -> any SensePayloadCodec {
        let identifier = try dbQueue.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT value FROM meta WHERE key = 'sensePayloadCodec'",
            )
        }
        return try SensePayloadCodecs.named(identifier)
    }

    public func metadata() throws -> DictionaryMetadata? {
        let values = try dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT key, value FROM meta")
                .reduce(into: [String: String]()) { $0[$1["key"] as String] = $1["value"] as String
                }
        }
        guard let slug = values["slug"] else { return nil }
        return DictionaryMetadata(
            slug: slug,
            displayName: values["displayName"] ?? slug,
            format: values["format"] ?? "unknown",
            indexLanguage: values["indexLanguage"] ?? "zh-Hans",
            glossLanguage: values["glossLanguage"] ?? "en",
            licence: values["licence"] ?? "",
            attribution: values["attribution"] ?? "",
            sourceURL: values["sourceURL"],
            sourceVersion: values["sourceVersion"],
            parserVersion: values["parserVersion"].flatMap(Int.init) ?? 0,
            entryCount: values["entryCount"].flatMap(Int.init) ?? 0,
            generatedAt: values["generatedAt"]
                .flatMap { ISO8601DateFormatter().date(from: $0) } ?? .distantPast,
        )
    }

    /// Every entry for a headword.
    ///
    /// Returns a list, not an optional. 和 has eight entries and 了 has two
    /// readings; the prototype's `LIMIT 1` is the bug this signature exists to
    /// make impossible.
    public func entries(for headword: String) throws -> [DictionaryEntry] {
        let codec = try sensePayloadCodec()
        return try dbQueue.read { db in
            // Matched against BOTH scripts. Storing the traditional form and
            // then only ever querying the simplified one means a reader of
            // traditional text finds nothing at all -- and the index on
            // traditional existed while nothing used it.
            let sql = """
                SELECT simplified, traditional, readingNumeric, senses
                FROM entry WHERE simplified = ? OR traditional = ? ORDER BY id
            """
            return try Row.fetchAll(db, sql: sql, arguments: [headword, headword]).map { row in
                try DictionaryEntry(
                    headword: Headword(
                        simplified: row["simplified"],
                        traditional: row["traditional"],
                    ),
                    reading: Pinyin.parse(numeric: row["readingNumeric"]),
                    senses: codec.decode(row["senses"]),
                )
            }
        }
    }

    /// Candidate readings for a character, best first.
    public func readings(forCharacter character: Character) throws -> [CharacterReading] {
        try dbQueue.read { db in
            let sql = """
                SELECT readingNumeric, readingDisplay, rank
                FROM charReading WHERE character = ? ORDER BY rank
            """
            return try Row.fetchAll(db, sql: sql, arguments: [String(character)]).map { row in
                CharacterReading(
                    character: character,
                    numeric: row["readingNumeric"],
                    display: row["readingDisplay"],
                    rank: row["rank"],
                )
            }
        }
    }

    /// The segmentation lexicon, for building an in-memory matcher.
    public func lexicon() throws -> [Lexeme] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT word, charLength, weight FROM lexeme").map { row in
                Lexeme(word: row["word"], characterLength: row["charLength"], weight: row["weight"])
            }
        }
    }

    public func syllableBases() throws -> Set<String> {
        try dbQueue.read { db in
            try Set(String.fetchAll(db, sql: "SELECT base FROM syllableBase"))
        }
    }

    /// How many words the segmentation lexicon holds.
    ///
    /// Separate from `lexicon()`, which returns all of them. A BKRS container
    /// has 1,806,893, and fetching them to print one number took 450 MB — in
    /// a `--verbose` summary, where it looked for a while like the import
    /// itself had blown its memory ceiling.
    public func lexemeCount() throws -> Int {
        try dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM lexeme") ?? 0
        }
    }

    /// Where each entry came from, in row order.
    ///
    /// For verifying that a resumable import stamps each entry with its own
    /// card rather than with the one that happened to fill its batch.
    public func sourceOffsets() throws -> [Int] {
        try dbQueue.read { db in
            try Int.fetchAll(db, sql: "SELECT sourceOffset FROM entry ORDER BY id")
        }
    }

    /// The longest word in the segmentation lexicon, in characters.
    ///
    /// Asked of the database rather than by fetching the lexicon: a BKRS
    /// container holds 1,806,893 lexemes, and loading them to take a maximum
    /// costs hundreds of megabytes.
    public func longestLexeme() throws -> Int {
        try dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT max(charLength) FROM lexeme") ?? 0
        }
    }

    /// Every headword in the container, for tests that need to assert over
    /// all of them rather than look one up.
    public func headwords() throws -> [String] {
        try dbQueue.read { db in
            try String.fetchAll(db, sql: "SELECT simplified FROM entry ORDER BY id")
        }
    }

    /// Whether this file is an import that stopped part way.
    ///
    /// The job row is cleared when an import finishes, so its presence is
    /// the file saying so itself. Worth asking, because a half-imported
    /// container has no metadata yet and would otherwise be reported as
    /// unreadable — which is both wrong and unhelpful, since the answer is
    /// to import it again and it will carry on.
    public func hasUnfinishedImport() throws -> Bool {
        try dbQueue.read { db in
            guard try db.tableExists("importJob") else { return false }
            return try Int.fetchOne(db, sql: "SELECT count(*) FROM importJob") ?? 0 > 0
        }
    }

    public func entryCount() throws -> Int {
        try dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM entry") ?? 0
        }
    }
}

// MARK: - Introspection

/// Reading the shape of a container rather than its content.
///
/// Used by the tests that assert an import leaves the right indexes behind
/// and that the retired `summary` column is gone — both things a reader
/// should never need to ask, and both worth asserting once.
extension DictionaryContainer {
    /// The indexes the file actually carries.
    ///
    /// For asserting that an import leaves behind the ones a reader needs and
    /// not the one only the importer wanted.
    public func indexNames() throws -> Set<String> {
        try dbQueue.read { db in
            try Set(String.fetchAll(
                db,
                sql: "SELECT name FROM sqlite_schema WHERE type = 'index' AND name IS NOT NULL",
            ))
        }
    }

    /// The columns a table carries, for asserting that one is gone.
    public func columnNames(of table: String) throws -> Set<String> {
        try dbQueue.read { db in
            try Set(db.columns(in: table).map(\.name))
        }
    }

    /// Writes a one-entry container with a chosen codec.
    ///
    /// Only so a test can build the kind of container an earlier build
    /// produced, and prove it still opens — which is the whole point of
    /// recording the codec rather than assuming it.
    static func writeForTesting(
        entry: DictionaryEntry,
        codec: any SensePayloadCodec,
        metadata: DictionaryMetadata,
        to url: URL,
    ) throws {
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
        )
        let queue = try DatabaseQueue(path: url.path)
        try DictionarySchema.migrator().migrate(queue)
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO entry
                    (simplified, traditional, readingNumeric, readingDisplay, senses)
                VALUES (?, ?, ?, ?, ?)
            """, arguments: [
                entry.headword.simplified,
                entry.headword.traditional,
                entry.readingKey,
                entry.readingDisplay,
                codec.encode(entry.senses),
            ])
        }
        try writeMetadata(metadata, to: queue)
        try queue.write { db in
            try db.execute(
                sql: "INSERT OR REPLACE INTO meta (key, value) VALUES ('sensePayloadCodec', ?)",
                arguments: [type(of: codec).identifier],
            )
        }
    }
}

extension Array {
    /// Splits into fixed-size chunks, so a batch can be one transaction.
    func chunked(into size: Int) -> [ArraySlice<Element>] {
        guard size > 0, !isEmpty else { return isEmpty ? [] : [self[...]] }
        return stride(from: 0, to: count, by: size).map {
            self[$0 ..< Swift.min($0 + size, count)]
        }
    }
}

/// A compiled dictionary is a dictionary to look words up in.
///
/// Declared here rather than on the protocol's own side because the protocol
/// lives in `HanReaderCore`, which knows nothing about storage. The two
/// methods already existed with exactly these signatures — the conformance
/// only says out loud that this is what they are for.
extension DictionaryContainer: DictionaryLookup {}
