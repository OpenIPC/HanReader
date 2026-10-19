// HanReader — MIT licensed. See LICENSE.

import Testing
@testable import HanReaderCore

/// A dictionary written out by hand, so a test about which reading wins says
/// which entries exist rather than building a SQLite container to ask.
private struct StubDictionary: DictionaryLookup {
    var words: [String: [DictionaryEntry]] = [:]
    var characters: [Character: [CharacterReading]] = [:]

    func entries(for headword: String) throws -> [DictionaryEntry] {
        words[headword] ?? []
    }

    func readings(forCharacter character: Character) throws -> [CharacterReading] {
        characters[character] ?? []
    }
}

/// Candidates come out of the container already ranked, so `rank` is the
/// order the composed path would otherwise take them in.
private func character(_ char: Character, _ numeric: String, rank: Int) -> CharacterReading {
    CharacterReading(
        character: char,
        numeric: numeric,
        display: Pinyin.display(Pinyin.parse(numeric: numeric)),
        rank: rank,
    )
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

/// Kept apart from the context rules because it answers a different
/// question. A context rule says which of two live readings this sentence
/// wants; a correction says the dictionary's own evidence is pointing at a
/// reading no living sentence wants.
@Suite("Heteronym corrections")
struct HeteronymCorrectionTests {
    /// 价 as CC-CEDICT holds it. The archaic reading has both a neutral tone
    /// and more senses, so every signal the ranking has points at it.
    private var priceOrGreat: [DictionaryEntry] {
        [
            entry("价", traditional: "價", "jie5", senses: 4),
            entry("价", traditional: "價", "jia4", senses: 3),
        ]
    }

    /// 她叫我给个价 — "name me a price". `jiè` ("great, middleman") is not a
    /// reading of modern Chinese, but it is the one CC-CEDICT says most
    /// about, and it carries a neutral tone on top of that.
    @Test("价 is jià, against both the neutral tone and the sense count")
    func correctedDefaultBeatsTheRanking() {
        #expect(ReadingComposer.reading(from: priceOrGreat)?.display == "jià")
    }

    /// The correction has to hold with no context at all, which is the case
    /// it exists for: unlike 重, there is no neighbour that settles 价 —
    /// there is nothing to settle.
    @Test(
        "价 is jià in every context",
        arguments: [nil, "很", "不", "个", "。"],
    )
    func correctedDefaultIgnoresContext(preceding: String?) {
        let context = ReadingContext(precedingWord: preceding)
        #expect(ReadingComposer.reading(from: priceOrGreat, context: context)?
            .display == "jià")
    }

    @Test(
        "Every generated correction is applied",
        arguments: [
            ("价", "jie5", "jia4", "jià"),
            ("椎", "chui2", "zhui1", "zhuī"),
            ("炮", "bao1", "pao4", "pào"),
            ("络", "lao4", "luo4", "luò"),
            ("膏", "gao4", "gao1", "gāo"),
        ],
    )
    func everyCorrectionApplies(
        word: String,
        wrong: String,
        right: String,
        expected: String,
    ) {
        // The wrong reading given more senses, which is the shape that made
        // the ranking choose it in the first place.
        let entries = [
            entry(word, wrong, senses: 9),
            entry(word, right, senses: 1),
        ]
        #expect(ReadingComposer.reading(from: entries)?.display == expected)
    }

    /// A character with no correction must be left to the ranking, or the
    /// table would be doing the ranking's job everywhere.
    @Test("An ordinary character has no correction")
    func ordinaryCharactersAreUncorrected() {
        #expect(HeteronymRules.defaultReading(
            for: Headword(simplified: "重", traditional: nil),
        ) == nil)
        #expect(HeteronymRules.defaultReading(
            for: Headword(simplified: "价格", traditional: nil),
        ) == nil)
    }

    /// Sentence-final particles are unattested in compounds for a reason
    /// that has nothing to do with being archaic, and the generator excludes
    /// them. If one ever reached the table, 他来了吧 would read `bā`.
    @Test("Particles are not corrected", arguments: ["吧", "呢", "啊", "吗", "了", "的"])
    func particlesAreNotCorrected(particle: String) {
        #expect(HeteronymRules.defaultReading(
            for: Headword(simplified: particle, traditional: nil),
        ) == nil)
    }

    /// A correction the dictionary cannot satisfy must not cost the word its
    /// annotation.
    @Test("A correction the dictionary lacks falls through")
    func unsatisfiableCorrectionFallsThrough() {
        let entries = [entry("价", "jie5", senses: 4)]
        #expect(ReadingComposer.reading(from: entries)?.display == "jie")
    }

    /// The composer tries context first and a correction second, but no
    /// character is in both tables, so that order decides nothing today and
    /// a test asserting it would be asserting an accident.
    ///
    /// This is the test worth having instead: it fails the moment the two
    /// overlap, which is exactly when the order starts to matter and someone
    /// has to decide whether context-first is right for that character.
    @Test("The context and correction tables are disjoint")
    func tablesAreDisjoint() {
        let corrected = Set(HeteronymRules.defaults.keys)
        #expect(!corrected.isEmpty)
        for (functionWord, rules) in HeteronymRules.table {
            let overlap = Set(rules.keys).intersection(corrected)
            #expect(overlap.isEmpty, "\(functionWord) also corrected: \(overlap)")
        }
    }

    /// The per-character table is built by the same sense-count ranking, so
    /// without the correction a word assembled from its characters spelled
    /// 价 `jiè` while the character tapped on its own read `jià` — the same
    /// character, two pronunciations, one screen apart.
    @Test("A word composed from its characters uses the corrected reading")
    func composedReadingIsCorrected() throws {
        let stub = StubDictionary(characters: [
            "价": [character("价", "jie5", rank: 0), character("价", "jia4", rank: 1)],
            "目": [character("目", "mu4", rank: 0)],
        ])
        let reading = try ReadingComposer.composedReading(for: "价目", in: stub)
        #expect(reading?.display == "jiàmù")
    }

    /// And a character with no correction keeps whatever the container
    /// ranked first, or the table would be overriding everywhere.
    @Test("An uncorrected character keeps its ranking in a composed word")
    func composedReadingKeepsTheRanking() throws {
        let stub = StubDictionary(characters: [
            "中": [character("中", "zhong1", rank: 0), character("中", "zhong4", rank: 1)],
            "目": [character("目", "mu4", rank: 0)],
        ])
        let reading = try ReadingComposer.composedReading(for: "中目", in: stub)
        #expect(reading?.display == "zhōngmù")
    }
}
