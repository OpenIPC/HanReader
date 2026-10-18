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
    ///
    /// - Parameter context: what the neighbouring words say about how this one
    ///   is being used. Consulted only for a word whose readings actually
    ///   disagree, so passing `.none` changes nothing for the 99% of tokens
    ///   that have one reading.
    public static func reading(
        for word: String,
        in lookup: some DictionaryLookup,
        context: ReadingContext = .none,
    ) throws
        -> TokenReading?
    {
        if let exact = try exactReading(for: word, in: lookup, context: context) {
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
    /// ### Where the rule runs out, and what picks up
    ///
    /// 为, 长, 重 and 相 have no neutral-tone reading and nothing in the
    /// dictionary to separate them, so the sense count decides and it decides
    /// badly: CC-CEDICT says more about 重 as `chóng` ("to repeat") than as
    /// `zhòng` ("heavy"), which annotated 很重 — "very heavy" — as `chóng`.
    ///
    /// No context-free rule can fix that, because both readings are right
    /// somewhere: 重 is `chóng` in 重复 and `zhòng` in 很重. So `context` is
    /// consulted first, and `HeteronymRules` answers for the handful of cases
    /// where a closed-class neighbour settles it grammatically — a degree
    /// adverb can only modify a stative predicate, so 很 before 重 rules
    /// `chóng` out rather than merely making it less likely.
    ///
    /// What the rules do not reach is still marked `.ambiguous`, so the
    /// annotation is drawn faintly and the panel lists every reading.
    static func exactReading(
        for word: String,
        in lookup: some DictionaryLookup,
        context: ReadingContext = .none,
    ) throws
        -> TokenReading?
    {
        try reading(from: lookup.entries(for: word), context: context)
    }

    /// The reading to show, given entries already fetched.
    ///
    /// Separate from `exactReading(for:in:)` so a caller that has the entries
    /// in hand — the detail panel has just fetched them to show definitions —
    /// does not query for them a second time.
    public static func reading(
        from entries: [DictionaryEntry],
        context: ReadingContext = .none,
    )
        -> TokenReading?
    {
        let usable = entries.filter(isUsable)
        guard let fallback = usable.max(by: isWeaker) else { return nil }

        // A grammatical constraint beats every ranking below it, because it is
        // the only one that knows the sentence. Applied before the rest and
        // only where the dictionary actually offers the preferred reading, so
        // a rule naming a reading this dictionary does not have falls through
        // to the context-free answer rather than annotating nothing.
        let best = preferred(in: usable, context: context) ?? fallback

        // Compared case-insensitively. Nearly every common character has a
        // surname entry alongside its ordinary one -- 年 is `nián` and
        // `Nián`, 中 is `zhōng` and `Zhōng` -- and those are the same sound
        // written two ways, not two readings. Counting them as a
        // disagreement would mark most of the page as uncertain and so say
        // nothing at all.
        let distinct = Set(usable.map { $0.readingDisplay.lowercased() })
        return TokenReading(
            display: best.readingDisplay,
            source: distinct.count > 1 ? .ambiguous : .dictionary,
        )
    }

    /// Whether an entry's reading can be shown to a reader.
    ///
    /// CC-CEDICT writes `[xx5]` for a character whose pronunciation it does
    /// not know — 23 entries, mostly Korean *gugja* characters that happen to
    /// be encoded as Han. The parser keeps that as `PinyinToken.unknown`
    /// precisely so the UI can decline to show it, and `Pinyin.display`
    /// renders it as `?`. Shown, it is a question mark presented as a
    /// pronunciation, and marked `.dictionary` it would be presented as a
    /// *confident* one. No annotation is the honest rendering.
    private static func isUsable(_ entry: DictionaryEntry) -> Bool {
        !entry.readingDisplay.isEmpty && !entry.reading.contains(.unknown)
    }

    /// The entry a context rule asks for, if there is a rule and the
    /// dictionary has the reading it names.
    ///
    /// Several entries can share the preferred reading — 和 has four under
    /// `hé` — so the ordinary ranking still chooses between them. The rule
    /// narrows the field; it does not replace the ranking.
    private static func preferred(
        in entries: [DictionaryEntry],
        context: ReadingContext,
    )
        -> DictionaryEntry?
    {
        guard !context.isEmpty,
              let headword = entries.first?.headword,
              let wanted = HeteronymRules.preferredReading(for: headword, in: context)
        else { return nil }
        return entries
            .filter { $0.readingKey.caseInsensitiveCompare(wanted) == .orderedSame }
            .max(by: isWeaker)
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
    public static func composedReading(
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
            // A character the dictionary itself marks unknown cannot
            // contribute to a word's reading, and the whole word is refused
            // rather than annotated with a `?` in the middle of it.
            guard !parsed.isEmpty, !parsed.contains(.unknown) else { return nil }
            tokens.append(contentsOf: parsed)
        }

        let display = Pinyin.display(tokens, style: .diacritic)
        guard !display.isEmpty else { return nil }
        return TokenReading(display: display, source: .composed)
    }
}
