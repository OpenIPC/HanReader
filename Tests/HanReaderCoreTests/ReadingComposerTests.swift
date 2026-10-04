// HanReader — MIT licensed. See LICENSE.

import Testing
@testable import HanReaderCore

/// A dictionary written out by hand, so that a test about which reading wins
/// says which entries exist rather than building a SQLite container to ask.
private struct StubDictionary: DictionaryLookup {
    var words: [String: [DictionaryEntry]] = [:]
    var characters: [Character: [CharacterReading]] = [:]
    var failsOn: String?

    func entries(for headword: String) throws -> [DictionaryEntry] {
        if headword == failsOn {
            throw StubError.unreadable
        }
        return words[headword] ?? []
    }

    func readings(forCharacter character: Character) throws -> [CharacterReading] {
        characters[character] ?? []
    }
}

private enum StubError: Error { case unreadable }

private func entry(
    _ simplified: String,
    _ numeric: String,
    senses: Int = 1,
)
    -> DictionaryEntry
{
    DictionaryEntry(
        headword: Headword(simplified: simplified, traditional: nil),
        reading: Pinyin.parse(numeric: numeric),
        senses: (0 ..< senses).map {
            Sense(id: $0, kind: .definition, gloss: Gloss(text: "sense \($0)"))
        },
    )
}

private func character(_ char: Character, _ numeric: String) -> CharacterReading {
    CharacterReading(
        character: char,
        numeric: numeric,
        display: Pinyin.display(Pinyin.parse(numeric: numeric)),
        rank: 0,
    )
}

@Suite("Reading composition")
struct ReadingComposerTests {
    // MARK: - Whole-word readings

    @Test("A word the dictionary knows is read from the dictionary")
    func exactLookup() throws {
        let stub = StubDictionary(words: ["中国": [entry("中国", "Zhong1 guo2")]])
        let readingResult = try ReadingComposer.reading(for: "中国", in: stub)
        let reading = try #require(readingResult)
        #expect(reading.display == "Zhōngguó")
        #expect(reading.source == .dictionary)
    }

    /// The rule that matters most, and the measurement behind it. Scored
    /// against 38 hand-labelled common words: sense count alone gets 28,
    /// preferring a neutral tone first gets 34.
    ///
    /// It is not a tie-break but a grammatical signal — a character takes the
    /// neutral tone precisely when it is working as a particle or a suffix,
    /// which is its commonest use. Here the `liǎo` entry has more senses and
    /// would win on sense count, and `le` is the reading a reader meets in
    /// 举行了, 笑了笑 and 拍了.
    @Test("A neutral-tone reading beats a richer entry")
    func neutralToneWins() throws {
        let stub = StubDictionary(words: ["了": [
            entry("了", "liao3", senses: 3),
            entry("了", "le5", senses: 2),
        ]])
        let readingResult = try ReadingComposer.reading(for: "了", in: stub)
        let reading = try #require(readingResult)
        #expect(reading.display == "le")
    }

    @Test("Without a neutral tone, the richer entry wins")
    func sensesDecideOtherwise() throws {
        let stub = StubDictionary(words: ["行": [
            entry("行", "hang2", senses: 6),
            entry("行", "xing2", senses: 16),
        ]])
        let readingResult = try ReadingComposer.reading(for: "行", in: stub)
        let reading = try #require(readingResult)
        #expect(reading.display == "xíng")
    }

    /// A capital marks a surname or a place, which is rarely the reading
    /// wanted in prose — and the surname entry often has more senses, so
    /// without this 都 reads `Dū` and 过 reads `Guò`.
    @Test("A capitalised reading loses to a lowercase one")
    func lowercaseWins() throws {
        let stub = StubDictionary(words: ["都": [
            entry("都", "Du1", senses: 9),
            entry("都", "dou1", senses: 1),
        ]])
        let readingResult = try ReadingComposer.reading(for: "都", in: stub)
        let reading = try #require(readingResult)
        #expect(reading.display == "dōu")
    }

    /// Determinism matters more than which one is picked: a tie resolved by
    /// row order would change the page when the dictionary was recompiled.
    @Test("A tie is broken the same way every time")
    func tiesAreDeterministic() throws {
        let forwards = StubDictionary(words: ["行": [entry("行", "hang2"), entry("行", "xing2")]])
        let backwards = StubDictionary(words: ["行": [entry("行", "xing2"), entry("行", "hang2")]])

        let firstResult = try ReadingComposer.reading(for: "行", in: forwards)
        let first = try #require(firstResult)
        let secondResult = try ReadingComposer.reading(for: "行", in: backwards)
        let second = try #require(secondResult)
        #expect(first == second)
    }

    // MARK: - Honesty about what was guessed

    /// 为 is `wéi` and `wèi` with no neutral tone and no signal to separate
    /// them — exactly what a part-of-speech tagger exists for. The reading is
    /// still shown, because no annotation is worse for a learner than a
    /// usually-right one, but it is marked so the UI can draw it faintly and
    /// the reader knows to check the panel.
    @Test("A word with several readings is marked as a guess")
    func ambiguityIsDeclared() throws {
        let stub = StubDictionary(words: ["为": [
            entry("为", "wei2", senses: 9),
            entry("为", "wei4", senses: 3),
        ]])
        let readingResult = try ReadingComposer.reading(for: "为", in: stub)
        let reading = try #require(readingResult)
        #expect(reading.source == .ambiguous)
        #expect(reading.source.isApproximate)
    }

    @Test("A word with one reading is not marked as a guess")
    func singleReadingIsCertain() throws {
        let stub = StubDictionary(words: ["中国": [entry("中国", "Zhong1 guo2")]])
        let readingResult = try ReadingComposer.reading(for: "中国", in: stub)
        let reading = try #require(readingResult)
        #expect(reading.source == .dictionary)
        #expect(!reading.source.isApproximate)
    }

    /// Nearly every common character has a surname entry beside its ordinary
    /// one. 年 is `nián` and `Nián` — the same sound written two ways, not
    /// two readings. Counting that as a disagreement would mark most of the
    /// page as uncertain, and a signal that fires everywhere says nothing.
    @Test("A surname spelling does not make a word ambiguous")
    func capitalisationIsNotAmbiguity() throws {
        let stub = StubDictionary(words: ["年": [
            entry("年", "nian2", senses: 5),
            entry("年", "Nian2", senses: 1),
        ]])
        let readingResult = try ReadingComposer.reading(for: "年", in: stub)
        let reading = try #require(readingResult)
        #expect(reading.display == "nián")
        #expect(reading.source == .dictionary)
    }

    @Test("An entry with no reading at all is skipped")
    func entriesWithoutReadingsAreSkipped() throws {
        // 77% of BKRS entries are like this: a headword and a definition,
        // with the pinyin field holding `_`.
        let stub = StubDictionary(
            words: ["爱": [entry("爱", "")]],
            characters: ["爱": [character("爱", "ai4")]],
        )
        let readingResult = try ReadingComposer.reading(for: "爱", in: stub)
        let reading = try #require(readingResult)
        #expect(reading.display == "ài")
        // Fell through to composition rather than returning an empty reading.
        #expect(reading.source == .composed)
    }

    /// CC-CEDICT writes `[xx5]` for a character whose pronunciation it does
    /// not know — 23 of them, mostly Korean *gugja* characters that happen to
    /// be encoded as Han. `Pinyin.display` renders that as `?`, and the token
    /// case exists so the UI can decline to show it. Showing it would put a
    /// question mark over the word *and* mark it `.dictionary`, presenting a
    /// non-answer as a confident one.
    @Test("A reading the dictionary marks unknown is not shown")
    func unknownReadingsAreRefused() throws {
        let stub = StubDictionary(words: ["丆": [entry("丆", "xx5")]])
        #expect(try ReadingComposer.reading(for: "丆", in: stub) == nil as TokenReading?)
    }

    @Test("An unknown reading does not hide a known one")
    func unknownDoesNotCrowdOutKnown() throws {
        let stub = StubDictionary(words: ["X": [
            entry("X", "xx5", senses: 9),
            entry("X", "hao3", senses: 1),
        ]])
        let readingResult = try ReadingComposer.reading(for: "X", in: stub)
        let reading = try #require(readingResult)
        #expect(reading.display == "hǎo")
        // And the unknown one does not count towards ambiguity either: there
        // is only one reading here, not two.
        #expect(reading.source == .dictionary)
    }

    @Test("A character with an unknown reading blocks composition")
    func unknownBlocksComposition() throws {
        let stub = StubDictionary(characters: [
            "北": [character("北", "bei3")],
            "丆": [character("丆", "xx5")],
        ])
        // Better no annotation than `běi?` over a two-character word.
        #expect(try ReadingComposer.reading(for: "北丆", in: stub) == nil as TokenReading?)
    }

    @Test("Entries already in hand are not looked up again")
    func readingFromEntries() {
        let entries = [entry("中国", "Zhong1 guo2")]
        #expect(ReadingComposer.reading(from: entries)?.display == "Zhōngguó")
        #expect(ReadingComposer.reading(from: []) == nil)
    }

    // MARK: - Composed readings

    /// Not optional, and the number is why: 77% of BKRS entries carry no
    /// reading, so for a Russian-preferring reader whole-word lookup leaves
    /// most of the page blank. CC-CEDICT's single-character headwords fill it.
    @Test("A word with no entry is assembled from its characters")
    func composesFromCharacters() throws {
        let stub = StubDictionary(characters: [
            "北": [character("北", "bei3")],
            "京": [character("京", "jing1")],
        ])
        let readingResult = try ReadingComposer.reading(for: "北京", in: stub)
        let reading = try #require(readingResult)
        #expect(reading.display == "běijīng")
        #expect(reading.source == .composed)
    }

    /// Composition goes through `PinyinToken` rather than joining the stored
    /// display strings, so the apostrophe rule applies across the join.
    /// Concatenating `Xī` and `ān` gives `Xīān`, which reads as a different
    /// word.
    @Test("An apostrophe is inserted where the syllables would run together")
    func apostropheAcrossTheJoin() throws {
        let stub = StubDictionary(characters: [
            "西": [character("西", "Xi1")],
            "安": [character("安", "an1")],
        ])
        let readingResult = try ReadingComposer.reading(for: "西安", in: stub)
        let reading = try #require(readingResult)
        #expect(reading.display == "Xī'ān")
    }

    /// All or nothing. Pinyin over two characters of three looks like a
    /// rendering fault rather than like missing data, and the reader cannot
    /// tell which part is absent.
    @Test("A word with one unknown character gets no reading")
    func partialCompositionIsRefused() throws {
        let stub = StubDictionary(characters: ["北": [character("北", "bei3")]])
        #expect(try ReadingComposer.reading(for: "北京", in: stub) == nil as TokenReading?)
    }

    @Test("Composition is only attempted for Han text", arguments: ["iPhone", "2026", "", "， "])
    func onlyHanComposes(word: String) throws {
        let stub = StubDictionary(characters: ["北": [character("北", "bei3")]])
        #expect(try ReadingComposer.reading(for: word, in: stub) == nil as TokenReading?)
    }

    @Test("A character whose reading will not parse is treated as unknown")
    func unparseableCharacterReading() throws {
        let stub = StubDictionary(characters: ["〇": [character("〇", "")]])
        #expect(try ReadingComposer.reading(for: "〇", in: stub) == nil as TokenReading?)
    }

    @Test("The best-ranked reading is used for each character")
    func usesTheBestRankedReading() throws {
        let stub = StubDictionary(characters: ["长": [
            character("长", "chang2"),
            character("长", "zhang3"),
        ]])
        let readingResult = try ReadingComposer.reading(for: "长", in: stub)
        let reading = try #require(readingResult)
        #expect(reading.display == "cháng")
    }

    // MARK: - Failure

    @Test("A lookup failure propagates rather than becoming a wrong answer")
    func failuresPropagate() {
        let stub = StubDictionary(
            characters: ["中": [character("中", "zhong1")]],
            failsOn: "中",
        )
        #expect(throws: StubError.self) {
            try ReadingComposer.reading(for: "中", in: stub)
        }
    }
}
