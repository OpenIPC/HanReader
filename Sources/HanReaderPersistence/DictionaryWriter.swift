// HanReader — MIT licensed. See LICENSE.

public import Foundation
import GRDB
public import HanReaderCore

/// A container being filled a batch at a time, able to pick up where it left
/// off.
///
/// `DictionaryContainer.write(entries:…)` takes the whole dictionary as an
/// array, which is right for CC-CEDICT: 107,619 entries parsed in under three
/// seconds at build time, and holding them costs a few tens of megabytes. It
/// is not right for a 350 MB BKRS set — 3,442,623 entries over 3,691,468
/// senses would not fit inside the import's 60 MB ceiling, and the import has
/// to survive being killed half way through.
///
/// So this writer holds no entries at all. Batches arrive, are written, and are
/// forgotten; the only state it keeps between batches is a few counters.
///
/// ### Crash safety is the whole design, and it costs a pragma
///
/// Compiling CC-CEDICT runs under `journal_mode = OFF, synchronous = OFF`,
/// which is safe there because the output is a build artefact regenerated from
/// its source in seconds — on failure you delete it and run again.
///
/// A reader's own BKRS import is not that. It takes a minute or more, and on
/// iOS the app *will* be suspended or killed part way through, so "delete it
/// and run again" is the behaviour this exists to avoid. Under
/// `journal_mode = OFF` a process killed mid-transaction can leave the file
/// corrupt, and a corrupt file cannot be resumed — the two requirements are
/// mutually exclusive, and resumability is the one that was asked for. WAL
/// with `synchronous = NORMAL` makes every committed batch survive the process
/// dying, which is exactly the guarantee `kill -9` mid-import needs. (It does
/// not promise survival of a power cut, which would need `FULL`; a dictionary
/// import is not worth an fsync per batch, and the job simply resumes from the
/// last batch that made it to disk.)
///
/// ### Rows and the checkpoint go in one transaction
///
/// Written separately, a crash between them leaves the checkpoint behind the
/// rows and the next run writes those rows again. Together, the file can only
/// ever be in a state where the checkpoint describes exactly what is in it.
/// The resume path still deletes anything at or past the checkpoint, because a
/// belt costs one indexed `DELETE` and braces alone are an argument.
public final class DictionaryWriter {
    /// When the lookup indexes get built.
    ///
    /// They are needed only once an import is finished, and the choice of
    /// *when* to build them trades the import's two budgets against each
    /// other. Measured over the full 350 MB BKRS set, same machine, same
    /// output:
    ///
    /// | | time | peak memory | size |
    /// |---|---|---|---|
    /// | `.atTheEnd` | **75 s** | 134 MB | **493 MB** |
    /// | `.whileWriting` | 188 s | **53 MB** | 556 MB |
    ///
    /// Building at the end is the ordinary bulk-load shape: one pass over
    /// rows that are all already there, instead of a random-order insert into
    /// an 84 MB B-tree three and a half million times. It is also 63 MB
    /// smaller on disk, because an index built in one pass does not carry the
    /// page splits that random insertion leaves behind.
    ///
    /// Its cost is memory: `CREATE INDEX` is a single atomic statement, so the
    /// whole new index is dirty at once — about 92 MB of it, which no
    /// `cache_size`, `temp_store`, `threads`, `soft_heap_limit` or
    /// `hard_heap_limit` pragma reduces. Measured, not assumed; all five were
    /// tried.
    ///
    /// `.atTheEnd` is the default because compiling a DSL set is a desktop
    /// operation by design — a Mac compiles it once and a phone imports the
    /// compiled container — so the import's memory ceiling, which exists for
    /// iOS, is not the binding constraint on this path. `.whileWriting` is
    /// there for the day something does run an import where it is.
    public enum Indexing: Sendable {
        case atTheEnd
        case whileWriting
    }

    /// Where the reader got to, recorded at a card boundary.
    ///
    /// A card boundary, not a line or a batch boundary, because it is the only
    /// place an import can restart without either losing a card or writing one
    /// twice.
    public struct Checkpoint: Hashable, Sendable {
        /// Index into the file set.
        public var fileIndex: Int
        /// Byte offset of the next unread card in that file.
        public var byteOffset: Int
        /// A headword whose article is in the next file. Empty for a
        /// card-aligned set.
        public var leadingHeadwords: [String]
        public var cardsRead: Int
        public var diagnostics: Int

        public init(
            fileIndex: Int = 0,
            byteOffset: Int = 0,
            leadingHeadwords: [String] = [],
            cardsRead: Int = 0,
            diagnostics: Int = 0,
        ) {
            self.fileIndex = fileIndex
            self.byteOffset = byteOffset
            self.leadingHeadwords = leadingHeadwords
            self.cardsRead = cardsRead
            self.diagnostics = diagnostics
        }
    }

    /// An entry together with the card it came from.
    ///
    /// Per entry, not per batch, and that distinction is the resume. Stamping
    /// a whole batch with the offset of the card that happened to fill it
    /// means a resume deletes every row of that batch and re-reads only its
    /// last card: measured over three `kill -9`s, 14,997 entries of 574,709
    /// simply vanished, and the import reported success.
    public struct SourcedEntry: Sendable {
        public let entry: DictionaryEntry
        public let sourceFile: Int
        public let sourceOffset: Int

        public init(entry: DictionaryEntry, sourceFile: Int, sourceOffset: Int) {
            self.entry = entry
            self.sourceFile = sourceFile
            self.sourceOffset = sourceOffset
        }
    }

    /// What the job is reading, as identity rather than as a location.
    ///
    /// A fingerprint rather than a path: on iOS the container directory's UUID
    /// changes across installs and restores, so a stored path is stale by the
    /// time it matters — the same mistake the predecessor made with absolute
    /// audio paths.
    ///
    /// The fingerprint has to cover **everything that affects the output**,
    /// which is more than the file the reader picked. Checking only the first
    /// volume lets a changed third volume resume onto entries from the old
    /// one; ignoring the syllable inventory lets a re-run with different
    /// `--bases` mix readings parsed two ways. Either produces a dictionary
    /// that is half one thing and half another, and reports success.
    public struct Source: Hashable, Sendable {
        /// The first volume's name, for messages.
        public var name: String
        /// Identity of every input: all volumes, and whatever else the parse
        /// depends on. Compared exactly.
        public var fingerprint: String
        public var fileCount: Int
        /// Across the whole set, for progress.
        public var totalBytes: Int
        public var parserVersion: Int

        public init(
            name: String,
            fingerprint: String,
            fileCount: Int,
            totalBytes: Int,
            parserVersion: Int,
        ) {
            self.name = name
            self.fingerprint = fingerprint
            self.fileCount = fileCount
            self.totalBytes = totalBytes
            self.parserVersion = parserVersion
        }
    }

    private let dbQueue: DatabaseQueue
    private let source: Source
    private let lexiconMaximumLength: Int
    private let indexing: Indexing
    private let codec = SensePayloadCodecs.current
    private var entriesWritten: Int

    /// Opens a container at `url`, resuming the job in it when there is one
    /// for this exact source.
    ///
    /// Returns nil for `resume` when the container is new, or when what is in
    /// it was built from a different file or by a different parser version. In
    /// that case everything already written is discarded first: no schema
    /// migration can reconcile output from two parsers, and half a dictionary
    /// from each is worse than either.
    /// - Parameter lexiconMaximumLength: longest headword admitted to the
    ///   segmentation lexicon. The default suits a word-level dictionary;
    ///   `LexiconBuilder.encyclopaedicWordLength` suits one whose headwords
    ///   run to phrases, which is most of BKRS.
    public static func open(
        at url: URL,
        source: Source,
        lexiconMaximumLength: Int = LexiconBuilder.maximumWordLength,
        indexing: Indexing = .atTheEnd,
    ) throws
        -> (writer: DictionaryWriter, resume: Checkpoint?)
    {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
        )

        var configuration = Configuration()
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL")
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
        }
        let queue = try DatabaseQueue(path: url.path, configuration: configuration)
        try DictionarySchema.migrator().migrate(queue)

        try prepareIndexes(queue, indexing: indexing)

        let stored = try queue.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM importJob WHERE id = 1")
        }
        let resume = stored.flatMap { row -> Checkpoint? in
            guard row["sourceFingerprint"] as String == source.fingerprint,
                  row["parserVersion"] as Int == source.parserVersion
            else { return nil }
            return Checkpoint(
                fileIndex: row["fileIndex"],
                byteOffset: row["byteOffset"],
                leadingHeadwords: Self.decodeHeadwords(row["leadingHeadwords"]),
                cardsRead: row["cardsRead"],
                diagnostics: row["diagnostics"],
            )
        }

        let written = try prepare(queue, resuming: resume, hadJob: stored != nil)

        let writer = DictionaryWriter(
            dbQueue: queue,
            source: source,
            lexiconMaximumLength: lexiconMaximumLength,
            indexing: indexing,
            entriesWritten: written,
        )
        return (writer, resume)
    }

    /// Sets up the indexes an import wants, and takes down the ones it does
    /// not.
    ///
    /// A lookup index is maintained per row while it exists, and
    /// `entry_on_simplified` means a random-order insert into an 84 MB B-tree
    /// three and a half million times. Nothing queries it until the import is
    /// over, so it comes down for the duration and is built in one pass at the
    /// end — the ordinary bulk-load shape.
    ///
    /// The source index is the mirror image: wanted only *during* an import,
    /// for the delete a resume does, and dropped when one finishes.
    ///
    /// A container interrupted part way therefore has no lookup indexes. That
    /// is correct rather than unfortunate — it is not a dictionary yet, and
    /// the `importJob` row is what says so.
    private static func prepareIndexes(_ queue: DatabaseQueue, indexing: Indexing) throws {
        try queue.write { db in
            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS entry_on_source ON entry (sourceFile, sourceOffset)
            """)
            guard indexing == .atTheEnd else { return }
            try db.execute(sql: "DROP INDEX IF EXISTS entry_on_simplified")
            try db.execute(sql: "DROP INDEX IF EXISTS entry_on_traditional")
        }
    }

    /// Makes the container ready to be written into, and says how many
    /// entries it already holds.
    private static func prepare(
        _ queue: DatabaseQueue,
        resuming resume: Checkpoint?,
        hadJob: Bool,
    ) throws
        -> Int
    {
        let existing = try queue.read { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM entry") ?? 0
        }
        guard let resume else {
            // No job to resume, so anything already here was written by a
            // different file or a different parser version. No schema
            // migration can reconcile output from two parsers, and half a
            // dictionary from each is worse than either.
            guard hadJob || existing > 0 else { return 0 }
            try queue.write { db in
                for table in ["entry", "lexeme", "charReading", "syllableBase", "meta"] {
                    try db.execute(sql: "DELETE FROM \(table)")
                }
                try db.execute(sql: "DELETE FROM importJob")
            }
            return 0
        }
        // Anything at or past the checkpoint is from a batch that did not
        // commit, or from a run that got further and was discarded. Either way
        // it is about to be written again.
        try queue.write { db in
            try db.execute(sql: """
                DELETE FROM entry
                WHERE sourceFile > ? OR (sourceFile = ? AND sourceOffset >= ?)
            """, arguments: [resume.fileIndex, resume.fileIndex, resume.byteOffset])
        }
        return try queue.read { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM entry") ?? 0
        }
    }

    private init(
        dbQueue: DatabaseQueue,
        source: Source,
        lexiconMaximumLength: Int,
        indexing: Indexing,
        entriesWritten: Int,
    ) {
        self.dbQueue = dbQueue
        self.source = source
        self.lexiconMaximumLength = lexiconMaximumLength
        self.indexing = indexing
        self.entriesWritten = entriesWritten
    }

    /// How many entries the container holds.
    public var count: Int {
        entriesWritten
    }

    // MARK: - Appending

    /// Writes a batch and the checkpoint that describes it, in one
    /// transaction.
    ///
    /// The lexicon is upserted here rather than derived at the end, because
    /// deriving it would mean decoding three and a half million sense payloads
    /// back out of the file. A word's weight depends only on its own entry, so
    /// taking the best weight per word batch by batch gives the same table as
    /// computing it over the whole dictionary at once — and it survives the
    /// process dying, since it lands in the same transaction as the rows.
    public func append(_ entries: [SourcedEntry], checkpoint: Checkpoint) throws {
        try dbQueue.write { db in
            for sourced in entries {
                let entry = sourced.entry
                try db.execute(sql: """
                    INSERT INTO entry
                        (simplified, traditional, readingNumeric, readingDisplay,
                         senses, sourceFile, sourceOffset)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                """, arguments: [
                    entry.headword.simplified,
                    entry.headword.traditional,
                    entry.readingKey,
                    entry.readingDisplay,
                    codec.encode(entry.senses),
                    sourced.sourceFile,
                    sourced.sourceOffset,
                ])
            }

            for lexeme in LexiconBuilder.lexicon(
                from: entries.map(\.entry),
                maximumLength: lexiconMaximumLength,
            ) {
                try db.execute(sql: """
                    INSERT INTO lexeme (word, charLength, weight) VALUES (?, ?, ?)
                    ON CONFLICT(word) DO UPDATE SET weight = max(weight, excluded.weight)
                """, arguments: [lexeme.word, lexeme.characterLength, lexeme.weight])
            }

            try self.writeJob(checkpoint, to: db)
        }
        entriesWritten += entries.count
    }

    /// Records a checkpoint with no entries behind it.
    ///
    /// A run of cards can produce no entries at all — a file whose remaining
    /// cards are all headwords with no article — and without this the job
    /// would appear to have made no progress and re-read them on resume.
    public func checkpoint(_ checkpoint: Checkpoint) throws {
        try dbQueue.write { db in
            try self.writeJob(checkpoint, to: db)
        }
    }

    private func writeJob(_ checkpoint: Checkpoint, to db: Database) throws {
        try db.execute(sql: """
            INSERT INTO importJob
                (id, fileIndex, byteOffset, fileCount, sourceName,
                 sourceFingerprint, totalBytes, parserVersion, entriesWritten,
                 cardsRead, diagnostics, leadingHeadwords, updatedAt)
            VALUES (1, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                fileIndex = excluded.fileIndex,
                byteOffset = excluded.byteOffset,
                entriesWritten = excluded.entriesWritten,
                cardsRead = excluded.cardsRead,
                diagnostics = excluded.diagnostics,
                leadingHeadwords = excluded.leadingHeadwords,
                updatedAt = excluded.updatedAt
        """, arguments: [
            checkpoint.fileIndex,
            checkpoint.byteOffset,
            source.fileCount,
            source.name,
            source.fingerprint,
            source.totalBytes,
            source.parserVersion,
            entriesWritten,
            checkpoint.cardsRead,
            checkpoint.diagnostics,
            Self.encodeHeadwords(checkpoint.leadingHeadwords),
            Date().timeIntervalSince1970,
        ])
    }

    // MARK: - Finishing

    /// Builds the derived tables, writes the metadata, and clears the job.
    ///
    /// The character readings and the syllable inventory are read back out of
    /// the `entry` table rather than accumulated while writing. Both need to
    /// see the whole dictionary — a character's readings are *ranked* against
    /// each other — and accumulating them in memory would be state that a
    /// crash destroys and a resume cannot rebuild. Derived at the end from
    /// what is on disk, they are correct however many times the import was
    /// interrupted. It costs one indexed pass; the single-character headwords
    /// it decodes number 33,372 in BKRS, not three million.
    public func finish(metadata: DictionaryMetadata) throws {
        try writeCharacterReadings()
        try writeSyllableBases()
        try writeMetadata(metadata)

        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM importJob")
            // The source index exists only so a resume can delete the rows
            // from a batch that did not commit. Once the import is finished
            // nothing queries it ever again, and on a BKRS-sized dictionary it
            // is 53 MB the reader would carry for nothing. The columns stay,
            // so a re-import can rebuild the index and resume as before.
            try db.execute(sql: "DROP INDEX IF EXISTS entry_on_source")

            // And now the ones a reader needs, built in one pass over rows
            // that are all already there rather than maintained as they
            // arrived. Lookup matches BOTH scripts: storing the traditional
            // form and only ever querying the simplified one means a reader of
            // traditional text finds nothing at all.
            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS entry_on_simplified ON entry (simplified)
            """)
            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS entry_on_traditional ON entry (traditional)
                WHERE traditional IS NOT NULL
            """)
            try db.execute(sql: "ANALYZE")
        }
        // Folding the write-ahead log back in leaves one file rather than
        // three, which is what the reader copies around and what the size
        // reported to them should mean.
        try dbQueue.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)")
        }
    }
}

// MARK: - Derived tables

extension DictionaryWriter {
    // Reads the single-character entries through a cursor, one at a time.

    ///
    /// Fetching them into an array first is what took peak memory to 857 MB
    /// against a 60 MB ceiling: single-character headwords are the densest
    /// cards in a dictionary — 38,618 of them in BKRS carrying 27 MB of
    /// encoded senses, 一 and 打 with 57 apiece — and decoding all of them at
    /// once, with the decoder's own intermediates on top, costs vastly more
    /// than the 27 MB suggests. The collector keeps five small values per
    /// candidate reading and the entry is released immediately.
    private func writeCharacterReadings() throws {
        var collector = LexiconBuilder.CharacterReadings()
        try dbQueue.read { db in
            let cursor = try Row.fetchCursor(db, sql: """
                SELECT simplified, traditional, readingNumeric, senses
                FROM entry WHERE length(simplified) = 1 ORDER BY id
            """)
            while let row = try cursor.next() {
                try collector.add(DictionaryEntry(
                    headword: Headword(
                        simplified: row["simplified"],
                        traditional: row["traditional"],
                    ),
                    reading: Pinyin.parse(numeric: row["readingNumeric"]),
                    senses: self.codec.decode(row["senses"]),
                ))
            }
        }
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM charReading")
            for reading in collector.ranked() {
                try db.execute(sql: """
                    INSERT INTO charReading (character, readingNumeric, readingDisplay, rank)
                    VALUES (?, ?, ?, ?)
                """, arguments: [
                    String(reading.character), reading.numeric, reading.display, reading.rank,
                ])
            }
        }
    }

    /// The toneless syllables this dictionary actually uses.
    ///
    /// Read as a cursor over the reading column alone, so three and a half
    /// million rows cost one small set rather than one large array.
    private func writeSyllableBases() throws {
        var bases: Set<String> = []
        try dbQueue.read { db in
            let cursor = try String.fetchCursor(
                db,
                sql: "SELECT readingNumeric FROM entry WHERE readingNumeric <> ''",
            )
            while let numeric = try cursor.next() {
                for token in Pinyin.parse(numeric: numeric) {
                    if case let .syllable(syllable) = token {
                        // Lowercased, as `LexiconBuilder.syllableBases` does.
                        // The syllabifier looks up lowercase candidates, so an
                        // uppercase-only base stored here — `Bei` from a
                        // capitalised reading — is one a later import using
                        // this inventory could never match.
                        bases.insert(syllable.base.lowercased())
                    }
                }
            }
        }
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM syllableBase")
            for base in bases.sorted() {
                try db.execute(sql: "INSERT INTO syllableBase (base) VALUES (?)", arguments: [base])
            }
        }
    }

    private func writeMetadata(_ metadata: DictionaryMetadata) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM meta")
        }
        try DictionaryContainer.writeMetadata(metadata, to: dbQueue)
    }

    // MARK: - Headword carry-over

    /// Tab-separated, because a headword cannot contain a tab and this is one
    /// field read by one function. JSON here would be a dependency on a
    /// decoder for a list that is empty 100% of the time on real input.
    private static func encodeHeadwords(_ headwords: [String]) -> String {
        headwords.joined(separator: "\t")
    }

    private static func decodeHeadwords(_ encoded: String) -> [String] {
        encoded.isEmpty ? [] : encoded.components(separatedBy: "\t")
    }
}
