// HanReader — MIT licensed. See LICENSE.

public import Foundation
public import HanReaderCore
import HanReaderPersistence

/// How far an import has got.
public struct DSLImportProgress: Hashable, Sendable {
    public let fileIndex: Int
    public let fileCount: Int
    public let bytesRead: Int
    public let totalBytes: Int
    public let cardsRead: Int
    public let entriesWritten: Int

    /// 0 to 1 across the whole set, not the current file — a reader watching
    /// a three-volume import does not want the bar to reach the end and start
    /// again twice.
    public var fraction: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1, Double(bytesRead) / Double(totalBytes))
    }
}

/// What an import produced.
public struct DSLImportSummary: Hashable, Sendable {
    public let cardsRead: Int
    public let entriesWritten: Int
    /// Problems inside the files — unknown markup, an article with no
    /// headword.
    public let diagnostics: Int
    /// Problems with the *set*: a volume an `#INCLUDE` names but that is not
    /// there, or a set longer than discovery will follow. Separate from the
    /// count above, because a reader has to be told about these whatever the
    /// import otherwise achieved — a dictionary quietly missing a third of
    /// itself is the failure they would never notice.
    public let discovery: [DSLDiagnostic]
    public let resumed: Bool
    public let metadata: DictionaryMetadata

    /// Everything that went wrong, as one headline number.
    public var totalDiagnostics: Int {
        diagnostics + discovery.count
    }
}

/// Imports an ABBYY DSL dictionary into a container.
///
/// The pieces it drives all live in `HanReaderCore` and are tested there:
/// `DSLFileSet` finds the volumes, `DSLCardReader` turns bytes into cards, and
/// `DSLCardBuilder` turns a card into entries. This owns only the I/O around
/// them — batching, checkpointing, throttled progress and cancellation —
/// which is the part that cannot be a pure function.
///
/// ### Memory is bounded by the batch, not by the dictionary
///
/// 3,442,623 entries over 3,691,468 senses do not fit in the 60 MB the import
/// is allowed. Nothing is accumulated: cards stream in, a batch of entries is
/// written, and the batch is released. Measured peak over the real 350 MB set
/// is a few tens of megabytes, almost all of it SQLite's page cache.
///
/// ### Progress is throttled, because the alternative was measurable
///
/// The predecessor fired its progress handler every 128 KB and hopped to the
/// main actor each time — about 2,700 hops for this set, every one of them
/// contending with the thread doing CJK layout. Here progress is reported at
/// most ten times a second, and always once at the end so a bar cannot stop
/// short of full.
public struct DSLImporter: Sendable {
    /// Bumped when a parser change alters what gets written.
    ///
    /// A container built by an older parser is rebuilt rather than migrated,
    /// because no schema migration can repair data that was parsed wrongly.
    public static let parserVersion = 1

    /// Entries per transaction. A row at a time takes minutes; batched it
    /// takes seconds, and 5,000 entries is a few megabytes.
    public static let defaultBatchSize = 5000

    /// Ten a second. Any faster is invisible to a reader and costs the
    /// importer an actor hop.
    static let progressInterval: TimeInterval = 0.1

    private let fileSet: DSLFileSet
    private let destination: URL
    private let syllableBases: Set<String>
    private let batchSize: Int

    /// - Parameters:
    ///   - fileSet: the volumes to read, from `DSLFileSet.discover(from:)`.
    ///   - destination: the container to write, created or resumed.
    ///   - syllableBases: toneless syllables for splitting a run-together
    ///     reading such as `tǔ'ěrqísītǎn`. These come from CC-CEDICT, which is
    ///     the phonetic backbone for both language modes; without them a
    ///     reading still displays exactly as the dictionary wrote it, and only
    ///     the cross-dictionary merge key is lost.
    public init(
        fileSet: DSLFileSet,
        destination: URL,
        syllableBases: Set<String>,
        batchSize: Int = Self.defaultBatchSize,
    ) {
        self.fileSet = fileSet
        self.destination = destination
        self.syllableBases = syllableBases
        self.batchSize = max(1, batchSize)
    }

    // MARK: - Running

    /// Runs the import to completion, resuming an interrupted one.
    ///
    /// Throws `CancellationError` if the task is cancelled, having committed
    /// everything up to the last batch — which is the same state a `kill -9`
    /// leaves, and resumes the same way.
    @discardableResult
    public func run(
        progress report: (@Sendable (DSLImportProgress) -> Void)? = nil,
    ) throws
        -> DSLImportSummary
    {
        let sources = try fileSet.files.map { try FileDescription(url: $0) }
        guard let first = sources.first else {
            throw DSLImportError.noFiles
        }
        let totalBytes = sources.reduce(0) { $0 + $1.size }

        let (writer, resume) = try DictionaryWriter.open(
            at: destination,
            source: DictionaryWriter.Source(
                name: first.name,
                fingerprint: Self.fingerprint(of: sources, bases: syllableBases),
                fileCount: sources.count,
                totalBytes: totalBytes,
                parserVersion: Self.parserVersion,
            ),
            // A dictionary whose headwords run to phrases must not supply the
            // segmentation lexicon as if they were words: at the general cap
            // of six, BKRS contributes 2,804,554 lexemes and almost every run
            // of Han characters becomes a word to match towards.
            lexiconMaximumLength: LexiconBuilder.encyclopaedicWordLength,
        )

        let run = Run(
            sources: sources,
            resume: resume,
            writer: writer,
            builder: DSLCardBuilder(syllableBases: syllableBases),
            batchSize: batchSize,
            report: report,
        )
        for index in run.state.checkpoint.fileIndex ..< sources.count {
            try run.importFile(at: index)
        }

        let metadata = Self.metadata(
            for: fileSet,
            entryCount: writer.count,
            fileName: first.name,
        )
        try writer.finish(metadata: metadata)
        report?(run.state.progress(written: writer.count, completed: true))

        return DSLImportSummary(
            cardsRead: run.state.checkpoint.cardsRead,
            entriesWritten: writer.count,
            diagnostics: run.state.checkpoint.diagnostics,
            // Discovery's own complaints are not in the checkpoint, because
            // they are not something a resume re-reads. Reported here so a
            // dictionary missing a volume cannot look finished.
            discovery: fileSet.diagnostics,
            resumed: resume != nil,
            metadata: metadata,
        )
    }

    /// The same import as a stream of progress values, for a view to observe.
    ///
    /// Runs on a detached task so the caller's actor is never the one doing
    /// the parsing, and finishes by throwing whatever the import threw.
    public func events() -> AsyncThrowingStream<DSLImportProgress, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task.detached(priority: .utility) {
                do {
                    try run { continuation.yield($0) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

// MARK: - One file at a time

extension DSLImporter {
    /// Everything the output depends on, as one comparable string.
    ///
    /// Spelled out rather than hashed, for two reasons. `Hasher` is seeded per
    /// process, so `hashValue` is not comparable across runs at all — the bug
    /// would be invisible and intermittent. And at a couple of kilobytes for a
    /// three-volume set this costs one row, where a mismatch that wrongly
    /// restarts a 200-second import costs rather more.
    ///
    /// Every volume, not just the one the reader picked: a changed third
    /// volume with an unchanged first one would otherwise resume onto entries
    /// from the old version. And the syllable inventory, because it decides
    /// how a reading is split and so what the cross-dictionary merge key is —
    /// re-running with a different `--bases` would mix readings parsed two
    /// ways.
    static func fingerprint(of sources: [FileDescription], bases: Set<String>) -> String {
        let files = sources.map {
            "\($0.name):\($0.size):\(Int($0.modified.timeIntervalSince1970))"
        }
        return (files + ["bases"] + bases.sorted()).joined(separator: "|")
    }
}

extension DSLImporter {
    /// The mutable half of a run.
    ///
    /// A single object rather than a handful of `inout` parameters threaded
    /// through a function, so the checkpoint cannot drift out of step with the
    /// batch it describes — they are only ever advanced together, here.
    final class Run {
        let sources: [FileDescription]
        let resume: DictionaryWriter.Checkpoint?
        let writer: DictionaryWriter
        let builder: DSLCardBuilder
        let batchSize: Int
        let report: (@Sendable (DSLImportProgress) -> Void)?

        var state: Checkpointing
        var batch: [DictionaryWriter.SourcedEntry] = []
        var lastReport = Date.distantPast

        init(
            sources: [FileDescription],
            resume: DictionaryWriter.Checkpoint?,
            writer: DictionaryWriter,
            builder: DSLCardBuilder,
            batchSize: Int,
            report: (@Sendable (DSLImportProgress) -> Void)?,
        ) {
            self.sources = sources
            self.resume = resume
            self.writer = writer
            self.builder = builder
            self.batchSize = batchSize
            self.report = report
            state = Checkpointing(
                checkpoint: resume ?? DictionaryWriter.Checkpoint(),
                sources: sources,
                totalBytes: sources.reduce(0) { $0 + $1.size },
            )
            batch.reserveCapacity(batchSize)
        }

        /// Commits the pending batch, checkpointed at the card that filled
        /// it.
        ///
        /// The checkpoint is that card's own offset, so it is re-read on
        /// resume rather than skipped: it is already in the batch being
        /// committed, and the resume path deletes everything at or past the
        /// offset first.
        ///
        /// A card with no offset was assembled across a file seam, and the
        /// only point that restarts it is in the *previous* file. Leaving the
        /// checkpoint where it is re-reads from there, which rebuilds the seam
        /// correctly; moving it here would resume past the carried headword
        /// and lose the card. The carried headwords stay for the same reason —
        /// cleared before this commit, a checkpoint whose frontier is still
        /// the seam card restarts the next file without that headword, so the
        /// card's entries are deleted and its article cannot rebuild them.
        private func commitBatch(
            frontier: DSLCardRecord,
            settled: (cards: Int, diagnostics: Int),
        ) throws {
            var commit = state.checkpoint
            commit.cardsRead = settled.cards
            commit.diagnostics = settled.diagnostics
            if let offset = frontier.offset {
                state.checkpoint.byteOffset = offset
                state.checkpoint.leadingHeadwords = []
                commit.byteOffset = offset
                commit.leadingHeadwords = []
            }
            try writer.append(batch, checkpoint: commit)
            batch.removeAll(keepingCapacity: true)
            lastReport = state.reportIfDue(
                after: lastReport,
                written: writer.count,
                to: report,
            )
        }

        /// Reads one file of the set, committing a batch whenever one fills.
        func importFile(at index: Int) throws {
            // Only the file the checkpoint names starts part way in, and only
            // when it names a real card offset. Zero is not one: it is where
            // the byte-order mark is, and handing it back as a resume point
            // reads the mark as the first character of the first headword. An
            // end-of-file checkpoint stores zero precisely to mean "from the
            // beginning", which is what nil says to the reader.
            let storedOffset = index == resume?.fileIndex ? (resume?.byteOffset ?? 0) : 0
            var reader = try DSLCardReader(
                source: DSLFileBytes(url: sources[index].url),
                resumingAt: storedOffset > 0 ? storedOffset : nil,
                leadingHeadwords: index == state.checkpoint.fileIndex
                    ? state.checkpoint.leadingHeadwords
                    : [],
            )
            state.checkpoint.fileIndex = index
            var readerDiagnostics = 0

            while let record = try reader.next() {
                try Task.checkCancellation()
                // The reader's own complaints are counted first, and they
                // count as *settled*. They describe lines the reader has
                // already gone past — an article with no headword above it
                // sits before the card that follows it — so a resume starting
                // at that card will never see them again, and leaving them out
                // of its checkpoint loses them for good. Taken per card rather
                // than at end of file for the same reason.
                state.checkpoint.diagnostics += reader.diagnostics.count - readerDiagnostics
                readerDiagnostics = reader.diagnostics.count

                // This card's own totals are not settled, because a resume
                // re-reads it: counting it on both sides inflates the totals
                // by one card and its diagnostics per interruption.
                let settled = (
                    cards: state.checkpoint.cardsRead,
                    diagnostics: state.checkpoint.diagnostics,
                )
                state.checkpoint.cardsRead += 1
                let built = builder.entries(from: record.card)
                state.checkpoint.diagnostics += built.diagnostics.count
                // Each entry carries its own card's offset. A card assembled
                // across a file seam has none of its own, and its entries take
                // the checkpoint's — which still points into the previous
                // file, so a resume from there deletes and rebuilds them.
                batch.append(contentsOf: built.entries.map {
                    DictionaryWriter.SourcedEntry(
                        entry: $0,
                        sourceFile: index,
                        sourceOffset: record.offset ?? 0,
                    )
                })

                guard batch.count >= batchSize else { continue }
                try commitBatch(frontier: record, settled: settled)
            }

            // End of file: the next card is in the next file, so the
            // checkpoint moves past this one in the same commit as its last
            // batch.
            state.checkpoint.diagnostics += reader.diagnostics.count - readerDiagnostics
            state.checkpoint.fileIndex = index + 1
            state.checkpoint.byteOffset = 0
            state.checkpoint.leadingHeadwords = reader.trailingHeadwords
            if batch.isEmpty {
                try writer.checkpoint(state.checkpoint)
            } else {
                try writer.append(batch, checkpoint: state.checkpoint)
                batch.removeAll(keepingCapacity: true)
            }
        }
    }
}

// MARK: - Progress bookkeeping

extension DSLImporter {
    /// One source file, measured once.
    struct FileDescription: Sendable {
        let url: URL
        let name: String
        let size: Int
        let modified: Date

        init(url: URL) throws {
            self.url = url
            name = url.lastPathComponent
            let values = try url.resourceValues(forKeys: [
                .fileSizeKey,
                .contentModificationDateKey,
            ])
            size = values.fileSize ?? 0
            modified = values.contentModificationDate ?? .distantPast
        }
    }

    /// The mutable half of a run, kept together so `run` reads as a loop over
    /// cards rather than as bookkeeping with a loop in it.
    struct Checkpointing {
        var checkpoint: DictionaryWriter.Checkpoint
        let sources: [FileDescription]
        let totalBytes: Int

        /// Bytes finished, counting whole files before the current one.
        var bytesRead: Int {
            let whole = sources.prefix(checkpoint.fileIndex).reduce(0) { $0 + $1.size }
            return min(totalBytes, whole + checkpoint.byteOffset)
        }

        func progress(written: Int, completed: Bool = false) -> DSLImportProgress {
            DSLImportProgress(
                fileIndex: min(checkpoint.fileIndex, max(0, sources.count - 1)),
                fileCount: sources.count,
                bytesRead: completed ? totalBytes : bytesRead,
                totalBytes: totalBytes,
                cardsRead: checkpoint.cardsRead,
                entriesWritten: written,
            )
        }

        /// Reports at most ten times a second, returning when it last did.
        func reportIfDue(
            after last: Date,
            written: Int,
            to report: (@Sendable (DSLImportProgress) -> Void)?,
        )
            -> Date
        {
            guard let report else { return last }
            let now = Date()
            guard now.timeIntervalSince(last) >= DSLImporter.progressInterval else { return last }
            report(progress(written: written))
            return now
        }
    }
}

// MARK: - Metadata

/// Something that stops an import before it starts.
public enum DSLImportError: Error, Hashable, Sendable, CustomStringConvertible {
    case noFiles

    public var description: String {
        switch self {
        case .noFiles: "the dictionary has no files to read"
        }
    }
}

extension DSLImporter {
    /// Builds the container's metadata from what the file says about itself.
    ///
    /// Nothing here is hardcoded. The predecessor took the dictionary's name
    /// from a constant in its source, so importing any other DSL dictionary
    /// mislabelled it.
    ///
    /// **No licence is claimed.** 大БКРС states no terms, and inventing one
    /// would be worse than admitting it: the Acknowledgements screen renders
    /// this verbatim, so whatever goes here is what the reader is told. The
    /// honest statement is that the file came from them, HanReader does not
    /// redistribute it, and its terms are the source dictionary's own.
    static func metadata(
        for fileSet: DSLFileSet,
        entryCount: Int,
        fileName: String,
    )
        -> DictionaryMetadata
    {
        let declared = fileSet.header.name?.trimmingCharacters(in: .whitespaces) ?? ""
        let name = volumeSuffix(strippedFrom: declared)
        let display = name.isEmpty ? fileName : name
        return DictionaryMetadata(
            slug: slug(from: display, fallback: fileName),
            displayName: display,
            format: "abbyy-dsl",
            indexLanguage: languageTag(fileSet.header.indexLanguage) ?? "zh-Hans",
            glossLanguage: languageTag(fileSet.header.contentsLanguage) ?? "und",
            licence: "Not stated by the source",
            attribution: """
            \(display) — imported from a copy supplied by the reader. HanReader \
            ships an importer, not this dictionary's data, and does not \
            redistribute it. Its terms are whatever the source dictionary \
            states. Changes made: parsed from the distributed DSL format into a \
            SQLite database for lookup; sense structure, usage examples and \
            grammatical labels were read from the markup, and a per-character \
            reading table and segmentation word list derived from the headword \
            set. No entry content was altered, removed, or added.
            """,
            sourceVersion: version(in: declared),
            parserVersion: Self.parserVersion,
            entryCount: entryCount,
        )
    }

    /// `大БКРС - 250920 ( 1 / 3 )` → `大БКРС - 250920`.
    ///
    /// The volume count belongs to the file, not to the dictionary, and the
    /// three volumes compile into one container.
    static func volumeSuffix(strippedFrom name: String) -> String {
        guard let open = name.lastIndex(of: "("), name.hasSuffix(")") else { return name }
        let inside = name[name.index(after: open) ..< name.index(before: name.endIndex)]
        guard inside.contains("/"),
              inside.allSatisfy({ $0.isNumber || $0.isWhitespace || $0 == "/" })
        else { return name }
        return String(name[name.startIndex ..< open]).trimmingCharacters(
            in: .whitespaces.union(CharacterSet(charactersIn: "-–—")),
        )
    }

    /// The date-like run in a declared name, as a version.
    static func version(in name: String) -> String? {
        let runs = name.split(whereSeparator: { !$0.isNumber })
        return runs.first { $0.count >= 6 }.map(String.init)
    }

    /// A stable identifier: lowercase, ASCII-safe, hyphen-separated.
    ///
    /// Transliterated rather than stripped, which is why `大БКРС - 250920`
    /// becomes `dabkrs-250920` and a wholly Han name like `大辞典` becomes
    /// `da-ci-dian` instead of nothing. The file name is the fallback for a
    /// declared name with nothing transliterable in it at all, because a slug
    /// has to work as a file name and as a settings key.
    static func slug(from name: String, fallback: String) -> String {
        let folded = name.lowercased()
            .applyingTransform(.toLatin, reverse: false)?
            .applyingTransform(.stripDiacritics, reverse: false) ?? name.lowercased()
        let parts = folded.split { !$0.isASCII || !($0.isLetter || $0.isNumber) }
        let slug = parts.joined(separator: "-")
        guard slug.count >= 3 else {
            let stem = fallback.split(separator: ".").first.map(String.init) ?? fallback
            // Through the same splitter, so the two paths cannot disagree
            // about what a slug looks like.
            return stem.lowercased()
                .split { !$0.isASCII || !($0.isLetter || $0.isNumber) }
                .joined(separator: "-")
        }
        return slug
    }

    /// Maps a DSL language name to a BCP-47 tag.
    ///
    /// Only the names this format actually writes, and anything else is kept
    /// verbatim rather than guessed at: an unrecognised language should be
    /// reported as the dictionary stated it, not relabelled as one we know.
    static func languageTag(_ declared: String?) -> String? {
        guard let declared, !declared.isEmpty else { return nil }
        switch declared.lowercased() {
        case "chinese", "chinesesimplified", "chinese simplified": return "zh-Hans"
        case "chinesetraditional", "chinese traditional": return "zh-Hant"
        case "russian": return "ru"
        case "english": return "en"
        default: return declared
        }
    }
}
