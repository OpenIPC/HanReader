// HanReader — MIT licensed. See LICENSE.

import Foundation
import Testing
@testable import HanReaderCore

/// Enough syllables to split the readings these tests use.
private let bases: Set = [
    "ai", "le", "liao", "yi", "da", "zhong", "guo", "tu", "er", "qi", "si", "tan",
]

private func build(
    headword: String = "爱",
    pinyin: String = "ài",
    _ body: String...,
)
    -> (entries: [DictionaryEntry], diagnostics: [DSLDiagnostic])
{
    DSLCardBuilder(syllableBases: bases).entries(from: DSLCard(
        headwords: [headword],
        pinyin: pinyin,
        body: body,
    ))
}

private func senses(_ body: String...) -> [Sense] {
    DSLCardBuilder(syllableBases: bases).entries(from: DSLCard(
        headwords: ["爱"],
        pinyin: "ài",
        body: body,
    )).entries.first?.senses ?? []
}

@Suite("DSL card builder")
struct DSLCardBuilderTests {
    // MARK: - The bug the rebuild exists for

    /// Test number one. The predecessor produced **one sense per card** —
    /// 3,434,222 rows over 3,434,222 headwords, exactly one each — because
    /// it treated a line as a sense, and a card's whole sense run arrives on
    /// a single physical line. The structure is in the markup.
    @Test("Two sense spans on one line become two senses")
    func twoSensesOneLine() {
        let result = senses("[m1]первый[/m][m2]второй[/m]")
        #expect(result.count == 2)
        #expect(result.map(\.gloss.text) == ["первый", "второй"])
        #expect(result.map(\.level) == [0, 1])
    }

    @Test("A real card's shape comes out as a list, not a blob")
    func realisticCard() {
        // A division heading, two numbered senses under it, then a second
        // division — the shape most multi-sense cards take.
        let division = "[m1][b]I[/b] [p]гл.[/p][/m]"
        let numbered = "[m2]1) любить[/m][m2]2) ценить[/m]"
        let second = "[m1][b]II[/b] [p]сущ.[/p][/m]"
        let result = senses(division + numbered + second)
        #expect(result.count == 4)
        #expect(result.map(\.level) == [0, 1, 1, 0])
        #expect(result.map(\.label) == ["I", "1)", "2)", "II"])
        #expect(result[1].gloss.text == "любить")
        #expect(result[0].partOfSpeech == ["гл."])
    }

    // MARK: - Nesting

    /// `[m4]` after an `[m3]` has to find the right `[m2]`. A stack that
    /// pushes on open and pops on close attaches it to whatever was last,
    /// which is wrong the moment levels skip.
    @Test("A deeper sense nests under the right parent")
    func nesting() {
        let result = senses("[m1]A[/m][m2]B[/m][m3]C[/m][m4]D[/m][m2]E[/m]")
        #expect(result.map(\.level) == [0, 1, 2, 3, 1])
        #expect(result.map(\.parent) == [nil, 0, 1, 2, 0])
    }

    @Test("Reopening a shallower level closes the deeper ones")
    func reopeningShallower() {
        let result = senses("[m1]A[/m][m3]B[/m][m1]C[/m]")
        #expect(result.map(\.level) == [0, 2, 0])
        #expect(result.map(\.parent) == [nil, 0, nil])
    }

    /// Across the whole set there are two more `[mN]` opens than `[/m]`
    /// closes, so the builder cannot assume balance.
    @Test("Unclosed markup still produces its senses")
    func unbalancedMarkup() {
        let result = senses("[m1]первый[m2]второй")
        #expect(result.count == 2)
        #expect(result.map(\.gloss.text) == ["первый", "второй"])
    }

    @Test("Body text with no markup at all is still a sense")
    func noMarkup() {
        let result = senses("просто текст")
        #expect(result.map(\.gloss.text) == ["просто текст"])
    }

    // MARK: - Readings

    /// 77% of cards. Returning `[""]` — which a naive split does — produces
    /// an entry claiming its pronunciation is the empty string.
    @Test("An underscore is not a reading")
    func underscoreReading() {
        let result = build(pinyin: "_", "[m1]текст[/m]")
        #expect(result.entries.count == 1)
        #expect(result.entries[0].reading.isEmpty)
        #expect(result.entries[0].readingDisplay.isEmpty)
    }

    /// One entry per reading, so the reading-selection rule can choose
    /// between them. One entry reading `le, liǎo, liào` would put all three
    /// above the word, which is the prototype's behaviour.
    @Test("A card with several readings becomes several entries")
    func severalReadings() {
        let result = build(headword: "了", pinyin: "le, liǎo", "[m1]текст[/m]")
        #expect(result.entries.count == 2)
        #expect(result.entries.map(\.readingDisplay) == ["le", "liǎo"])
        // They share the sense run rather than splitting it.
        #expect(result.entries.allSatisfy { $0.senses.count == 1 })
    }

    @Test("A reading that cannot be split still displays")
    func unsplittableReading() {
        let result = build(pinyin: "zzzqqq", "[m1]текст[/m]")
        #expect(result.entries.count == 1)
        // Degraded to a literal: the reading shows, only the merge key is
        // lost, so the word forms its own group instead of joining one.
        #expect(result.entries[0].readingDisplay == "zzzqqq")
    }

    @Test("A run-together reading is split into syllables")
    func runTogetherReading() {
        let result = build(pinyin: "àiguó", "[m1]текст[/m]")
        #expect(result.entries.first?.reading.count == 2)
    }

    // MARK: - Labels and categories

    @Test("A grammatical category is separated from the prose")
    func partOfSpeech() {
        let result = senses("[m1][p]гл.[/p]любить[/m]")
        #expect(result[0].partOfSpeech == ["гл."])
        #expect(result[0].gloss.text == "любить")
    }

    /// Unrecognised markers go to registers verbatim rather than being
    /// dropped. A field marker this list has not heard of is still
    /// something the dictionary chose to print.
    @Test(
        "A field marker is kept even when unrecognised",
        arguments: ["бот.", "ист.", "уст.", "зззз."],
    )
    func registers(marker: String) {
        let result = senses("[m1][p]\(marker)[/p]текст[/m]")
        #expect(result[0].registers == [marker])
        #expect(result[0].partOfSpeech.isEmpty)
    }

    @Test("Numbering is lifted out of the gloss", arguments: [
        ("1) любить", "1)", "любить"),
        ("12) ценить", "12)", "ценить"),
        ("а) первый", "а)", "первый"),
        ("II сущ", "II", "сущ"),
    ])
    func labels(body: String, label: String, gloss: String) {
        let result = senses("[m1]\(body)[/m]")
        #expect(result[0].label == label)
        #expect(result[0].gloss.text == gloss)
    }

    @Test("Prose that merely starts with a letter is not a label")
    func notALabel() {
        let result = senses("[m1]Исторический термин[/m]")
        #expect(result[0].label == nil)
        #expect(result[0].gloss.text == "Исторический термин")
    }

    // MARK: - Emphasis and references

    /// 631,732 italic spans, nearly all parenthetical grammatical notes.
    /// Flattened, they read as part of the definition.
    @Test("Italics are kept as a range, not flattened")
    func italics() throws {
        let result = senses("[m1]любить ([i]кого-л.[/i])[/m]")
        #expect(result[0].gloss.text == "любить (кого-л.)")
        // One `#require` per statement: a macro expanded inside another
        // macro's argument is a recursive expansion the compiler refuses.
        let run = try #require(result[0].gloss.styles.first)
        #expect(run.style == .italic)
        let text = result[0].gloss.text
        let span = NSRange(location: run.range.lowerBound, length: run.range.count)
        let range = try #require(Range(span, in: text))
        #expect(String(text[range]) == "кого-л.")
    }

    @Test("A cross-reference records the word it points at")
    func reference() {
        let result = senses("[m1]см. [ref]磁性碰锁[/ref][/m]")
        #expect(result[0].gloss.references.first?.simplified == "磁性碰锁")
        #expect(result[0].gloss.text == "см. 磁性碰锁")
    }

    @Test("An empty emphasis span records nothing")
    func emptyStyle() {
        #expect(senses("[m1][i][/i]текст[/m]")[0].gloss.styles.isEmpty)
    }

    // MARK: - Examples

    @Test("An example is split into its two languages")
    func exampleSplit() {
        let result = senses("[m1][*][ex]爱儿童 любить ребёнка (детей)[/ex][/*][/m]")
        let example = result[0].examples.first
        #expect(example?.chinese == "爱儿童")
        #expect(example?.translation == "любить ребёнка (детей)")
        #expect(example?.raw == "爱儿童 любить ребёнка (детей)")
    }

    @Test("An example with no Chinese still keeps everything")
    func exampleWithoutChinese() {
        let example = SenseAssembly.splitExample("только по-русски")
        #expect(example.chinese.isEmpty)
        #expect(example.translation == "только по-русски")
        #expect(example.raw == "только по-русски")
    }

    @Test("CJK punctuation stays with the Chinese")
    func examplePunctuation() {
        let example = SenseAssembly.splitExample("他说：“好。” он сказал")
        #expect(example.chinese == "他说：“好。”")
        #expect(example.translation == "он сказал")
    }

    /// 62 `[*]` spans in the set contain no `[ex]`. The block is treated as
    /// transparent, so that path needs no special case and loses nothing.
    @Test("An example block with no example does not lose its text")
    func blockWithoutExample() {
        let result = senses("[m1][*]просто текст[/*][/m]")
        #expect(result[0].examples.isEmpty)
        #expect(result[0].gloss.text == "просто текст")
    }

    // MARK: - Entry shape

    @Test("An empty card produces no entries")
    func emptyCard() {
        let result = DSLCardBuilder(syllableBases: bases)
            .entries(from: DSLCard(headwords: [], pinyin: "_", body: []))
        #expect(result.entries.isEmpty)
    }

    @Test("A second headword line is the traditional spelling")
    func traditionalHeadword() {
        let result = DSLCardBuilder(syllableBases: bases).entries(from: DSLCard(
            headwords: ["爱", "愛"],
            pinyin: "ài",
            body: ["[m1]любить[/m]"],
        ))
        #expect(result.entries.first?.headword.traditional == "愛")
    }

    @Test("Diagnostics from the lexer reach the caller")
    func diagnosticsPropagate() {
        let result = build("[m1][zzz]текст[/m]")
        #expect(result.diagnostics.count == 1)
    }
}
