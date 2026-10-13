// HanReader — MIT licensed. See LICENSE.

import Foundation
import HanReaderCore
import Testing
@testable import HanReaderPersistence

// MARK: - Fixtures

private func entry(
    _ simplified: String,
    traditional: String? = nil,
    reading: String = "ai4",
    senses: [String] = ["значение"],
)
    -> DictionaryEntry
{
    DictionaryEntry(
        headword: Headword(simplified: simplified, traditional: traditional),
        reading: Pinyin.parse(numeric: reading),
        senses: senses.enumerated().map { index, text in
            Sense(
                id: index,
                kind: .definition,
                gloss: Gloss(text: text, references: [], styles: []),
                level: 0,
                parent: nil,
                label: nil,
                partOfSpeech: [],
                registers: [],
                examples: [],
            )
        },
    )
}

private func metadata(entryCount: Int) -> DictionaryMetadata {
    DictionaryMetadata(
        slug: "test",
        displayName: "Test",
        format: "abbyy-dsl",
        indexLanguage: "zh-Hans",
        glossLanguage: "ru",
        licence: "none",
        attribution: "none",
        parserVersion: 1,
        entryCount: entryCount,
    )
}

private func temporaryURL() -> URL {
    URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("hanreader-storage-\(UUID().uuidString)")
        .appendingPathComponent("out.hanreaderdict")
}

private func source(fingerprint: String = "f") -> DictionaryWriter.Source {
    DictionaryWriter.Source(
        name: "a.dsl",
        fingerprint: fingerprint,
        fileCount: 1,
        totalBytes: 1000,
        parserVersion: 1,
    )
}

@Suite("Dictionary storage")
struct DictionaryStorageTests {
    /// Whatever the indexing strategy, a finished container has to answer a
    /// lookup — the whole point of building the indexes at the end is that it
    /// is invisible from the outside.
    @Test("A finished container looks words up", arguments: [
        DictionaryWriter.Indexing.atTheEnd,
        DictionaryWriter.Indexing.whileWriting,
    ])
    func lookupAfterEitherIndexing(indexing: DictionaryWriter.Indexing) throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let (writer, resume) = try DictionaryWriter.open(
            at: url,
            source: source(),
            indexing: indexing,
        )
        #expect(resume == nil)
        try writer.append(
            [
                DictionaryWriter.SourcedEntry(
                    entry: entry("爱", traditional: "愛"),
                    sourceFile: 0,
                    sourceOffset: 10,
                ),
                DictionaryWriter.SourcedEntry(
                    entry: entry("中国", reading: "zhong1 guo2"),
                    sourceFile: 0,
                    sourceOffset: 20,
                ),
            ],
            checkpoint: DictionaryWriter.Checkpoint(fileIndex: 0, byteOffset: 20, cardsRead: 2),
        )
        try writer.finish(metadata: metadata(entryCount: 2))

        let container = try DictionaryContainer(contentsOf: url)
        #expect(try container.entryCount() == 2)
        #expect(try container.entries(for: "爱").count == 1)
        // Matched against both scripts, or a reader of traditional text finds
        // nothing at all.
        #expect(try container.entries(for: "愛").count == 1)
        #expect(try container.entries(for: "中国").first?.senses.first?.gloss.text == "значение")
    }

    /// The index the resume path uses is wanted only during an import, and the
    /// lookup indexes only after one. A finished container should carry the
    /// second pair and not the first.
    @Test("A finished container carries the reader's indexes and not the importer's")
    func indexesAfterFinishing() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let (writer, _) = try DictionaryWriter.open(at: url, source: source())
        try writer.append(
            [DictionaryWriter.SourcedEntry(entry: entry("爱"), sourceFile: 0, sourceOffset: 1)],
            checkpoint: DictionaryWriter.Checkpoint(byteOffset: 1, cardsRead: 1),
        )
        try writer.finish(metadata: metadata(entryCount: 1))

        let indexes = try DictionaryContainer(contentsOf: url).indexNames()
        #expect(indexes.contains("entry_on_simplified"))
        #expect(indexes.contains("entry_on_traditional"))
        #expect(!indexes.contains("entry_on_source"))
    }

    /// A re-import needs the source index back, since a finished import drops
    /// it and the resume path's delete depends on it.
    @Test("Reopening a finished container restores the importer's index")
    func reopeningRestoresSourceIndex() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let (first, _) = try DictionaryWriter.open(at: url, source: source())
        try first.append(
            [DictionaryWriter.SourcedEntry(entry: entry("爱"), sourceFile: 0, sourceOffset: 1)],
            checkpoint: DictionaryWriter.Checkpoint(byteOffset: 1, cardsRead: 1),
        )
        try first.finish(metadata: metadata(entryCount: 1))

        _ = try DictionaryWriter.open(at: url, source: source(fingerprint: "changed"))
        #expect(try DictionaryContainer(contentsOf: url).indexNames()
            .contains("entry_on_source"))
    }

    // MARK: - Sense payloads

    /// A container records which codec wrote it, so a new codec does not
    /// invalidate the dictionaries already on disk.
    @Test("A container says which codec wrote its senses")
    func recordedCodec() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try DictionaryContainer.write(
            entries: [entry("爱", senses: ["первое", "второе"])],
            metadata: metadata(entryCount: 1),
            to: url,
        )
        let container = try DictionaryContainer(contentsOf: url)
        #expect(try type(of: container.sensePayloadCodec()).identifier
            == CompactSenseCodec.identifier)
        #expect(try container.entries(for: "爱").first?.senses.count == 2)
    }

    /// The denormalised first gloss, written since v1 and read by nothing. On
    /// a BKRS container it was 160 MB of prose already sitting in the payload
    /// beside it.
    @Test("The summary column is gone")
    func summaryDropped() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try DictionaryContainer.write(
            entries: [entry("爱")],
            metadata: metadata(entryCount: 1),
            to: url,
        )
        #expect(try !DictionaryContainer(contentsOf: url).columnNames(of: "entry")
            .contains("summary"))
    }

    /// A container built before the compact codec existed still opens, which
    /// is what the recorded identifier is for.
    @Test("A JSON container still reads")
    func jsonContainerStillReads() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let senses = entry("爱", senses: ["первое", "второе"]).senses
        try DictionaryContainer.writeForTesting(
            entry: entry("爱", senses: ["первое", "второе"]),
            codec: JSONSenseCodec(),
            metadata: metadata(entryCount: 1),
            to: url,
        )
        let container = try DictionaryContainer(contentsOf: url)
        #expect(try type(of: container.sensePayloadCodec()).identifier
            == JSONSenseCodec.identifier)
        #expect(try container.entries(for: "爱").first?.senses == senses)
    }
}
