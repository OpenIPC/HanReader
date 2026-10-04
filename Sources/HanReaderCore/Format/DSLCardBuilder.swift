// HanReader — MIT licensed. See LICENSE.

import Foundation

/// One card as it appears in the file: a headword, a reading, and a body.
public struct DSLCard: Hashable, Sendable {
    /// Consecutive unindented lines. The DSL spec allows several spellings
    /// to share one card; BKRS never uses it, but accepting it costs a line
    /// and refusing it would be a parser bug on the next dictionary.
    public let headwords: [String]
    /// The reading line, already stripped of its indent. `_` means the
    /// dictionary has no reading for this word — **77% of BKRS cards**.
    public let pinyin: String
    /// Everything after the reading line.
    public let body: [String]

    public init(headwords: [String], pinyin: String, body: [String]) {
        self.headwords = headwords
        self.pinyin = pinyin
        self.body = body
    }
}

/// Turns a card into entries.
///
/// ### One entry per reading
///
/// A card with several readings — `le, liǎo, liào` — becomes several
/// entries sharing a sense run, rather than one entry whose reading is the
/// whole comma-separated string. Three reasons, in order of weight:
///
/// 1. It is what the schema says. An entry is keyed on headword *and*
///    reading, which is the shape CC-CEDICT already needs for 了.
/// 2. It makes the existing reading-selection rule work for BKRS. The
///    alternative puts `le, liǎo, liào` above the word on the page, which is
///    exactly the prototype's behaviour this rebuild exists to replace.
/// 3. The duplication is nothing: 9,069 of 3,434,224 cards have more than
///    one reading.
///
/// ### And one entry per spelling, for the same reason
///
/// A card may carry several headword lines. Each becomes its own entry over
/// the same sense run, so every spelling the dictionary lists can be looked
/// up. The alternative — reading the second line as the traditional form of
/// the first — is an invention: the format says consecutive headword lines
/// are alternative headwords for one article, and says nothing about which
/// script they are in. Guessing would write a wrong `traditional` into the
/// cross-dictionary merge key, and it also silently dropped every spelling
/// after the second.
///
/// No card in this set has more than one headword, so nothing here changes
/// what BKRS imports. It changes what the next dictionary imports.
///
/// ### The sense stack is indexed by level, not pushed and popped
///
/// `[m4]` after an `[m3]` must nest under the right `[m2]`, and a card can
/// reopen a shallower level without closing the deeper one. A stack that
/// simply pushes on open and pops on close attaches a sense to whatever
/// happened to be last, which is wrong whenever the levels skip.
///
/// Markup is also not reliably balanced: across the whole set there are two
/// more `[mN]` opens than `[/m]` closes. Anything left open at the end of a
/// card is closed there.
public struct DSLCardBuilder: Sendable {
    /// The toneless syllables this dictionary's readings are built from,
    /// used to split a run-together reading like `tǔ'ěrqísītǎn`.
    private let syllableBases: Set<String>

    public init(syllableBases: Set<String>) {
        self.syllableBases = syllableBases
    }

    public func entries(from card: DSLCard)
        -> (entries: [DictionaryEntry], diagnostics: [DSLDiagnostic])
    {
        var assembly = SenseAssembly()
        var diagnostics: [DSLDiagnostic] = []

        for (index, line) in card.body.enumerated() {
            if index > 0 {
                assembly.beginLine()
            }
            let lexed = DSLLexer.tokens(in: line)
            diagnostics.append(contentsOf: lexed.diagnostics)
            assembly.consume(lexed.tokens)
        }
        let senses = assembly.finish()

        guard !card.headwords.isEmpty else { return ([], diagnostics) }
        let headwords = card.headwords.map { Headword(simplified: $0, traditional: nil) }
        let readings = Self.readings(in: card.pinyin).map { tokens(forReading: $0) }

        let entries = headwords.flatMap { headword in
            readings.isEmpty
                ? [DictionaryEntry(headword: headword, reading: [], senses: senses)]
                : readings.map {
                    DictionaryEntry(headword: headword, reading: $0, senses: senses)
                }
        }
        return (entries, diagnostics)
    }

    // MARK: - Readings

    /// Splits the reading line into individual readings.
    ///
    /// `_` is not a reading. Returning `[""]` for it — which a naive split
    /// does — produces an entry claiming to know a pronunciation that is the
    /// empty string, and 77% of this dictionary is that case.
    static func readings(in pinyin: String) -> [String] {
        let trimmed = pinyin.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != "_" else { return [] }
        return trimmed
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0 != "_" }
    }

    /// Converts one diacritic reading into tokens.
    ///
    /// Falls back to a literal when the reading cannot be split into known
    /// syllables. That is a degradation, not a failure: the reading still
    /// displays exactly as the dictionary wrote it, and only the
    /// cross-dictionary merge key is lost — so the word appears as its own
    /// group instead of joining CC-CEDICT's.
    func tokens(forReading reading: String) -> [PinyinToken] {
        guard let syllables = PinyinSyllabifier.syllables(
            fromDiacritic: reading,
            bases: syllableBases,
        ) else {
            return [.literal(reading)]
        }
        return syllables.map { .syllable($0) }
    }
}
