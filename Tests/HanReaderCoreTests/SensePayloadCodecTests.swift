// HanReader — MIT licensed. See LICENSE.

import Foundation
import Testing
@testable import HanReaderCore

// MARK: - Fixtures

/// Every sense in the committed slice of real 大БКРС data.
///
/// Round-tripping invented senses tests the cases someone thought of.
/// Round-tripping 523 real ones tests the cases nobody did — the sense whose
/// gloss is empty because its text was all label, the example that splits at
/// a quotation mark, the reference that ends where the gloss does.
private enum Corpus {
    static let senses: [[Sense]] = {
        guard let url = Bundle.module.url(
            forResource: "Fixtures/bkrs-slice.dsl",
            withExtension: "txt",
        ),
            let data = try? Data(contentsOf: url),
            let text = String(data: data, encoding: .utf8)
        else {
            Issue.record("could not load the BKRS fixture")
            return []
        }
        var bytes: [UInt8] = [0xFF, 0xFE]
        for unit in Array(text.utf16) {
            bytes += [UInt8(unit & 0xFF), UInt8(unit >> 8)]
        }
        let builder = DSLCardBuilder(syllableBases: [])
        var runs: [[Sense]] = []
        do {
            var reader = try DSLCardReader(source: DSLMemoryBytes(bytes))
            while let record = try reader.next() {
                if let senses = builder.entries(from: record.card).entries.first?.senses {
                    runs.append(senses)
                }
            }
        } catch {
            Issue.record("could not read the BKRS fixture: \(error)")
        }
        return runs
    }()
}

private func sense(
    id: Int = 0,
    kind: SenseKind = .definition,
    text: String = "значение",
    level: Int = 0,
    parent: Int? = nil,
    label: String? = nil,
    styles: [StyleRun] = [],
    references: [CrossReference] = [],
    partOfSpeech: [String] = [],
    registers: [String] = [],
    examples: [UsageExample] = [],
)
    -> Sense
{
    Sense(
        id: id,
        kind: kind,
        gloss: Gloss(text: text, references: references, styles: styles),
        level: level,
        parent: parent,
        label: label,
        partOfSpeech: partOfSpeech,
        registers: registers,
        examples: examples,
    )
}

@Suite("Compact sense payloads")
struct SensePayloadCodecTests {
    private let codec = CompactSenseCodec()

    // MARK: - Round trips

    /// The whole committed slice, sense for sense. Equality is on `Sense`
    /// itself, so every field has to come back — a codec that silently drops
    /// `registers` would pass a test that only checked gloss text.
    @Test("Every sense in the real slice survives a round trip")
    func realCorpus() throws {
        #expect(!Corpus.senses.isEmpty)
        var total = 0
        for run in Corpus.senses {
            let decoded = try codec.decode(codec.encode(run))
            #expect(decoded == run)
            total += run.count
        }
        #expect(total == 523)
    }

    @Test("An empty run round-trips")
    func emptyRun() throws {
        #expect(try codec.decode(codec.encode([])).isEmpty)
    }

    @Test("Each field survives on its own", arguments: [
        sense(),
        sense(kind: .reference, text: "см. другое"),
        sense(kind: .label, text: "фамилия"),
        sense(text: "", level: 3, parent: 1, label: "I"),
        sense(level: 9, parent: 300),
        sense(styles: [
            StyleRun(style: .bold, range: 0 ..< 2),
            StyleRun(style: .italic, range: 3 ..< 8),
            StyleRun(style: .highlighted, range: 0 ..< 1),
        ]),
        sense(references: [CrossReference(
            simplified: "磁性碰锁",
            traditional: "磁性碰鎖",
            reading: "cíxìng pèngsuǒ",
            range: 2 ..< 6,
        )]),
        sense(references: [CrossReference(
            simplified: "横",
            traditional: nil,
            reading: nil,
            range: 0 ..< 1,
        )]),
        sense(partOfSpeech: ["гл.", "сущ."], registers: ["бот.", "уст."]),
        sense(examples: [UsageExample(
            chinese: "爱儿童",
            translation: "любить ребёнка",
            raw: "爱儿童 любить ребёнка",
        )]),
    ])
    func singleFields(input: Sense) throws {
        #expect(try codec.decode(codec.encode([input])) == [input])
    }

    /// `id` is the index in the run and is not stored, so a run decodes with
    /// its positions renumbered — which is what every reader of it assumes.
    @Test("Identifiers come back as positions")
    func identifiersArePositions() throws {
        let run = (0 ..< 5).map { sense(id: 97 + $0, text: "s\($0)") }
        let decoded = try codec.decode(codec.encode(run))
        #expect(decoded.map(\.id) == [0, 1, 2, 3, 4])
        #expect(decoded.map(\.gloss.text) == run.map(\.gloss.text))
    }

    // MARK: - Examples, which are stored once

    /// `raw` is the example as written and the two halves are a heuristic
    /// split of it, so storing all three copies the text twice. Measured over
    /// the set, the halves cost as much again as `raw`.
    @Test("An example is stored once and split on the way out", arguments: [
        UsageExample(chinese: "爱儿童", translation: "любить ребёнка", raw: "爱儿童 любить ребёнка"),
        UsageExample(chinese: "", translation: "только по-русски", raw: "только по-русски"),
        UsageExample(chinese: "他说：“好。”", translation: "он сказал", raw: "他说：“好。” он сказал"),
        UsageExample(chinese: "一", translation: "", raw: "一"),
        UsageExample(chinese: "", translation: "", raw: ""),
    ])
    func examples(input: UsageExample) throws {
        let decoded = try codec.decode(codec.encode([sense(examples: [input])]))
        #expect(decoded.first?.examples == [input])
    }

    /// A split that is not a slice of the raw text — which a different
    /// splitter could produce — is written out in full rather than silently
    /// reconstructed wrongly. The compact form is an optimisation, not an
    /// invariant the model has to keep.
    @Test("An example whose halves are not slices of its raw text still round-trips")
    func examplesThatAreNotSlices() throws {
        let odd = UsageExample(chinese: "完全", translation: "иное", raw: "ничего общего")
        let decoded = try codec.decode(codec.encode([sense(examples: [odd])]))
        #expect(decoded.first?.examples == [odd])
    }

    /// The same text twice over, where a naive "find the half in the raw"
    /// would pick the wrong occurrence.
    @Test("A repeated half picks the right occurrence")
    func repeatedHalf() throws {
        let repeated = UsageExample(chinese: "好", translation: "好", raw: "好 好")
        let decoded = try codec.decode(codec.encode([sense(examples: [repeated])]))
        #expect(decoded.first?.examples == [repeated])
    }

    // MARK: - Size

    /// The reason the codec exists. Measured over the real slice rather than
    /// asserted as a ratio someone liked: JSON spends most of a payload on
    /// syntax and key names, written out once per sense across three and a
    /// half million of them.
    @Test("The compact form is substantially smaller than JSON")
    func size() throws {
        let json = JSONSenseCodec()
        var compactBytes = 0
        var jsonBytes = 0
        for run in Corpus.senses {
            compactBytes += try codec.encode(run).count
            jsonBytes += try json.encode(run).count
        }
        #expect(compactBytes * 2 < jsonBytes, "compact \(compactBytes), json \(jsonBytes)")
    }

    // MARK: - Malformed payloads

    /// A payload is data from a file on disk. A corrupt one costs that entry,
    /// not the process, so every read is bounds-checked rather than trapping.
    @Test("A truncated payload throws rather than trapping")
    func truncated() throws {
        let full = try codec.encode([sense(
            text: "значение",
            label: "1)",
            examples: [UsageExample(chinese: "一", translation: "один", raw: "一 один")],
        )])
        for length in 0 ..< full.count {
            #expect(throws: (any Error).self) {
                _ = try codec.decode(full.prefix(length))
            }
        }
    }

    @Test("A payload from a newer format is refused, not guessed at")
    func newerVersion() throws {
        var bytes = try [UInt8](codec.encode([sense()]))
        bytes[0] = CompactSenseCodec.version + 1
        #expect(throws: SensePayloadError.unknownVersion(CompactSenseCodec.version + 1)) {
            _ = try codec.decode(Data(bytes))
        }
    }

    @Test("An empty payload is refused")
    func emptyPayload() {
        #expect(throws: (any Error).self) {
            _ = try codec.decode(Data())
        }
    }

    // MARK: - Codec selection

    /// A container records which codec wrote it, so adding one does not
    /// invalidate the dictionaries already on disk.
    @Test("A container's recorded codec is what reads it")
    func selection() throws {
        #expect(try SensePayloadCodecs.named("compact-v1") is CompactSenseCodec)
        #expect(try SensePayloadCodecs.named("json") is JSONSenseCodec)
        // Written before the codec was recorded, which means JSON.
        #expect(try SensePayloadCodecs.named(nil) is JSONSenseCodec)
        #expect(throws: SensePayloadError.unknownCodec("compact-v99")) {
            _ = try SensePayloadCodecs.named("compact-v99")
        }
    }

    /// JSON still reads, so a dictionary compiled by an earlier build opens.
    @Test("JSON payloads still round-trip")
    func jsonStillWorks() throws {
        let json = JSONSenseCodec()
        let run = try #require(Corpus.senses.first { $0.count > 2 })
        #expect(try json.decode(json.encode(run)) == run)
    }

    // MARK: - Wire format

    /// The byte for a style is fixed here rather than taken from the case
    /// order, so reordering the enum cannot change what is already on disk.
    @Test("Style bytes are stable", arguments: TextStyle.allCases)
    func styleBytes(style: TextStyle) {
        #expect(TextStyle(encoded: style.encoded) == style)
    }

    @Test("Varints round-trip at the boundaries", arguments: [
        0, 1, 127, 128, 255, 256, 16383, 16384, 1 << 20, Int(Int32.max),
    ])
    func varints(value: Int) throws {
        var bytes: [UInt8] = []
        CompactSenseCodec.appendVarint(value, to: &bytes)
        var reader = CompactSenseCodec.Reader(Data(bytes))
        #expect(try reader.varint() == value)
    }
}
