// HanReader — MIT licensed. See LICENSE.

import Foundation

/// Where a reading came from, and so how much to trust it.
///
/// Three states rather than a boolean, because there are three genuinely
/// different situations and the reader can act on the difference.
public enum ReadingSource: UInt8, Sendable, Hashable, CaseIterable {
    /// The dictionary holds exactly one reading for this word. Trustworthy.
    case dictionary
    /// The dictionary holds several, and one was chosen by rule.
    ///
    /// 了 is `le` and `liǎo`; 为 is `wéi` and `wèi`. Choosing correctly needs
    /// to know how the word is being used, which needs a part-of-speech
    /// tagger — out of scope, and not something a heuristic can fake. The
    /// rule gets the common cases right and will be wrong sometimes, so the
    /// annotation is drawn faintly and the detail panel lists every reading.
    case ambiguous
    /// Assembled from per-character readings because the word itself is not
    /// in the dictionary.
    ///
    /// Necessary rather than optional: **77% of BKRS entries carry no
    /// reading**, so for a reader using the Russian dictionary this is what
    /// annotates most of the page. It is an approximation and it is wrong for
    /// heteronyms, so it too is drawn faintly.
    case composed

    /// Whether this reading is a guess the reader should be able to see is a
    /// guess.
    public var isApproximate: Bool {
        self != .dictionary
    }
}

/// A reading to draw above a word.
public struct TokenReading: Hashable, Sendable {
    /// Pinyin with diacritics, as the reader should see it.
    ///
    /// Dictionary form, never sandhi-adjusted. Sandhi is positional, so
    /// applying it would render the same word differently in different
    /// sentences and defeat the recognition the annotation exists to build.
    /// `AVSpeechSynthesizer` applies its own sandhi, so a displayed `yī`
    /// spoken as `yí` is expected and documented rather than a bug.
    public let display: String

    public let source: ReadingSource

    public init(display: String, source: ReadingSource) {
        self.display = display
        self.source = source
    }
}

/// What a reading composer needs from a dictionary.
///
/// Narrow on purpose, and declared here rather than in the storage layer so
/// that the composition rules can be tested against a handful of entries
/// written in the test — the alternative is building a SQLite container to
/// ask what 了 sounds like.
public protocol DictionaryLookup: Sendable {
    /// Every entry for a headword. A list, not an optional: 和 has eight
    /// entries and 了 has two readings.
    func entries(for headword: String) throws -> [DictionaryEntry]
    /// Candidate readings for a single character, best first.
    func readings(forCharacter character: Character) throws -> [CharacterReading]
}

/// Works out what to write above a word.
///
/// Two steps, in order, and the second one is not optional: **77% of BKRS
/// entries store no reading at all**, so for a reader using the Russian
/// dictionary a whole-word lookup leaves most of the page unannotated.
/// CC-CEDICT's ten thousand single-character headwords are what fill it in,
/// which is the architectural consequence of bundling CC-CEDICT that is easy
/// to miss: it is the phonetic backbone for *both* language modes, not merely
/// the English dictionary.
public enum ReadingComposer {
    /// The reading to show above `word`, or nil if nothing is known.
    public static func reading(
        for word: String,
        in lookup: some DictionaryLookup,
    ) throws
        -> TokenReading?
    {
        if let exact = try exactReading(for: word, in: lookup) {
            return exact
        }
        return try composedReading(for: word, in: lookup)
    }

    /// A reading the dictionary holds for this exact word.
    ///
    /// A word can have several: 了 is `le` and `liǎo`, 为 is `wéi` and
    /// `wèi`. Choosing correctly needs to know how the word is being used,
    /// which needs a part-of-speech tagger and is out of scope — so the
    /// question is only which default is least often wrong.
    ///
    /// ### The rule, and why it is this one
    ///
    /// Measured against 38 hand-labelled common words, scoring each rule by
    /// whether it picks the reading a learner actually meets in running text:
    ///
    /// | rule | correct |
    /// |---|---|
    /// | first in the dictionary's own order | 22/38 |
    /// | most senses | 28/38 |
    /// | **prefer a neutral tone, then most senses** | **34/38** |
    ///
    /// The neutral tone wins because it is not a tie-break at all but a
    /// grammatical signal: a character takes the neutral tone precisely when
    /// it is working as a particle or a suffix, which is its highest-frequency
    /// use. It is what makes 了 `le` rather than `liǎo`, 地 `de` rather than
    /// `dì`, 着 `zhe`, 子 `zi`, 东西 `dōngxi` and 便宜 `piányi` — the sense
    /// count gets every one of those wrong, and they are among the commonest
    /// words in the language.
    ///
    /// Lowercase outranks everything, matching `LexiconBuilder`: a capital
    /// marks a surname or a place, rarely the reading wanted in prose.
    ///
    /// The four it still gets wrong — 为, 长, 重, 相 — have no neutral-tone
    /// reading and no signal to separate them. Those are exactly the cases a
    /// tagger exists for, and they are marked `.ambiguous` so the reader can
    /// see the annotation is a guess.
    static func exactReading(
        for word: String,
        in lookup: some DictionaryLookup,
    ) throws
        -> TokenReading?
    {
        let entries = try lookup.entries(for: word).filter { !$0.readingDisplay.isEmpty }
        guard let best = entries.max(by: isWeaker) else { return nil }

        // Compared case-insensitively. Nearly every common character has a
        // surname entry alongside its ordinary one -- 年 is `nián` and
        // `Nián`, 中 is `zhōng` and `Zhōng` -- and those are the same sound
        // written two ways, not two readings. Counting them as a
        // disagreement would mark most of the page as uncertain and so say
        // nothing at all.
        let distinct = Set(entries.map { $0.readingDisplay.lowercased() })
        return TokenReading(
            display: best.readingDisplay,
            source: distinct.count > 1 ? .ambiguous : .dictionary,
        )
    }

    /// Whether `lhs` is the worse choice of reading. See `exactReading` for
    /// where the ordering comes from.
    private static func isWeaker(_ lhs: DictionaryEntry, _ rhs: DictionaryEntry) -> Bool {
        if isCapitalised(lhs) != isCapitalised(rhs) {
            return isCapitalised(lhs)
        }
        if hasNeutralTone(lhs) != hasNeutralTone(rhs) {
            return !hasNeutralTone(lhs)
        }
        if lhs.senses.count != rhs.senses.count {
            return lhs.senses.count < rhs.senses.count
        }
        // Purely so the choice is the same every time rather than depending
        // on the order rows come back in.
        return lhs.readingKey > rhs.readingKey
    }

    private static func hasNeutralTone(_ entry: DictionaryEntry) -> Bool {
        entry.reading.contains { token in
            if case let .syllable(syllable) = token {
                return syllable.tone == .neutral
            }
            return false
        }
    }

    private static func isCapitalised(_ entry: DictionaryEntry) -> Bool {
        entry.reading.contains { token in
            if case let .syllable(syllable) = token {
                return syllable.base.first?.isUppercase ?? false
            }
            return false
        }
    }

    /// A reading assembled from the word's characters.
    ///
    /// All or nothing. A partial reading — pinyin over two of three
    /// characters — looks like a rendering fault rather than like missing
    /// data, and it is worse than no annotation because the reader cannot
    /// tell which part is missing.
    ///
    /// Composition goes through `PinyinToken` rather than joining the stored
    /// display strings, so that the apostrophe rule is applied across the
    /// join: 西安 is `Xī'ān`, and concatenating `Xī` and `ān` would give
    /// `Xīān`, which reads as a different word.
    static func composedReading(
        for word: String,
        in lookup: some DictionaryLookup,
    ) throws
        -> TokenReading?
    {
        guard !word.isEmpty, word.unicodeScalars.allSatisfy(ScalarClass.isHan) else {
            return nil
        }

        var tokens: [PinyinToken] = []
        for character in word {
            guard let reading = try lookup.readings(forCharacter: character).first else {
                return nil
            }
            let parsed = Pinyin.parse(numeric: reading.numeric)
            guard !parsed.isEmpty else { return nil }
            tokens.append(contentsOf: parsed)
        }

        let display = Pinyin.display(tokens, style: .diacritic)
        guard !display.isEmpty else { return nil }
        return TokenReading(display: display, source: .composed)
    }
}
