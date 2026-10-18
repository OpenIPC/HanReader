// HanReader — MIT licensed. See LICENSE.

import Testing
@testable import HanReaderCore

/// A dictionary written out by hand, so a test about which reading wins says
/// which entries exist rather than building a SQLite container to ask.
private struct StubDictionary: DictionaryLookup {
    var words: [String: [DictionaryEntry]] = [:]

    func entries(for headword: String) throws -> [DictionaryEntry] {
        words[headword] ?? []
    }

    func readings(forCharacter character: Character) throws -> [CharacterReading] {
        []
    }
}

private func entry(
    _ simplified: String,
    traditional: String? = nil,
    _ numeric: String,
    senses: Int = 1,
)
    -> DictionaryEntry
{
    DictionaryEntry(
        headword: Headword(simplified: simplified, traditional: traditional),
        reading: Pinyin.parse(numeric: numeric),
        senses: (0 ..< senses).map {
            Sense(id: $0, kind: .definition, gloss: Gloss(text: "sense \($0)"))
        },
    )
}

/// The real CC-CEDICT shape for 重, sense counts included, because the sense
/// counts are the whole reason the context-free rule gets it wrong:
/// `chóng` has five senses and `zhòng` three.
private let heavyOrRepeat = [
    entry("重", "chong2", senses: 5),
    entry("重", "zhong4", senses: 3),
]

/// 长 as CC-CEDICT holds it: `zhǎng` has seven senses to `cháng`'s five.
private let longOrChief = [
    entry("长", traditional: "長", "chang2", senses: 5),
    entry("长", traditional: "長", "zhang3", senses: 7),
]

private func tokens(_ words: [String], kinds: [TokenKind]? = nil) -> [Token] {
    var offset = 0
    return words.enumerated().map { index, word in
        let length = word.utf16.count
        defer { offset += length }
        return Token(
            id: TokenID(block: 0, index: index),
            text: word,
            range: offset ..< offset + length,
            kind: kinds?[index] ?? .han,
        )
    }
}

@Suite("Reading context")
struct ReadingContextTests {
    // MARK: - The reported defect

    /// The bug this whole mechanism exists for. 我在一个山村学校当老师，教学任务很重
    /// segments to `… | 任务 | 很 | 重`, so 重 is a lone token, and the
    /// context-free ranking annotated it `chóng` ("to repeat") because
    /// CC-CEDICT says more about that reading than about `zhòng` ("heavy").
    @Test("A degree adverb makes 很重 zhòng, not chóng")
    func degreeAdverbPicksTheStativeReading() {
        let context = ReadingContext(precedingWord: "很")
        let reading = ReadingComposer.reading(from: heavyOrRepeat, context: context)
        #expect(reading?.display == "zhòng")
    }

    /// The other half of the same claim, and the reason a context-free
    /// default could never have fixed it: standing alone, 重 keeps whatever
    /// the ranking says. The rule adds knowledge, it does not replace one
    /// blanket default with another.
    @Test("Without a degree adverb the ranking is untouched")
    func noContextLeavesTheRankingAlone() {
        let reading = ReadingComposer.reading(from: heavyOrRepeat)
        #expect(reading?.display == "chóng")
        #expect(ReadingComposer.reading(from: heavyOrRepeat, context: .none)?.display == "chóng")
    }

    @Test(
        "Every degree adverb in the class picks the stative reading",
        arguments: ["很", "太", "挺", "最", "更", "真", "好", "非常", "比较", "有点", "越来越"],
    )
    func everyDegreeAdverbApplies(adverb: String) {
        let context = ReadingContext(precedingWord: adverb)
        #expect(ReadingComposer.reading(from: heavyOrRepeat, context: context)?.display == "zhòng")
    }

    /// 任务不重 is "the task is not heavy". A negator is a weaker signal than
    /// a degree adverb and is kept to the characters where both readings it
    /// admits point the same way.
    @Test("A negator makes 不重 zhòng")
    func negatorPicksTheStativeReading() {
        let context = ReadingContext(precedingWord: "不")
        #expect(context.preceding == .negator)
        #expect(ReadingComposer.reading(from: heavyOrRepeat, context: context)?.display == "zhòng")
    }

    /// The two classes are not interchangeable, and this is what keeps them
    /// apart: 待我不薄 is `bó` and 不长 can be "does not grow", so a negator
    /// must not reach the characters a degree adverb does.
    @Test("A negator does not settle 长, where a degree adverb does")
    func negatorIsNarrowerThanDegreeAdverb() {
        #expect(ReadingComposer.reading(
            from: longOrChief,
            context: ReadingContext(precedingWord: "不"),
        )?.display == "zhǎng")
        #expect(ReadingComposer.reading(
            from: longOrChief,
            context: ReadingContext(precedingWord: "很"),
        )?.display == "cháng")
    }

    /// 没 negates aspect rather than a predicate, and 没重 is not something
    /// anyone says — so it is not a negator for this purpose.
    @Test("没 is not treated as a negator")
    func aspectualNegatorIsExcluded() {
        #expect(FunctionWordClass(word: "没") == nil)
    }

    @Test("A degree adverb makes 很长 cháng, not zhǎng")
    func longIsNotChief() {
        let context = ReadingContext(precedingWord: "很")
        #expect(ReadingComposer.reading(from: longOrChief, context: context)?.display == "cháng")
        #expect(ReadingComposer.reading(from: longOrChief)?.display == "zhǎng")
    }

    /// A traditional text says 很長, and the token matched is 長. The rule has
    /// to reach it, or the fix works in one script only.
    /// An entry carrying only the simplified form, so the traditional line in
    /// the table cannot cover for it. Both spellings are listed there and
    /// each has to work alone, or the table silently depends on every
    /// dictionary recording both scripts.
    @Test("The rule reaches a simplified-only entry")
    func simplifiedOnlyEntryIsCovered() {
        let simplifiedOnly = [
            entry("长", "chang2", senses: 5),
            entry("长", "zhang3", senses: 7),
        ]
        let context = ReadingContext(precedingWord: "很")
        #expect(
            ReadingComposer.reading(from: simplifiedOnly, context: context)?.display == "cháng",
        )
    }

    @Test("The rule reaches the traditional spelling")
    func traditionalScriptIsCovered() {
        let traditionalOnly = [
            entry("長", "chang2", senses: 5),
            entry("長", "zhang3", senses: 7),
        ]
        let context = ReadingContext(precedingWord: "很")
        #expect(
            ReadingComposer.reading(from: traditionalOnly, context: context)?.display == "cháng",
        )
    }

    // MARK: - What the rule must not do

    /// 重复 is `chóngfù` and nothing here may interfere: a multi-character
    /// word's reading comes from its own entry, where the dictionary has
    /// already settled which reading of each character applies.
    @Test("A multi-character word is never overridden")
    func multiCharacterWordsAreLeftAlone() {
        let entries = [entry("重复", "chong2 fu4", senses: 4)]
        let context = ReadingContext(precedingWord: "很")
        #expect(ReadingComposer.reading(from: entries, context: context)?.display == "chóngfù")
        // Asserted on the rule itself as well as on the outcome. A rule that
        // matched 重复 on its first character would be caught by nothing
        // downstream: the reading it names is one syllable and a two-syllable
        // word can never equal it, so the bug would sit there silently until
        // some two-character headword turned up with a one-syllable reading.
        #expect(HeteronymRules.preferredReading(
            for: Headword(simplified: "重复", traditional: nil),
            in: context,
        ) == nil)
    }

    /// A dictionary that simply has no `zhòng` entry must still annotate the
    /// word. Falling through to the context-free answer is right; annotating
    /// nothing because a rule could not be satisfied is not.
    @Test("A rule the dictionary cannot satisfy falls through")
    func unsatisfiableRuleFallsThrough() {
        let entries = [entry("重", "chong2", senses: 5)]
        let context = ReadingContext(precedingWord: "很")
        #expect(ReadingComposer.reading(from: entries, context: context)?.display == "chóng")
    }

    /// Still a guess, and still drawn faintly. A grammatical constraint makes
    /// the choice defensible, not certain — the reader should see that the
    /// dictionary holds more than one reading and be able to check the panel.
    @Test("A context-chosen reading is still marked as a guess")
    func contextDoesNotClaimCertainty() {
        let context = ReadingContext(precedingWord: "很")
        let reading = ReadingComposer.reading(from: heavyOrRepeat, context: context)
        #expect(reading?.source == .ambiguous)
    }

    /// Characters the context-free ranking already gets right, listed so that
    /// a change to that ranking fails here instead of quietly creating the
    /// need for more rules. None of these appears in `HeteronymRules`.
    @Test(
        "Characters needing no rule stay correct without one",
        arguments: [
            ("好", ["hao3", "hao4"], "hǎo"),
            ("难", ["nan2", "nan4"], "nán"),
            ("累", ["lei4", "lei3", "lei2"], "lèi"),
            ("大", ["da4", "dai4"], "dà"),
            ("少", ["shao3", "shao4"], "shǎo"),
        ],
    )
    func unruledCharactersAreAlreadyRight(
        word: String,
        readings: [String],
        expected: String,
    ) {
        // Sense counts descending, which is the shape that made 重 fail: the
        // first reading listed is the one the ranking would pick on count
        // alone.
        let entries = readings.enumerated().map {
            entry(word, $1, senses: readings.count - $0)
        }
        let context = ReadingContext(precedingWord: "很")
        #expect(HeteronymRules.preferredReading(
            for: Headword(simplified: word, traditional: nil),
            in: context,
        ) == nil)
        #expect(ReadingComposer.reading(from: entries, context: context)?.display == expected)
    }

    // MARK: - Classifying neighbours

    @Test("Punctuation severs the relation")
    func punctuationSevers() {
        let stream = tokens(["很", "，", "重"], kinds: [.han, .punctuation, .han])
        let contexts = ReadingContext.contexts(in: stream)
        #expect(contexts[2] == .none)
        // Both classifiers, because a tap uses the other one and the reader
        // would see the panel disagree with the ruby above the word.
        #expect(ReadingContext.context(at: 2, in: stream) == .none)
        #expect(ReadingComposer.reading(from: heavyOrRepeat, context: contexts[2])?
            .display == "chóng")
    }

    /// `很 重` with a space between is still a degree adverb modifying 重 —
    /// which matters because a reader's text may have spaces anywhere.
    @Test("Whitespace does not sever the relation")
    func whitespaceDoesNotSever() {
        let stream = tokens(["很", " ", "重"], kinds: [.han, .whitespace, .han])
        let contexts = ReadingContext.contexts(in: stream)
        #expect(contexts[2].preceding == .degreeAdverb)
    }

    @Test("The first token of a block has no context")
    func blockStartHasNoContext() {
        #expect(ReadingContext.contexts(in: tokens(["重", "要"]))[0] == .none)
    }

    @Test("A context is produced for every token")
    func contextsAlignWithTokens() {
        let stream = tokens(["任务", "很", "重"])
        #expect(ReadingContext.contexts(in: stream).count == stream.count)
    }

    /// Two implementations of the same question — one walking a paragraph
    /// forwards for the model, one scanning backwards from an index for a tap
    /// — and they must never disagree. They did not start out agreeing: a
    /// divergence shows up as the panel naming a different reading from the
    /// ruby directly above the word.
    @Test("The single-token and whole-block classifiers agree")
    func theTwoClassifiersAgree() {
        // 很 sits immediately before a comma, so a classifier that skipped
        // punctuation would carry the adverb across it and the two would
        // disagree about 重. Without that shape the streams agree whatever
        // either one does with punctuation.
        let stream = tokens(
            ["他", "说", "很", "，", "重", " ", "很", "重", "。"],
            kinds: [
                .han, .han, .han, .punctuation, .han, .whitespace, .han, .han, .punctuation,
            ],
        )
        let all = ReadingContext.contexts(in: stream)
        for index in stream.indices {
            #expect(ReadingContext.context(at: index, in: stream) == all[index])
        }
    }

    @Test("An index outside the block has no context")
    func outOfRangeIndexIsSafe() {
        let stream = tokens(["重"])
        #expect(ReadingContext.context(at: 5, in: stream) == .none)
        #expect(ReadingContext.context(at: -1, in: stream) == .none)
    }

    @Test("An ordinary word is in no function-word class")
    func ordinaryWordsAreUnclassified() {
        #expect(FunctionWordClass(word: "任务") == nil)
        #expect(FunctionWordClass(word: "重") == nil)
        #expect(FunctionWordClass(word: "很") == .degreeAdverb)
    }

    // MARK: - Through the lookup

    /// The whole path, as the reader meets it: the words of the sentence, the
    /// dictionary, and the annotation that comes out.
    @Test("The reported sentence annotates 重 as zhòng")
    func theReportedSentenceIsFixed() throws {
        let stub = StubDictionary(words: ["重": heavyOrRepeat, "很": [entry("很", "hen3")]])
        let stream = tokens(["任务", "很", "重"])
        let contexts = ReadingContext.contexts(in: stream)

        let reading = try ReadingComposer.reading(for: "重", in: stub, context: contexts[2])
        #expect(reading?.display == "zhòng")

        // And unchanged where there is no adverb, in the same sentence.
        let bare = try ReadingComposer.reading(for: "重", in: stub, context: contexts[0])
        #expect(bare?.display == "chóng")
    }
}
