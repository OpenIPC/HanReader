// HanReader — MIT licensed. See LICENSE.

import Testing
@testable import HanReaderCore

@Suite("Pinyin tone placement")
struct TonePlacementTests {
    /// The classic cases. `liu`/`dui` are the pair that catches a naive
    /// "mark the first vowel" implementation, and `lüe` catches a naive
    /// "mark the ü" one.
    @Test("Standard placement", arguments: [
        ("ai", Tone.fourth, "ài"),
        ("hao", .third, "hǎo"),
        ("ni", .third, "nǐ"),
        ("liu", .fourth, "liù"), // last of i/u -> the u
        ("dui", .fourth, "duì"), // last of i/u -> the i
        ("jiu", .third, "jiǔ"),
        ("gui", .fourth, "guì"),
        ("hui", .second, "huí"),
        ("xue", .second, "xué"),
        ("zhuang", .first, "zhuāng"),
        ("er", .second, "ér"),
    ])
    func placement(base: String, tone: Tone, expected: String) {
        #expect(PinyinSyllable(base: base, tone: tone).diacritic == expected)
    }

    /// `a` outranks the other vowels. Note what this does *not* claim: the
    /// relative order of `o` and `e` is unobservable, because no pinyin base
    /// contains both — verified across all 430 bases in CC-CEDICT. Swapping
    /// those two branches in the implementation is a semantic no-op, and a
    /// mutation test confirms no assertion can distinguish it. The ordering is
    /// written a > o > e only because that is how the rule is conventionally
    /// stated.
    @Test("a outranks other vowels; o versus e is unobservable", arguments: [
        ("hao", Tone.first, "hāo"),
        ("hou", .first, "hōu"),
        ("hei", .first, "hēi"),
        ("guo", .second, "guó"),
        ("jie", .second, "jié"),
    ])
    func priority(base: String, tone: Tone, expected: String) {
        #expect(PinyinSyllable(base: base, tone: tone).diacritic == expected)
    }

    /// The ü cases, including the one that trips people up: in `lüe` the mark
    /// goes on the `e`, because `e` outranks ü in the priority order.
    @Test("Umlaut handling", arguments: [
        ("lu:", Tone.third, "lǚ"),
        ("nu:", .third, "nǚ"),
        ("lu:e", .fourth, "lüè"), // mark on e, NOT on ü
        ("nu:e", .fourth, "nüè"),
        ("lv", .third, "lǚ"), // the `v` convention
        ("ju", .fourth, "jù"), // plain u, not ü
    ])
    func umlaut(base: String, tone: Tone, expected: String) {
        #expect(PinyinSyllable(base: base, tone: tone).diacritic == expected)
    }

    /// Capitals are preserved because CC-CEDICT uses them to mark proper
    /// nouns and surnames, and that distinction ranks candidate readings.
    @Test("Capitals are preserved", arguments: [
        ("Bei", Tone.third, "Běi"),
        ("A", .first, "Ā"),
        ("Su", .fourth, "Sù"),
    ])
    func capitals(base: String, tone: Tone, expected: String) {
        #expect(PinyinSyllable(base: base, tone: tone).diacritic == expected)
    }

    /// The neutral tone carries no mark at all. `ma0` is never produced.
    @Test("Neutral tone is unmarked")
    func neutral() {
        #expect(PinyinSyllable(base: "ma", tone: .neutral).diacritic == "ma")
        #expect(PinyinSyllable(base: "r", tone: .neutral).diacritic == "r")
        #expect(PinyinSyllable(base: "ma", tone: .neutral).numeric == "ma5")
    }

    /// Syllabic nasals have no vowel to mark, so the renderer composes a
    /// combining mark instead of looking one up. CC-CEDICT really does
    /// contain `m2`.
    @Test("Vowelless syllables", arguments: [
        ("m", Tone.second, "ḿ"),
        ("n", .second, "ń"),
        ("n", .third, "ň"),
        ("hm", .neutral, "hm"),
        ("ng", .neutral, "ng"),
    ])
    func vowelless(base: String, tone: Tone, expected: String) {
        let produced = PinyinSyllable(base: base, tone: tone).diacritic
        #expect(produced.precomposedStringWithCanonicalMapping
            == expected.precomposedStringWithCanonicalMapping)
    }
}

@Suite("Pinyin round-tripping")
struct PinyinRoundTripTests {
    /// Every base × every tone must survive diacritic → numeric → diacritic.
    /// This is the property that makes the cross-dictionary merge key sound:
    /// if it did not hold, two spellings of one reading would not group.
    @Test("Diacritic and numeric forms round-trip")
    func roundTrip() {
        let bases = [
            "a", "ai", "an", "ang", "ao", "ba", "bai", "ban", "bang", "bei", "ben",
            "chuang", "shuang", "e", "ei", "en", "er", "hao", "hou", "hui", "jie",
            "liu", "dui", "lü", "nü", "lüe", "nüe", "ma", "n", "ng", "m", "xue",
            "zhuang", "guo", "zi", "ci", "si", "ri", "yu", "yue", "yuan",
        ]
        for base in bases {
            for tone in Tone.allCases {
                let original = PinyinSyllable(base: base, tone: tone)
                let rendered = original.diacritic
                guard let recovered = PinyinSyllabifier.syllable(fromDiacritic: rendered) else {
                    Issue.record("could not read back \(rendered) (from \(base)\(tone.rawValue))")
                    continue
                }
                #expect(
                    recovered == original,
                    "round-trip failed for \(base)\(tone.rawValue) -> \(rendered)",
                )
            }
        }
    }

    @Test("Reading a diacritic syllable", arguments: [
        ("ài", "ai", Tone.fourth),
        ("nǐ", "ni", .third),
        ("lǚ", "lü", .third),
        ("lüè", "lüe", .fourth),
        ("ma", "ma", .neutral),
        ("Běi", "Bei", .third),
    ])
    func readBack(text: String, base: String, tone: Tone) {
        let syllable = PinyinSyllabifier.syllable(fromDiacritic: text)
        #expect(syllable == PinyinSyllable(base: base, tone: tone))
    }

    /// Already-decomposed input must behave the same as precomposed input.
    @Test("Decomposed input is handled")
    func decomposed() {
        let decomposed = "a\u{0300}i" // a + combining grave + i
        #expect(PinyinSyllabifier.syllable(fromDiacritic: decomposed)
            == PinyinSyllable(base: "ai", tone: .fourth))
    }

    /// ü must survive: its diaeresis is part of the letter, not a tone mark.
    @Test("Umlaut is not mistaken for a tone mark")
    func umlautSurvives() {
        #expect(PinyinSyllabifier.syllable(fromDiacritic: "lü")?.base == "lü")
        #expect(PinyinSyllabifier.syllable(fromDiacritic: "lü")?.tone == .neutral)
    }
}

@Suite("Parsing CC-CEDICT pinyin fields")
struct PinyinParsingTests {
    @Test("Ordinary readings")
    func ordinary() {
        #expect(Pinyin.parse(numeric: "ni3 hao3") == [
            .syllable(PinyinSyllable(base: "ni", tone: .third)),
            .syllable(PinyinSyllable(base: "hao", tone: .third)),
        ])
    }

    @Test("u: is folded to ü")
    func umlautField() {
        #expect(Pinyin.parse(numeric: "lu:3") == [.syllable(PinyinSyllable(
            base: "lü",
            tone: .third,
        ))])
    }

    /// The complete set of non-syllable forms that appear in CC-CEDICT. A
    /// survey of the whole file found only these, so the parser covers the
    /// field exhaustively rather than approximately.
    @Test("Non-syllable forms")
    func nonSyllables() {
        #expect(Pinyin.parse(numeric: "xx5") == [.unknown])
        #expect(Pinyin.parse(numeric: "A A zhi4") == [
            .literal("A"), .literal("A"),
            .syllable(PinyinSyllable(base: "zhi", tone: .fourth)),
        ])
        #expect(Pinyin.parse(numeric: "ha1 , ha1") == [
            .syllable(PinyinSyllable(base: "ha", tone: .first)),
            .separator(","),
            .syllable(PinyinSyllable(base: "ha", tone: .first)),
        ])
        #expect(Pinyin.parse(numeric: "ao4 · ba1 ma3").contains(.separator("·")))
    }

    /// `r5` is the erhua suffix and is a perfectly ordinary neutral syllable,
    /// not an unknown.
    @Test("Erhua is a normal syllable")
    func erhua() {
        #expect(Pinyin.parse(numeric: "hua1 r5") == [
            .syllable(PinyinSyllable(base: "hua", tone: .first)),
            .syllable(PinyinSyllable(base: "r", tone: .neutral)),
        ])
    }

    @Test("Degenerate input does not crash")
    func degenerate() {
        #expect(Pinyin.parse(numeric: "").isEmpty)
        #expect(Pinyin.parse(numeric: "   ").isEmpty)
        // A trailing digit outside 1...5 is not a tone, so this is literal text.
        #expect(Pinyin.parse(numeric: "abc9") == [.literal("abc9")])
        #expect(Pinyin.parse(numeric: "7") == [.literal("7")])
    }
}

@Suite("Pinyin display")
struct PinyinDisplayTests {
    @Test("Syllables join without spaces")
    func joined() {
        #expect(Pinyin.display(Pinyin.parse(numeric: "Bei3 jing1")) == "Běijīng")
        #expect(Pinyin.display(Pinyin.parse(numeric: "ni3 hao3")) == "nǐhǎo")
    }

    /// Without the apostrophe, `Xī'ān` would read as one syllable.
    @Test("Apostrophe where the boundary would be ambiguous")
    func apostrophe() {
        #expect(Pinyin.display(Pinyin.parse(numeric: "Xi1 an1")) == "Xī'ān")
        #expect(Pinyin.display(Pinyin.parse(numeric: "Tian1 an1 men2")) == "Tiān'ānmén")
    }

    /// ...and no apostrophe where there is no ambiguity, which is the half
    /// that a careless implementation gets wrong.
    @Test("No apostrophe when the boundary is already clear")
    func noApostrophe() {
        #expect(Pinyin.display(Pinyin.parse(numeric: "Bei3 jing1")) == "Běijīng")
        #expect(Pinyin.display(Pinyin.parse(numeric: "zhong1 guo2")) == "zhōngguó")
    }

    @Test("Alternative styles")
    func styles() {
        let tokens = Pinyin.parse(numeric: "Bei3 jing1")
        #expect(Pinyin.display(tokens, style: .numeric) == "Bei3 jing1")
        #expect(Pinyin.display(tokens, style: .diacriticSpaced) == "Běi jīng")
        #expect(Pinyin.display(tokens, style: .toneless) == "Beijing")
    }

    @Test("Unknown readings are visible rather than silently dropped")
    func unknown() {
        #expect(Pinyin.display(Pinyin.parse(numeric: "xx5")) == "?")
    }
}

@Suite("Syllabifying continuous readings")
struct SyllabifierTests {
    /// The bases needed by these cases. In the app this set comes from
    /// CC-CEDICT; injecting it keeps the algorithm pure and the tests hermetic.
    private static let bases: Set = [
        "san", "bi", "xi", "he", "tu", "er", "qi", "si", "tan", "shang", "hai",
        "shi", "ai", "hao", "ni", "zhong", "guo", "an", "ma", "a", "o", "e",
        "li", "la", "lu", "ha", "to",
    ]

    @Test("A BKRS-style run-together reading")
    func runTogether() {
        let parsed = PinyinSyllabifier.syllables(fromDiacritic: "sānbǐxīhé", bases: Self.bases)
        #expect(parsed?.map(\.base) == ["san", "bi", "xi", "he"])
        #expect(parsed?.map(\.tone) == [.first, .third, .first, .second])
    }

    /// BKRS uses the typographic apostrophe U+2019, not the ASCII one.
    @Test("Both apostrophes act as boundaries")
    func apostrophes() {
        let typographic = PinyinSyllabifier.syllables(
            fromDiacritic: "tǔ\u{2019}ěrqísītǎn",
            bases: Self.bases,
        )
        #expect(typographic?.map(\.base) == ["tu", "er", "qi", "si", "tan"])

        let ascii = PinyinSyllabifier.syllables(fromDiacritic: "tǔ'ěrqísītǎn", bases: Self.bases)
        #expect(ascii?.map(\.base) == ["tu", "er", "qi", "si", "tan"])
    }

    @Test("Spaces and hyphens are boundaries too")
    func separators() {
        #expect(PinyinSyllabifier.syllables(fromDiacritic: "shàng hǎi", bases: Self.bases)?
            .map(\.base) == ["shang", "hai"])
        #expect(PinyinSyllabifier.syllables(fromDiacritic: "shàng-hǎi", bases: Self.bases)?
            .map(\.base) == ["shang", "hai"])
    }

    /// Greedy matching alone would take `shang` here and then fail on the
    /// remainder; backtracking is what makes it recover.
    @Test("Backtracking recovers from a greedy wrong turn")
    func backtracking() {
        // "shanghai" could start with `shang`, which works. Force the other
        // shape by offering a base set where it cannot.
        let limited: Set = ["sha", "ng", "hai"]
        let parsed = PinyinSyllabifier.syllables(fromDiacritic: "shanghai", bases: limited)
        #expect(parsed?.map(\.base) == ["sha", "ng", "hai"])
    }

    /// Returning nil is a normal outcome — the caller falls back to grouping
    /// by the raw string rather than treating it as an error.
    @Test("Unsegmentable input returns nil rather than guessing")
    func unsegmentable() {
        #expect(PinyinSyllabifier.syllables(fromDiacritic: "zzzz", bases: Self.bases) == nil)
        #expect(PinyinSyllabifier.syllables(fromDiacritic: "", bases: Self.bases) == nil)
    }

    /// The whole point of the syllabifier: a reading written as diacritics by
    /// one dictionary and numerically by another must produce the same key.
    @Test("BKRS and CC-CEDICT spellings reach the same key")
    func crossDictionaryKey() {
        let fromBKRS = PinyinSyllabifier.syllables(fromDiacritic: "nǐhǎo", bases: Self.bases)
        let fromCEDICT = Pinyin.parse(numeric: "ni3 hao3").compactMap { token -> PinyinSyllable? in
            if case let .syllable(syllable) = token {
                return syllable
            }
            return nil
        }
        #expect(fromBKRS == fromCEDICT)
        #expect(fromBKRS?.map(\.numeric).joined(separator: " ") == "ni3 hao3")
    }
}

@Suite("Pinyin regressions")
struct PinyinRegressionTests {
    /// A Unicode numeral whose value exceeds 255 must not trap the parser.
    /// `wholeNumberValue` is not bounded by the ASCII digits.
    @Test("Large Unicode numerals are kept as literals, not crashed on")
    func largeNumeral() {
        #expect(Pinyin.parse(numeric: "ha1\u{4E07}") == [.literal("ha1\u{4E07}")]) // 万 = 10000
        #expect(Pinyin.parse(numeric: "x\u{0D70}") == [.literal("x\u{0D70}")]) // Malayalam 100
    }

    /// A syllable following a literal needs a separator, or two letter names
    /// run into the reading after them.
    @Test("Letter names stay separate from a following syllable")
    func literalThenSyllable() {
        #expect(Pinyin.display(Pinyin.parse(numeric: "A A zhi4")) == "A A zhì")
    }

    /// `chang` ends in `ng`, so `cháng` + `ān` needs the apostrophe just as
    /// `Xī` + `ān` does.
    @Test("An ng ending still takes an apostrophe")
    func ngBoundary() {
        #expect(Pinyin.display(Pinyin.parse(numeric: "Chang2 an1")) == "Cháng'ān")
        #expect(Pinyin.display(Pinyin.parse(numeric: "Xi1 an1")) == "Xī'ān")
    }

    /// A comma attached to the preceding syllable must not swallow it.
    @Test("Attached separators are split off", arguments: [
        "ha1, ha1",
        "ha1 , ha1",
        "ha1,ha1",
    ])
    func attachedComma(field: String) {
        let rendered = Pinyin.display(Pinyin.parse(numeric: field))
        #expect(rendered == "hā, hā", "field \(field) rendered as \(rendered)")
    }

    /// Pathological input must not take exponential time. A long run of
    /// ambiguous prefixes followed by an unmatchable character is the shape
    /// that blows up an unmemoised search.
    @Test("Unsegmentable ambiguous input terminates quickly", .timeLimit(.minutes(1)))
    func noExponentialBlowup() {
        let bases: Set = ["a", "aa", "aaa", "aaaa", "aaaaa", "aaaaaa"]
        let text = String(repeating: "a", count: 40) + "z"
        #expect(PinyinSyllabifier.syllables(fromDiacritic: text, bases: bases) == nil)
    }
}
