// HanReader — MIT licensed. See LICENSE.

import Testing
@testable import HanReaderCore

/// Readings for the handful of characters these tests use, written out so a
/// test about scoring does not depend on which dictionaries happen to be
/// installed. The values are CC-CEDICT's.
private let readings: [Character: [String]] = [
    "真": ["zhen1"], "针": ["zhen1"],
    "是": ["shi4"], "时": ["shi2"], "事": ["shi4"],
    "重": ["chong2", "zhong4"],
    "价": ["jia4"], "假": ["jia3", "jia4"],
    "山": ["shan1"], "村": ["cun1"], "的": ["de5", "di2", "di4"],
    "年": ["nian2", "Nian2"],
    "黏": ["nian2"],
    // 佟 is a surname and CC-CEDICT spells it capitalised, with no other
    // reading at all — so this pair is the one that actually depends on
    // comparing readings case-insensitively.
    "佟": ["Tong2"], "同": ["tong2"],
    "猫": ["mao1"], "狗": ["gou3"],
]

private func lookup(_ character: Character) -> [CharacterReading] {
    (readings[character] ?? []).enumerated().map { rank, numeric in
        CharacterReading(character: character, numeric: numeric, display: numeric, rank: rank)
    }
}

private func check(_ typed: String, _ expected: String) -> DictationResult {
    DictationComparison.check(typed: typed, against: expected, readings: lookup)
}

@Suite("Dictation checking")
struct DictationComparisonTests {
    // MARK: - Scoring

    @Test("A perfect attempt scores one")
    func perfect() {
        let result = check("山村的孩子需要他", "山村的孩子需要他")
        #expect(result.isPerfect)
        #expect(result.accuracy == 1)
        #expect(result.correct == 8)
        #expect(result.expected == 8)
    }

    /// Punctuation is a transcription convention, not evidence about anyone's
    /// ears — and a Chinese IME inserts it for the learner anyway, so scoring
    /// it would mark some people down for their keyboard.
    @Test(
        "Punctuation and spacing are ignored on both sides",
        arguments: [
            ("山村的孩子需要他", "山村的孩子需要他。"),
            ("山村的孩子需要他。", "山村的孩子需要他"),
            ("山村的孩子,需要他!", "山村的孩子需要他。"),
            ("山 村 的 孩 子 需 要 他", "山村的孩子需要他。"),
        ],
    )
    func punctuationIgnored(typed: String, expected: String) {
        let result = check(typed, expected)
        #expect(result.isPerfect)
        #expect(result.accuracy == 1)
    }

    @Test("An empty attempt scores zero and marks everything missing")
    func emptyAttempt() {
        let result = check("", "山村的孩子")
        #expect(result.accuracy == 0)
        #expect(result.count(of: .missing) == 5)
        #expect(result.marks.count == 5)
    }

    /// Nothing expected and nothing typed is a phrase with nothing to get
    /// wrong. Nothing expected but something typed is simply wrong, and
    /// saying so beats dividing by zero and calling it full marks.
    @Test("An empty phrase scores one, but not if something was typed into it")
    func emptyPhrase() {
        let result = check("", "")
        #expect(result.accuracy == 1)
        #expect(result.isPerfect)
        #expect(check("多余", "").accuracy == 0)
    }

    /// Review finding: dividing matches by the *expected* length alone left
    /// invented characters free. Typing the phrase correctly and then adding
    /// nonsense scored one, and passed.
    @Test("Invented characters bring the score down")
    func extrasAreScored() {
        let perfect = check("山村的孩子", "山村的孩子")
        #expect(perfect.accuracy == 1)

        let padded = check("山村的孩子猫狗猫", "山村的孩子")
        #expect(padded.count(of: .extra) == 3)
        #expect(padded.accuracy < 1)
        // Five right out of five expected plus three invented.
        #expect(abs(padded.accuracy - 5.0 / 8.0) < 0.000_1)
        #expect(!padded.isPerfect)
    }

    /// Review finding: the passing contract says a homophone is acceptable
    /// because the learner heard the phrase, but the strict score counts
    /// only exact matches — so such an attempt could never reach the default
    /// threshold. Two scores, and the one that gates drilling is the one
    /// that measures listening.
    @Test("A homophone slip is heard, even though it is not correct")
    func listeningAccuracyForgivesHomophones() {
        // 真 for 针: both zhen1.
        let result = check("真是", "针是")
        #expect(result.accuracy == 0.5)
        #expect(result.listeningAccuracy == 1)
        #expect(!result.isPerfect)
    }

    /// But a tone slip is not forgiven. Tones are what an ear loses first,
    /// and they are what this exercise is most useful for.
    @Test("A tone slip is not counted as heard")
    func listeningAccuracyKeepsToneSlips() {
        // 是 shi4 for 时 shi2.
        let result = check("是重", "时重")
        #expect(result.accuracy == 0.5)
        #expect(result.listeningAccuracy == 0.5)
    }

    @Test("Invented characters count against the listening score too")
    func listeningAccuracyScoresExtras() {
        let result = check("针猫狗", "针")
        #expect(result.listeningAccuracy < 1)
        #expect(result.scale == 3)
    }

    @Test("Accuracy counts matched characters over expected characters")
    func accuracyArithmetic() {
        // Four expected, three right.
        let result = check("山村的狗", "山村的猫")
        #expect(result.correct == 3)
        #expect(result.expected == 4)
        #expect(abs(result.accuracy - 0.75) < 0.000_1)
        #expect(!result.isPerfect)
    }

    // MARK: - The three kinds of wrong

    /// 真 and 针 are both `zhen1`. They heard it correctly and their input
    /// method offered the wrong candidate; calling that a listening mistake
    /// would be a lie about the one thing this exercise measures.
    @Test("A character that sounds identical is a homophone, not a mishearing")
    func homophone() {
        let result = check("真", "针")
        #expect(result.marks.map(\.outcome) == [.homophone])
        #expect(result.correct == 0)
        #expect(result.count(of: .misheard) == 0)
    }

    /// 是 `shi4` for 时 `shi2`: the right syllable, the wrong tone. The most
    /// useful signal in the exercise and the one no general-purpose
    /// dictation tool can give.
    @Test("The right syllable with the wrong tone is a tone slip")
    func toneSlip() {
        let result = check("是", "时")
        #expect(result.marks.map(\.outcome) == [.toneSlip])
    }

    @Test("A character with no reading in common is a mishearing")
    func misheard() {
        let result = check("猫", "狗")
        #expect(result.marks.map(\.outcome) == [.misheard])
    }

    /// A character with several readings is a homophone if *any* of them
    /// match — 假 is `jia3` and `jia4`, and 价 is `jia4`, so a learner typing
    /// 假 for 价 heard it exactly right.
    @Test("Any shared reading is enough to be a homophone")
    func homophoneAcrossMultipleReadings() {
        #expect(check("假", "价").marks.map(\.outcome) == [.homophone])
    }

    /// A surname is written `Nian2` and is the same sound as `nian2`.
    /// Treating those as different readings would call 年/黏 a mishearing,
    /// and for single characters a surname reading is the common case.
    @Test("Capitalisation does not hide a homophone")
    func surnameSpellingIsStillTheSameSound() {
        #expect(check("年", "黏").marks.map(\.outcome) == [.homophone])
        // 佟 is spelled `Tong2` and has no lowercase reading of its own, so
        // this pair fails as a tone slip rather than a homophone unless the
        // comparison folds case.
        #expect(check("佟", "同").marks.map(\.outcome) == [.homophone])
    }

    /// With no dictionary — the state the app is in before one is installed —
    /// everything wrong is simply wrong. Better than claiming a homophone
    /// analysis that was never done.
    @Test("With no readings available every wrong character is a mishearing")
    func noDictionary() {
        let result = DictationComparison.check(typed: "真", against: "针")
        #expect(result.marks.map(\.outcome) == [.misheard])
    }

    // MARK: - Missing and extra

    @Test("A dropped character is missing, not a substitution")
    func dropped() {
        let result = check("山的孩子", "山村的孩子")
        #expect(result.count(of: .missing) == 1)
        #expect(result.correct == 4)
        #expect(result.marks.first { $0.outcome == .missing }?.expected == "村")
    }

    @Test("An invented character is extra and carries no offset")
    func invented() {
        let result = check("山村村的孩子", "山村的孩子")
        #expect(result.count(of: .extra) == 1)
        let extra = result.marks.first { $0.outcome == .extra }
        #expect(extra?.typed == "村")
        #expect(extra?.expected == nil)
        #expect(extra?.offset == nil)
    }

    // MARK: - Offsets

    /// Marks are drawn over the phrase's own text, so each one has to carry
    /// where its character sits — measured in UTF-16, after punctuation has
    /// been skipped but counting the space it occupies.
    @Test("Offsets point into the original text, past skipped punctuation")
    func offsetsSurvivePunctuation() {
        let expected = "山村,的孩子"
        let result = check("山村的孩子", expected)
        let offsets = result.marks.compactMap(\.offset)
        #expect(offsets == [0, 1, 3, 4, 5])

        // And they really do address the right characters.
        let utf16 = Array(expected.utf16)
        for mark in result.marks {
            guard let offset = mark.offset, let expectedCharacter = mark.expected else { continue }
            #expect(String(decoding: [utf16[offset]], as: UTF16.self) == String(expectedCharacter))
        }
    }

    @Test("Offsets are UTF-16, so a surrogate pair shifts what follows")
    func offsetsAreUTF16() {
        let result = check("一𠀋二", "一𠀋二")
        #expect(result.marks.compactMap(\.offset) == [0, 1, 3])
    }

    // MARK: - A whole phrase

    /// The scenario from the plan: 「卖主是位六十多岁的老太太」 typed with a
    /// tone slip, which is what this feature exists to catch.
    @Test("A realistic attempt reports each kind of error separately")
    func realisticAttempt() {
        let expected = "是时重"
        let typed = "事是猫"
        let result = check(typed, expected)
        #expect(result.marks.map(\.outcome) == [.homophone, .toneSlip, .misheard])
        #expect(result.correct == 0)
        #expect(result.count(of: .homophone) == 1)
        #expect(result.count(of: .toneSlip) == 1)
        #expect(result.count(of: .misheard) == 1)
    }

    @Test("Every outcome except correct counts as an error")
    func errorsAreErrors() {
        for outcome in DictationOutcome.allCases {
            #expect(outcome.isError == (outcome != .correct))
        }
    }
}

@Suite("Reading comparison helpers")
struct DictationReadingTests {
    @Test(
        "A numeric reading drops its tone digit to give the syllable",
        arguments: [
            ("zhen1", "zhen"), ("shi4", "shi"), ("de5", "de"),
            ("Nian2", "nian"), ("er", "er"), ("", nil as String?),
        ],
    )
    func syllableBase(numeric: String, expected: String?) {
        #expect(DictationComparison.base(of: numeric) == expected)
    }

    /// A reading that is only a tone digit has no syllable, and must not be
    /// reported as an empty one that matches every other empty one.
    @Test("A degenerate reading has no syllable")
    func degenerateReading() {
        #expect(DictationComparison.base(of: "4") == nil)
    }
}
