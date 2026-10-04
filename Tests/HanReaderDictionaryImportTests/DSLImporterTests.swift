// HanReader — MIT licensed. See LICENSE.

import Foundation
import HanReaderCore
import HanReaderPersistence
import Testing
@testable import HanReaderDictionaryImport

// MARK: - Fixtures

/// A throwaway directory holding a DSL set and the container built from it.
private struct Workspace: ~Copyable {
    let root: URL

    init() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("hanreader-import-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    var destination: URL {
        root.appendingPathComponent("out.hanreaderdict")
    }

    /// Writes a DSL file as the real ones are written: UTF-16LE with a BOM.
    @discardableResult
    func write(_ name: String, _ text: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        var bytes: [UInt8] = [0xFF, 0xFE]
        for unit in Array(text.utf16) {
            bytes += [UInt8(unit & 0xFF), UInt8(unit >> 8)]
        }
        try Data(bytes).write(to: url)
        return url
    }

    func importer(
        from name: String,
        batchSize: Int = DSLImporter.defaultBatchSize,
    ) throws
        -> DSLImporter
    {
        try DSLImporter(
            fileSet: DSLFileSet.discover(from: root.appendingPathComponent(name)),
            destination: destination,
            syllableBases: ["ai", "le", "liao", "yi", "da", "guo"],
            batchSize: batchSize,
        )
    }
}

/// A card run long enough to span several batches.
private func cards(_ count: Int, from offset: Int = 0) -> String {
    (0 ..< count).map { index in
        let word = String(index + offset, radix: 36)
        return "w\(word)\n ài\n [m1]значение \(index)[/m][m2]второе[/m]\n"
    }.joined()
}

private let header = """
#NAME "大БКРС - 250920 ( 1 / 3 )"\r
#INDEX_LANGUAGE "Chinese"
#CONTENTS_LANGUAGE "Russian"

"""

@Suite("DSL importer")
struct DSLImporterTests {
    // MARK: - A plain import

    @Test("A set becomes a container")
    func wholeImport() throws {
        let workspace = try Workspace()
        try workspace.write("a.dsl", header + cards(40))

        let summary = try workspace.importer(from: "a.dsl").run()
        #expect(summary.cardsRead == 40)
        #expect(summary.entriesWritten == 40)
        #expect(summary.diagnostics == 0)
        #expect(!summary.resumed)

        let container = try DictionaryContainer(contentsOf: workspace.destination)
        #expect(try container.entryCount() == 40)
        let entries = try container.entries(for: "w0")
        #expect(entries.count == 1)
        #expect(entries[0].senses.count == 2)
        #expect(entries[0].senses[0].gloss.text == "значение 0")
    }

    /// The job row is cleared on success, so a finished container does not
    /// look like one that was interrupted.
    @Test("A finished import leaves no job behind")
    func noJobAfterFinishing() throws {
        let workspace = try Workspace()
        try workspace.write("a.dsl", header + cards(10))
        try workspace.importer(from: "a.dsl").run()

        // Opening for writing again finds nothing to resume, which is what
        // makes the second run a fresh import rather than a continuation.
        let reopened = try DictionaryWriter.open(
            at: workspace.destination,
            source: DictionaryWriter.Source(
                name: "a.dsl",
                size: 1,
                modified: .now,
                fileCount: 1,
                totalBytes: 1,
                parserVersion: DSLImporter.parserVersion,
            ),
        )
        #expect(reopened.resume == nil)
    }

    @Test("Several files are imported in order")
    func severalFiles() throws {
        let workspace = try Workspace()
        try workspace.write("a.dsl", header + "#INCLUDE \"b.dsl\"\n\n" + cards(5))
        try workspace.write("b.dsl", "#NAME \"B\"\n\n" + cards(5, from: 100))

        let summary = try workspace.importer(from: "a.dsl").run()
        #expect(summary.cardsRead == 10)
        let container = try DictionaryContainer(contentsOf: workspace.destination)
        #expect(try container.entryCount() == 10)
    }

    // MARK: - Resuming

    /// The gate this exists for. Interrupting leaves the same state a
    /// `kill -9` leaves — everything up to the last committed batch — and the
    /// resumed result has to equal the uninterrupted one exactly.
    ///
    /// Interrupted deterministically rather than after a sleep. Progress is
    /// reported once the first batch commits and then at most ten times a
    /// second, so cancelling on the first report stops the import after
    /// exactly one batch however fast the machine is. A sleep raced: on a
    /// quiet machine the whole 400-card import finished inside 40 ms.
    @Test("An interrupted import resumes to the same result")
    func resumeMatchesUninterrupted() async throws {
        let reference = try Workspace()
        try reference.write("a.dsl", header + cards(400))
        let expected = try reference.importer(from: "a.dsl", batchSize: 25).run()

        let interrupted = try Workspace()
        try interrupted.write("a.dsl", header + cards(400))
        let importer = try interrupted.importer(from: "a.dsl", batchSize: 25)

        // The first progress value means the first batch has committed, so
        // waiting for it and then cancelling interrupts the import at a batch
        // boundary with work done and work left — no sleep, no race.
        let (reports, continuation) = AsyncStream<Int>.makeStream()
        let task = Task.detached {
            defer { continuation.finish() }
            return try importer.run { continuation.yield($0.entriesWritten) }
        }
        var iterator = reports.makeAsyncIterator()
        _ = await iterator.next()
        task.cancel()
        _ = try? await task.value

        let partial = try DictionaryContainer(contentsOf: interrupted.destination).entryCount()
        #expect(partial > 0, "nothing was committed before the interruption")
        #expect(partial < 400, "the import was not actually interrupted")
        // A whole number of batches, because a batch and its checkpoint are
        // one transaction: a half-written batch cannot survive.
        #expect(partial.isMultiple(of: 25))

        let resumed = try interrupted.importer(from: "a.dsl", batchSize: 25).run()
        #expect(resumed.resumed)
        #expect(resumed.entriesWritten == expected.entriesWritten)
        #expect(resumed.cardsRead == expected.cardsRead)

        // Not just the counts: the same rows, and the same senses in them.
        let left = try DictionaryContainer(contentsOf: reference.destination)
        let right = try DictionaryContainer(contentsOf: interrupted.destination)
        #expect(try left.entryCount() == right.entryCount())
        #expect(try left.sourceOffsets() == right.sourceOffsets())
        for word in ["w0", "wa", "wrr", "wb3"] {
            let before = try left.entries(for: word).map(\.senses)
            let after = try right.entries(for: word).map(\.senses)
            #expect(before == after, "\(word) differs")
        }
    }

    /// Stamping a whole batch with the offset of the card that filled it is
    /// what made a resume lose entries: the delete removed the batch and the
    /// re-read replaced only its last card. Over four interruptions of a
    /// 574,709-entry import, 14,997 entries vanished and it reported success.
    @Test("Each entry records its own card's offset")
    func perEntryOffsets() throws {
        let workspace = try Workspace()
        try workspace.write("a.dsl", header + cards(30))
        try workspace.importer(from: "a.dsl", batchSize: 10).run()

        let container = try DictionaryContainer(contentsOf: workspace.destination)
        let offsets = try container.sourceOffsets()
        #expect(offsets.count == 30)
        // Distinct and increasing: one per card, not one per batch.
        #expect(Set(offsets).count == 30)
        #expect(offsets == offsets.sorted())
    }

    /// A different file, or a different parser, cannot be stitched onto what
    /// is already there — no schema migration repairs output from two
    /// parsers, and half a dictionary from each is worse than either.
    @Test("A changed source starts the import again")
    func changedSourceRestarts() throws {
        let workspace = try Workspace()
        try workspace.write("a.dsl", header + cards(20))
        try workspace.importer(from: "a.dsl", batchSize: 5).run()

        // Same name, different content, so size and modification time differ.
        try workspace.write("a.dsl", header + cards(7))
        let again = try workspace.importer(from: "a.dsl", batchSize: 5).run()
        #expect(!again.resumed)
        #expect(again.entriesWritten == 7)
        #expect(try DictionaryContainer(contentsOf: workspace.destination).entryCount() == 7)
    }

    // MARK: - Progress

    @Test("Progress is throttled and ends at the end")
    func progress() throws {
        let workspace = try Workspace()
        try workspace.write("a.dsl", header + cards(600))

        nonisolated(unsafe) var values: [DSLImportProgress] = []
        try workspace.importer(from: "a.dsl", batchSize: 5).run { values.append($0) }

        // 120 batches, but never more than ten reports a second.
        #expect(values.count < 120)
        #expect(values.last?.fraction == 1)
        #expect(values.last?.bytesRead == values.last?.totalBytes)
        #expect(values.map(\.cardsRead) == values.map(\.cardsRead).sorted())
    }

    // MARK: - Metadata

    /// Nothing is hardcoded: the predecessor took the dictionary's name from a
    /// constant in its source, so importing any other DSL dictionary
    /// mislabelled it.
    @Test("Metadata comes out of the file")
    func metadata() throws {
        let workspace = try Workspace()
        try workspace.write("a.dsl", header + cards(3))
        let summary = try workspace.importer(from: "a.dsl").run()

        #expect(summary.metadata.displayName == "大БКРС - 250920")
        #expect(summary.metadata.slug == "dabkrs-250920")
        #expect(summary.metadata.format == "abbyy-dsl")
        #expect(summary.metadata.indexLanguage == "zh-Hans")
        #expect(summary.metadata.glossLanguage == "ru")
        #expect(summary.metadata.sourceVersion == "250920")
        #expect(summary.metadata.entryCount == 3)
    }

    /// The volume count belongs to the file, not to the dictionary — the three
    /// volumes compile into one container.
    @Test("The volume suffix is stripped from the name", arguments: [
        ("大БКРС - 250920 ( 1 / 3 )", "大БКРС - 250920"),
        ("Example (2/2)", "Example"),
        ("Example (revised)", "Example (revised)"),
        ("Example", "Example"),
    ])
    func volumeSuffix(declared: String, expected: String) {
        #expect(DSLImporter.volumeSuffix(strippedFrom: declared) == expected)
    }

    /// BKRS states no licence, and inventing one would be worse than
    /// admitting it: the Acknowledgements screen renders this verbatim.
    @Test("No licence is claimed for a source that states none")
    func noLicenceClaimed() throws {
        let workspace = try Workspace()
        try workspace.write("a.dsl", header + cards(1))
        let summary = try workspace.importer(from: "a.dsl").run()
        #expect(summary.metadata.licence == "Not stated by the source")
        #expect(summary.metadata.attribution.contains("does not"))
        #expect(summary.metadata.attribution.contains("Changes made:"))
    }

    @Test("A language the format does not name is kept verbatim")
    func unknownLanguage() {
        #expect(DSLImporter.languageTag("Chinese") == "zh-Hans")
        #expect(DSLImporter.languageTag("Russian") == "ru")
        #expect(DSLImporter.languageTag("Klingon") == "Klingon")
        #expect(DSLImporter.languageTag(nil) == nil)
    }

    /// A slug has to work as a file name and a settings key, and `大БКРС`
    /// has nothing ASCII in it at all. Transliterating rather than stripping
    /// is what gives it one.
    @Test("A name is transliterated into its slug", arguments: [
        ("大БКРС - 250920", "dabkrs-250920"),
        ("大辞典", "da-ci-dian"),
        ("Example Dictionary", "example-dictionary"),
    ])
    func slugFromName(declared: String, expected: String) {
        #expect(DSLImporter.slug(from: declared, fallback: "ignored.dsl") == expected)
    }

    @Test("A name with nothing transliterable falls back to the file name")
    func slugFallback() {
        #expect(DSLImporter.slug(from: "", fallback: "my_dict.dsl") == "my-dict")
        #expect(DSLImporter.slug(from: "—", fallback: "vol_1.dsl") == "vol-1")
    }
}
