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

/// The text a style run actually selects.
///
/// Asserting the substring rather than the offsets is the point: an offset
/// that is off by one still reads as a plausible number in a failure message,
/// where the wrong substring says exactly what went wrong.
private func styled(_ sense: Sense, _ index: Int = 0) -> String? {
    guard index < sense.gloss.styles.count else { return nil }
    return substring(sense.gloss.text, sense.gloss.styles[index].range)
}

private func referenced(_ sense: Sense, _ index: Int = 0) -> String? {
    guard index < sense.gloss.references.count else { return nil }
    return substring(sense.gloss.text, sense.gloss.references[index].range)
}

private func substring(_ text: String, _ range: Range<Int>) -> String? {
    let span = NSRange(location: range.lowerBound, length: range.count)
    guard let converted = Range(span, in: text) else { return nil }
    return String(text[converted])
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

    /// Several headword lines are several spellings of one article, so each
    /// becomes its own entry over the same senses. Reading the second as the
    /// traditional form of the first is an invention the format does not
    /// support — and it dropped every spelling after the second outright.
    @Test("Every headword line becomes an entry")
    func severalHeadwords() {
        let result = DSLCardBuilder(syllableBases: bases).entries(from: DSLCard(
            headwords: ["爱", "愛", "㤅"],
            pinyin: "ài",
            body: ["[m1]любить[/m]"],
        ))
        #expect(result.entries.map(\.headword.simplified) == ["爱", "愛", "㤅"])
        #expect(result.entries.allSatisfy { $0.headword.traditional == nil })
        #expect(result.entries.allSatisfy { $0.senses == result.entries[0].senses })
    }

    @Test("Several headwords and several readings multiply out")
    func headwordsAndReadings() {
        let result = DSLCardBuilder(syllableBases: bases).entries(from: DSLCard(
            headwords: ["了", "瞭"],
            pinyin: "le, liǎo",
            body: ["[m1]текст[/m]"],
        ))
        #expect(result.entries.count == 4)
        #expect(result.entries.map(\.readingDisplay) == ["le", "liǎo", "le", "liǎo"])
    }

    @Test("Diagnostics from the lexer reach the caller")
    func diagnosticsPropagate() {
        let result = build("[m1][zzz]текст[/m]")
        #expect(result.diagnostics.count == 1)
    }
}

/// Gloss text is trimmed and renumbered after its markup ranges were
/// recorded against the untrimmed text, so every range has to move with it.
/// These are the cases where it did not.
@Suite("DSL gloss ranges")
struct DSLGlossRangeTests {
    /// Lifting `1)` out of the gloss also removes the space after it, and
    /// every recorded range has to move by the whole of that. It did not:
    /// 16,957 senses in the set carry a style run inside a numbered sense,
    /// and all of them pointed one character too far right.
    @Test("A style range follows the text past a lifted label")
    func styleAfterLabel() {
        let result = senses("[m1]1) первый ([i]по порядку[/i])[/m]")
        #expect(result[0].label == "1)")
        #expect(result[0].gloss.text == "первый (по порядку)")
        #expect(styled(result[0]) == "по порядку")
    }

    /// Same fault, worse consequence: a reference reaching the end of the
    /// gloss overshot it and was discarded rather than clipped. 3,974 senses.
    @Test("A reference at the end of a numbered sense survives")
    func referenceAtEndOfLabelledSense() {
        let result = senses("[m1]2) ключ иероглифа ([p]см.[/p] [ref]横[/ref])[/m]")
        #expect(result[0].label == "2)")
        #expect(referenced(result[0]) == "横")
        #expect(result[0].gloss.references.first?.simplified == "横")
    }

    /// 395,878 `[p]` tags, nearly all followed by a space — so the prose of
    /// 85,395 senses begins with whitespace that the final trim removed
    /// without telling the ranges. No label involved.
    @Test("A style range follows the text past trimmed whitespace")
    func styleAfterLeadingSpace() {
        let result = senses("[m1][p]бот.[/p] девясил каспийский ([i]Inula caspica[/i])[/m]")
        #expect(result[0].registers == ["бот."])
        #expect(result[0].gloss.text == "девясил каспийский (Inula caspica)")
        #expect(styled(result[0]) == "Inula caspica")
    }

    @Test("A reference range follows the text past trimmed whitespace")
    func referenceAfterLeadingSpace() {
        let result = senses("[m1][p]см.[/p] [ref]磁性碰锁[/ref] и далее[/m]")
        #expect(referenced(result[0]) == "磁性碰锁")
    }

    /// Both trims at once, which is where an offset computed by subtracting
    /// string lengths goes most wrong.
    @Test("Ranges survive a leading space, a label and a trailing space")
    func rangesSurviveEverything() {
        let result = senses("[m1]  12) [b]первый[/b] и [i]второй[/i]   [/m]")
        #expect(result[0].label == "12)")
        #expect(result[0].gloss.text == "первый и второй")
        #expect(styled(result[0], 0) == "первый")
        #expect(styled(result[0], 1) == "второй")
    }

    /// The trim is a pure function, so the awkward inputs can be put to it
    /// directly.
    @Test("Trimming is exact at the edges", arguments: [
        ("текст", "текст", String?.none),
        ("   текст   ", "текст", nil),
        ("1)", "", "1)"),
        ("1)   ", "", "1)"),
        ("   ", "", nil),
        ("", "", nil),
    ])
    func trimEdges(input: String, text: String, label: String?) {
        let result = SenseAssembly.trim(text: input)
        #expect(result.text == text)
        #expect(result.label == label)
    }

    /// A run reaching into whitespace that the trim removes is clipped to the
    /// gloss, not discarded. It is still the run the dictionary asked for, and
    /// dropping it would cost the emphasis over the whole phrase to save a
    /// space.
    @Test("A run overshooting into trimmed whitespace is clipped")
    func runClippedToGloss() {
        let result = senses("[m1]текст [i]курсив [/i][/m]")
        #expect(result[0].gloss.text == "текст курсив")
        #expect(styled(result[0]) == "курсив")
    }

    @Test("An unclosed run over trailing whitespace is clipped too")
    func unclosedRunClipped() {
        let result = senses("[m1]текст [i]курсив   ")
        #expect(result[0].gloss.text == "текст курсив")
        #expect(styled(result[0]) == "курсив")
    }

    /// 21 `[ref]` spans in the set close after a space. A headword with a
    /// trailing space matches no entry in any dictionary, so the reference
    /// would point nowhere — and the range has to be trimmed with the string,
    /// or the two disagree about which characters the link covers.
    @Test(
        "A reference span is trimmed to the headword it names",
        arguments: ["[ref]磁性碰锁 [/ref]", "[ref] 磁性碰锁[/ref]", "[ref]  磁性碰锁  [/ref]"],
    )
    func referenceSpanTrimmed(markup: String) throws {
        let result = senses("[m1]см. \(markup) и далее[/m]")
        let reference = try #require(result[0].gloss.references.first)
        #expect(reference.simplified == "磁性碰锁")
        #expect(referenced(result[0]) == "磁性碰锁")
    }

    @Test("A reference span of nothing but whitespace records nothing")
    func referenceSpanAllWhitespace() {
        #expect(senses("[m1]см. [ref] [/ref][/m]")[0].gloss.references.isEmpty)
    }

    @Test("A span lying entirely inside a lifted label is dropped")
    func spanInsideLabel() {
        // `[b]I[/b]` is the division heading itself: once lifted into the
        // label there is no gloss left for the run to point at.
        let result = senses("[m1][b]I[/b] [p]гл.[/p][/m]")
        #expect(result[0].label == "I")
        #expect(result[0].gloss.text.isEmpty)
        #expect(result[0].gloss.styles.isEmpty)
    }
}

/// DSL markup is not reliably balanced — the set has two more `[mN]` opens
/// than `[/m]` closes and 241 sense spans with a style tag still open — and
/// the rule the importer follows is that nothing is ever deleted.
@Suite("Unbalanced DSL markup")
struct DSLUnbalancedMarkupTests {
    /// Nothing is ever deleted. An unclosed `[i]` kept its text but lost the
    /// emphasis it was asking for — 241 sense spans in the set close `[/m]`
    /// with a style still open.
    @Test("An unclosed emphasis still produces its run")
    func unclosedStyle() {
        let result = senses("[m1]текст [i]курсив[/m][m1]другой[/m]")
        #expect(result.count == 2)
        #expect(styled(result[0]) == "курсив")
        // And it does not leak into the next sense.
        #expect(result[1].gloss.styles.isEmpty)
    }

    @Test("An unclosed emphasis at the end of a card still produces its run")
    func unclosedStyleAtEnd() {
        let result = senses("[m1]текст [i]курсив")
        #expect(styled(result[0]) == "курсив")
    }

    @Test("An unclosed reference still records the word")
    func unclosedReference() {
        let result = senses("[m1]см. [ref]磁性碰锁")
        #expect(referenced(result[0]) == "磁性碰锁")
    }

    /// `[p]` and `[ex]` divert text out of the gloss, so an unclosed one took
    /// its contents out of the sense entirely. None occur in this set, but
    /// losing text is the one thing this importer must never do.
    @Test("An unclosed category keeps its text")
    func unclosedGrammar() {
        let result = senses("[m1]текст [p]гл.")
        #expect(result[0].partOfSpeech == ["гл."])
        #expect(result[0].gloss.text == "текст")
    }

    @Test("An unclosed example keeps its text")
    func unclosedExample() {
        let result = senses("[m1]текст [ex]爱儿童 любить ребёнка")
        #expect(result[0].examples.first?.raw == "爱儿童 любить ребёнка")
    }

    /// The other half of the same fault: a buffer still open when the next
    /// sense began went on collecting that sense's prose.
    @Test("An unclosed category does not swallow the next sense")
    func unclosedGrammarDoesNotLeak() {
        let result = senses("[m1][p]гл.[m2]любить[/m]")
        #expect(result.count == 2)
        #expect(result[0].partOfSpeech == ["гл."])
        #expect(result[1].gloss.text == "любить")
    }

    /// 479 cards begin their article with markup and no `[mN]` at all. The
    /// fallback sense used to be created by the first *text* token, which
    /// cleared the offset the `[i]` had already recorded.
    @Test("Emphasis before any sense tag still produces its run")
    func styleBeforeAnySense() {
        let result = senses("[i]курсив[/i] и дальше")
        #expect(result.count == 1)
        #expect(result[0].gloss.text == "курсив и дальше")
        #expect(styled(result[0]) == "курсив")
    }

    @Test("A reference before any sense tag still records the word")
    func referenceBeforeAnySense() {
        let result = senses("[ref]磁性碰锁[/ref] см.")
        #expect(referenced(result[0]) == "磁性碰锁")
    }

    // MARK: - A sense broken across body lines

    /// 乐芙兰, the one card in 3,434,224 whose article breaks a line inside
    /// an open `[m1]`. Concatenating gives `Ле Блан(чемпион…)`.
    @Test("A sense continued on the next line gains a space, not nothing")
    func senseAcrossLines() {
        let result = senses("[m1]Ле Блан", "(чемпион из Лиги Легенд)[/m]")
        #expect(result.count == 1)
        #expect(result[0].gloss.text == "Ле Блан (чемпион из Лиги Легенд)")
    }

    /// And a card that closes each sense at the end of its line — which is
    /// how most DSL dictionaries are written — gains no stray space.
    @Test("One sense per line gains no leading space")
    func sensePerLine() {
        let result = senses("[m1]первый[/m]", "[m2]второй[/m]")
        #expect(result.map(\.gloss.text) == ["первый", "второй"])
    }
}
