// HanReader — MIT licensed. See LICENSE.

import Foundation
import Testing
@testable import HanReaderCore

/// Loads the committed slice of real 大БКРС data.
///
/// Real cards rather than hand-written ones, because the shapes that break a
/// parser are the ones nobody thinks to invent — 一's prose sandhi note, the
/// `[*]` block with no `[ex]` inside it, the one card whose article is split
/// across two lines. Extracted by `Scripts/extract-dsl-fixture.py`; the
/// sidecar manifest says why each card is in there.
private enum Fixture {
    static let text: String = {
        guard let url = Bundle.module.url(
            forResource: "Fixtures/bkrs-slice.dsl",
            withExtension: "txt",
        ),
            let data = try? Data(contentsOf: url),
            let text = String(data: data, encoding: .utf8)
        else {
            Issue.record("could not load the BKRS fixture")
            return ""
        }
        return text
    }()

    /// The committed bytes: UTF-8, no byte-order mark, so the slice stays
    /// diffable in a pull request.
    static let utf8: [UInt8] = Array(text.utf8)

    /// The same content as the source files are actually written: UTF-16LE
    /// with a byte-order mark. Re-encoded here rather than committed, so the
    /// real encoding path is exercised without a binary blob in the
    /// repository.
    static let utf16: [UInt8] = {
        var bytes: [UInt8] = [0xFF, 0xFE]
        for unit in Array(text.utf16) {
            bytes += [UInt8(unit & 0xFF), UInt8(unit >> 8)]
        }
        return bytes
    }()

    struct Reading {
        let records: [DSLCardRecord]
        let header: DSLHeader
        let diagnostics: [DSLDiagnostic]
    }

    static func read(_ bytes: [UInt8]) throws -> Reading {
        var reader = try DSLCardReader(source: DSLMemoryBytes(bytes))
        var records: [DSLCardRecord] = []
        while let record = try reader.next() {
            records.append(record)
        }
        return Reading(
            records: records,
            header: reader.header,
            diagnostics: reader.diagnostics,
        )
    }

    static func card(_ headword: String, in records: [DSLCardRecord]) -> DSLCard? {
        records.first { $0.card.headwords.first == headword }?.card
    }

    static func senses(_ headword: String, in records: [DSLCardRecord]) -> [Sense] {
        guard let card = card(headword, in: records) else { return [] }
        return DSLCardBuilder(syllableBases: []).entries(from: card).entries.first?.senses ?? []
    }
}

@Suite("DSL fixture")
struct DSLFixtureTests {
    /// The committed slice is UTF-8 and the real files are UTF-16LE+BOM. Both
    /// have to come out as the same cards, or the fixture is testing a
    /// different dictionary from the one the app imports.
    @Test("UTF-8 and UTF-16 readings of the same content agree")
    func encodingsAgree() throws {
        let fromUTF8 = try Fixture.read(Fixture.utf8)
        let fromUTF16 = try Fixture.read(Fixture.utf16)
        #expect(fromUTF8.records.map(\.card) == fromUTF16.records.map(\.card))
        #expect(fromUTF8.header == fromUTF16.header)
        // Offsets differ — two bytes per character against one — which is
        // exactly why a resume point is only meaningful against its own file.
        #expect(fromUTF8.records[1].offset != fromUTF16.records[1].offset)
    }

    /// 203 real cards through the whole stack with nothing the parser cannot
    /// account for. The tag set was established by a full scan of all three
    /// files; a diagnostic here means the slice found something that scan
    /// missed.
    @Test("The whole slice parses with no diagnostics")
    func noDiagnostics() throws {
        let result = try Fixture.read(Fixture.utf16)
        #expect(result.records.count == 203)
        #expect(result.diagnostics.isEmpty)

        let builder = DSLCardBuilder(syllableBases: [])
        var diagnostics: [DSLDiagnostic] = []
        var senses = 0
        var multiSense = 0
        for record in result.records {
            let built = builder.entries(from: record.card)
            diagnostics += built.diagnostics
            let count = built.entries.first?.senses.count ?? 0
            senses += count
            if count > 1 {
                multiSense += 1
            }
        }
        #expect(diagnostics.isEmpty)
        // Measured over this slice, and asserted exactly rather than as a
        // threshold: the fixture is committed and deterministic, so a change
        // here is either a parser regression or a deliberate regeneration,
        // and both are worth a line in the diff.
        #expect(senses == 523)
        #expect(multiSense == 67)
    }

    @Test("The header is read from the file")
    func header() throws {
        let header = try Fixture.read(Fixture.utf16).header
        #expect(header.indexLanguage == "Chinese")
        #expect(header.contentsLanguage == "Russian")
        // The fixture is one file, so it declares no includes — and the
        // extraction script writes no stray directives.
        #expect(header.includes.isEmpty)
        #expect(header.other.isEmpty)
    }

    // MARK: - The cards the plan names

    @Test("爱 comes out as divisions with numbered senses under them")
    func ai() throws {
        let senses = try Fixture.senses("爱", in: Fixture.read(Fixture.utf16).records)
        #expect(senses.count > 10)
        #expect(senses[0].label == "I")
        #expect(senses[0].partOfSpeech == ["гл."])
        #expect(senses[1].label == "1)")
        #expect(senses[1].level == 1)
        #expect(senses[1].gloss.text.hasPrefix("любить"))
        // A second division, so the Roman numerals are not being flattened.
        #expect(senses.contains { $0.label == "II" && $0.level == 0 })
    }

    /// The predecessor produced one sense for this card, and put the whole
    /// string `le, liǎo, liào` above the word on the page. Three readings
    /// means three entries sharing the sense run, so the reading-selection
    /// rule can choose between them.
    @Test("了 has many senses and one entry per reading")
    func le() throws {
        let records = try Fixture.read(Fixture.utf16).records
        let card = try #require(Fixture.card("了", in: records))
        #expect(card.pinyin == "le, liǎo, liào")
        let built = DSLCardBuilder(syllableBases: ["le", "liao"]).entries(from: card)
        #expect(built.entries.map(\.readingDisplay) == ["le", "liǎo", "liào"])
        #expect(built.entries[0].senses.count >= 20)
        #expect(built.entries.allSatisfy { $0.senses == built.entries[0].senses })
    }

    /// 一 carries its own tone-sandhi note as prose at the end of the card.
    /// Keeping it is free and faithful; computing sandhi ourselves is not
    /// something this app does.
    @Test("一 keeps its sandhi note")
    func yi() throws {
        let senses = try Fixture.senses("一", in: Fixture.read(Fixture.utf16).records)
        #expect(senses.count > 40)
        #expect(senses.contains { $0.gloss.text.contains("произносится") })
    }

    @Test("打 is the deepest card in the slice")
    func da() throws {
        let senses = try Fixture.senses("打", in: Fixture.read(Fixture.utf16).records)
        #expect(senses.count > 40)
        #expect(senses.contains { $0.level >= 2 })
    }

    /// The one card in 3,434,224 whose article breaks a line inside an open
    /// `[m1]`.
    @Test("乐芙兰's split article reads as one sentence")
    func leBlanc() throws {
        let records = try Fixture.read(Fixture.utf16).records
        let card = try #require(Fixture.card("乐芙兰", in: records))
        #expect(card.body.count == 2)
        let senses = Fixture.senses("乐芙兰", in: records)
        #expect(senses.count == 1)
        #expect(senses[0].gloss.text == "Ле Блан (чемпион из Лиги Легенд)")
    }

    // MARK: - Markup the predecessor lost

    /// 55,414 escaped brackets in the set. `stripDSL` treated every `[` as a
    /// tag and deleted to the next `]`, so these and their contents vanished.
    @Test("Escaped brackets survive as literal brackets")
    func escapedBrackets() throws {
        let senses = try Fixture.senses("一二", in: Fixture.read(Fixture.utf16).records)
        #expect(senses.contains { $0.gloss.text.contains("[целого]") })
    }

    /// 62 `[*]` spans in the set contain no `[ex]`, and that path must neither
    /// crash nor lose the text.
    @Test("An example block with no example keeps its text")
    func blockWithoutExample() throws {
        let senses = try Fixture.senses("栓", in: Fixture.read(Fixture.utf16).records)
        #expect(!senses.isEmpty)
        #expect(senses.allSatisfy { !$0.gloss.text.isEmpty || !$0.examples.isEmpty })
    }

    @Test("A cross-reference records the word it points at")
    func reference() throws {
        let senses = try Fixture.senses("上海市", in: Fixture.read(Fixture.utf16).records)
        #expect(senses.contains { !$0.gloss.references.isEmpty })
    }

    /// `_` means the dictionary has no reading — 77% of the set. An entry
    /// claiming its pronunciation is the empty string is worse than one
    /// admitting it has none.
    @Test("A card with no reading produces an entry with no reading")
    func noReading() throws {
        let records = try Fixture.read(Fixture.utf16).records
        let card = try #require(Fixture.card("碟仙", in: records))
        #expect(card.pinyin == "_")
        let built = DSLCardBuilder(syllableBases: []).entries(from: card)
        #expect(built.entries.count == 1)
        #expect(built.entries[0].reading.isEmpty)
        #expect(built.entries[0].readingDisplay.isEmpty)
    }

    /// Every card in the slice yields at least one entry: whatever the markup
    /// does, a headword the dictionary defines is a headword the reader can
    /// look up.
    @Test("Every card yields an entry")
    func everyCardYieldsAnEntry() throws {
        let records = try Fixture.read(Fixture.utf16).records
        let builder = DSLCardBuilder(syllableBases: [])
        for record in records {
            let built = builder.entries(from: record.card)
            #expect(!built.entries.isEmpty, "\(record.card.headwords) produced no entry")
            #expect(built.entries.allSatisfy { !$0.senses.isEmpty })
        }
    }
}
