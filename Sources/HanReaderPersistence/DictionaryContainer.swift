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

        let encoder = JSONEncoder()
        var written = 0

        for chunk in entries.chunked(into: batchSize) {
            // One transaction per batch rather than per row. With a row at a
            // time this takes minutes; batched it takes seconds.
            try queue.write { db in
                for entry in chunk {
                    try db.execute(sql: """
                        INSERT INTO entry
                            (simplified, traditional, readingNumeric,
                             readingDisplay, senses, summary)
                        VALUES (?, ?, ?, ?, ?, ?)
                    """, arguments: [
                        entry.headword.simplified,
                        entry.headword.traditional,
                        entry.readingKey,
                        entry.readingDisplay,
                        encoder.encode(entry.senses),
                        entry.summarySense?.gloss.text ?? "",
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

    private static func writeMetadata(
        _ metadata: DictionaryMetadata,
        to queue: DatabaseQueue,
    ) throws {
        let values: [String: String?] = [
            "formatVersion": String(DictionarySchema.formatVersion),
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
        let decoder = JSONDecoder()
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
                    senses: decoder.decode([Sense].self, from: row["senses"]),
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

    public func entryCount() throws -> Int {
        try dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM entry") ?? 0
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
