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

    var bases: Set<String> {
        ["ai", "le", "liao", "yi", "da", "guo"]
    }

    /// Plants the job row an interruption would have left.
    ///
    /// Needed because a *completed* import clears the job, so a test that
    /// runs one to the end and then runs it again is testing a fresh import
    /// and nothing else — which is how three of these tests first passed
    /// against bugs they were written for.
    func plantJob(
        _ checkpoint: DictionaryWriter.Checkpoint,
        files: [String],
        bases: Set<String>? = nil,
    ) throws {
        let sources = try files.map {
            try DSLImporter.FileDescription(url: root.appendingPathComponent($0))
        }
        let (writer, _) = try DictionaryWriter.open(
            at: destination,
            source: DictionaryWriter.Source(
                name: files[0],
                fingerprint: DSLImporter.fingerprint(of: sources, bases: bases ?? self.bases),
                fileCount: files.count,
                totalBytes: sources.reduce(0) { $0 + $1.size },
                parserVersion: DSLImporter.parserVersion,
            ),
        )
        try writer.checkpoint(checkpoint)
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
            syllableBases: bases,
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

/// Runs an import and stops it at its first committed batch.
///
/// Deterministic, and it has to be. The progress callback signals the test
/// and then *blocks*, so the cancellation is in place before the importer can
/// take another step. Waiting for a progress value and then cancelling is not
/// enough on its own: the importer carries on in the meantime, and on a quiet
/// machine — or on CI — a twenty-card import finishes before an async test can
/// react at all, leaving nothing interrupted and nothing to resume. Three
/// tests here passed locally and failed on CI for exactly that reason.
///
/// Progress is reported on the first batch to commit, so afterwards exactly
/// one batch is in the container and the rest of the file is not.
@discardableResult
private func interruptAtFirstBatch(_ importer: DSLImporter) async -> Bool {
    let release = DispatchSemaphore(value: 0)
    let (reached, continuation) = AsyncStream<Void>.makeStream()
    let task = Task.detached {
        defer { continuation.finish() }
        return try importer.run { _ in
            continuation.yield()
            release.wait()
        }
    }
    var iterator = reached.makeAsyncIterator()
    let interrupted = await iterator.next() != nil
    task.cancel()
    release.signal()
    _ = try? await task.value
    return interrupted
}

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
                fingerprint: "anything",
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
        await interruptAtFirstBatch(importer)

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

    /// An end-of-file checkpoint stores byte offset zero to mean "from the
    /// beginning of the next file". Handing that straight back to the byte
    /// reader starts it *at* the byte-order mark, which then arrives as the
    /// first character of the first headword — so every multi-file resume at a
    /// file boundary corrupted one headword, silently.
    ///
    /// The job row is planted rather than reached by interrupting, because a
    /// batch big enough to span a volume reports no progress inside the card
    /// loop and a batch small enough to report never stops *on* the boundary.
    /// It is exactly the row a real interruption leaves.
    @Test("Resuming at a file boundary does not read the byte-order mark")
    func resumeAtFileBoundary() throws {
        let workspace = try Workspace()
        try workspace.write("a.dsl", header + "#INCLUDE \"b.dsl\"\n\n" + cards(5))
        try workspace.write("b.dsl", "#NAME \"B\"\n\n" + cards(5, from: 500))
        try workspace.plantJob(
            DictionaryWriter.Checkpoint(fileIndex: 1, byteOffset: 0),
            files: ["a.dsl", "b.dsl"],
        )

        let summary = try workspace.importer(from: "a.dsl").run()
        #expect(summary.resumed)

        let container = try DictionaryContainer(contentsOf: workspace.destination)
        // The headword that follows the mark, intact. Read as content, the
        // mark makes it "\u{FEFF}wdw" and nothing finds it again.
        #expect(try !container.entries(for: "w" + String(500, radix: 36)).isEmpty)
        for word in try container.headwords() {
            #expect(!word.hasPrefix("\u{FEFF}"), "\(word.debugDescription) kept a byte-order mark")
        }
    }

    /// A card whose headword is in one volume and whose article is in the next
    /// has no resume point in the file it was completed in. Clearing the
    /// carried headword before that card's batch commits leaves a checkpoint
    /// that restarts the next file without it, so the card's entries are
    /// deleted on resume and its article cannot rebuild them.
    ///
    /// Interrupted at exactly that card: the first volume holds nothing but
    /// the dangling headword, so the first batch to commit is the seam card's,
    /// and the first progress report is therefore the one that follows it.
    @Test("A seam card survives being the frontier of a checkpoint")
    func seamCardSurvivesResume() async throws {
        let seamFiles = { (workspace: borrowing Workspace) throws in
            try workspace.write("a.dsl", header + "#INCLUDE \"b.dsl\"\n\nwseam\n")
            try workspace.write(
                "b.dsl",
                "#NAME \"B\"\n\n ài\n [m1]разрезанное[/m]\n" + cards(4, from: 900),
            )
        }

        let reference = try Workspace()
        try seamFiles(reference)
        let expected = try reference.importer(from: "a.dsl", batchSize: 1).run()
        #expect(expected.cardsRead == 5)

        let workspace = try Workspace()
        try seamFiles(workspace)
        let importer = try workspace.importer(from: "a.dsl", batchSize: 1)
        await interruptAtFirstBatch(importer)

        let resumed = try workspace.importer(from: "a.dsl", batchSize: 1).run()
        #expect(resumed.resumed)
        #expect(resumed.cardsRead == expected.cardsRead)

        let seam = try DictionaryContainer(contentsOf: workspace.destination)
            .entries(for: "wseam")
        #expect(seam.count == 1, "the seam card was lost")
        #expect(seam.first?.senses.first?.gloss.text == "разрезанное")
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

/// What an import is allowed to resume onto.
///
/// A job is only continuable if everything the output depends on is unchanged
/// — every volume, and the syllable inventory the readings were split with.
/// Half a dictionary from each of two versions is worse than either, and
/// reports success.
@Suite("DSL import identity")
struct DSLImportIdentityTests {
    /// Checking only the first volume lets a changed third volume resume onto
    /// entries from the old one — a dictionary half from each version, and it
    /// reports success.
    @Test("A changed later volume starts the import again")
    func changedLaterVolumeRestarts() throws {
        let workspace = try Workspace()
        try workspace.write("a.dsl", header + "#INCLUDE \"b.dsl\"\n\n" + cards(5))
        try workspace.write("b.dsl", "#NAME \"B\"\n\n" + cards(5, from: 500))
        try workspace.plantJob(
            DictionaryWriter.Checkpoint(fileIndex: 1, byteOffset: 0, cardsRead: 5),
            files: ["a.dsl", "b.dsl"],
        )

        // The first volume is untouched; only the second changes.
        try workspace.write("b.dsl", "#NAME \"B\"\n\n" + cards(2, from: 500))
        let again = try workspace.importer(from: "a.dsl").run()
        #expect(!again.resumed)
        #expect(again.cardsRead == 7)
        #expect(again.entriesWritten == 7)
    }

    /// The syllable inventory decides how a reading is split and therefore
    /// what the cross-dictionary merge key is, so changing it between runs
    /// would leave readings parsed two ways in one container.
    @Test("Changed syllable bases start the import again")
    func changedBasesRestart() throws {
        let workspace = try Workspace()
        try workspace.write("a.dsl", header + cards(6))
        try workspace.plantJob(
            DictionaryWriter.Checkpoint(fileIndex: 0, byteOffset: 200, cardsRead: 2),
            files: ["a.dsl"],
            bases: ["ai"],
        )

        let again = try DSLImporter(
            fileSet: DSLFileSet.discover(from: workspace.root.appendingPathComponent("a.dsl")),
            destination: workspace.destination,
            syllableBases: ["ai", "guo"],
        ).run()
        #expect(!again.resumed)
        #expect(again.cardsRead == 6)
    }

    /// The same job with the same inputs *does* resume, so the checks above
    /// are not passing because nothing ever resumes.
    @Test("An unchanged source resumes")
    func unchangedSourceResumes() throws {
        let workspace = try Workspace()
        try workspace.write("a.dsl", header + cards(6))
        try workspace.plantJob(
            DictionaryWriter.Checkpoint(fileIndex: 0, byteOffset: 0, cardsRead: 0),
            files: ["a.dsl"],
        )
        #expect(try workspace.importer(from: "a.dsl").run().resumed)
    }

    /// A volume an `#INCLUDE` names but that is not there means a dictionary
    /// missing part of itself, which is the failure a reader would never
    /// notice on their own.
    @Test("A missing volume is reported, not finished over")
    func missingVolumeReported() throws {
        let workspace = try Workspace()
        try workspace.write("a.dsl", header + "#INCLUDE \"gone.dsl\"\n\n" + cards(4))

        let summary = try workspace.importer(from: "a.dsl").run()
        #expect(summary.entriesWritten == 4)
        #expect(summary.diagnostics == 0)
        #expect(summary.discovery.map(\.kind) == [.missingInclude("gone.dsl")])
        #expect(summary.totalDiagnostics == 1)
    }

    /// A card counted on both sides of an interruption is counted twice, and
    /// so are its diagnostics. Reader diagnostics have the opposite problem:
    /// added only at end of file, a resume seeking past them loses them.
    @Test("Diagnostic counts survive an interruption")
    func diagnosticCountsSurviveResume() async throws {
        // `[zzz]` is one lexer diagnostic per card; the dangling headword at
        // the end is one from the reader.
        let body = (0 ..< 20).map { "wz\($0)\n ài\n [m1][zzz]текст[/m]\n" }.joined()
        let make = { (workspace: borrowing Workspace) throws in
            _ = try workspace.write("a.dsl", header + body + "wdangling\n")
        }

        let reference = try Workspace()
        try make(reference)
        let expected = try reference.importer(from: "a.dsl", batchSize: 1).run()
        #expect(expected.diagnostics == 21)

        let workspace = try Workspace()
        try make(workspace)
        let importer = try workspace.importer(from: "a.dsl", batchSize: 1)
        await interruptAtFirstBatch(importer)

        let resumed = try workspace.importer(from: "a.dsl", batchSize: 1).run()
        #expect(resumed.resumed)
        #expect(resumed.cardsRead == expected.cardsRead)
        #expect(resumed.diagnostics == expected.diagnostics)
    }

    /// The other half: a reader diagnostic that happens *before* a checkpoint
    /// has to be in that checkpoint. Added only at end of file, it is lost
    /// whenever a resume seeks past the lines that caused it — and the
    /// end-of-file catch-up hides the fault in any run that reaches the end,
    /// which is why this case needs an interruption to show at all.
    @Test("A diagnostic before the checkpoint is carried across a resume")
    func readerDiagnosticsBeforeCheckpoint() async throws {
        // An article line with no headword above it, before any card.
        let make = { (workspace: borrowing Workspace) throws in
            _ = try workspace.write("a.dsl", header + " [m1]сирота[/m]\n" + cards(20))
        }

        let reference = try Workspace()
        try make(reference)
        let expected = try reference.importer(from: "a.dsl", batchSize: 1).run()
        #expect(expected.diagnostics == 1)

        let workspace = try Workspace()
        try make(workspace)
        let importer = try workspace.importer(from: "a.dsl", batchSize: 1)
        await interruptAtFirstBatch(importer)

        let partial = try DictionaryContainer(contentsOf: workspace.destination).entryCount()
        let resumed = try workspace.importer(from: "a.dsl", batchSize: 1).run()
        #expect(resumed.resumed)
        #expect(
            resumed.diagnostics == expected.diagnostics,
            "resumed \(resumed.diagnostics), reference \(expected.diagnostics), partial \(partial)",
        )
    }
}
