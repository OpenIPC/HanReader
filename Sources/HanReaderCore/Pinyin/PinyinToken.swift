// HanReader — MIT licensed. See LICENSE.

import Foundation

/// One element of a parsed pinyin reading.
///
/// A reading is not simply a list of syllables: CC-CEDICT's pinyin field also
/// carries separators, literal Latin text and an explicit "unknown" marker. A
/// survey of the whole dictionary found only 21 distinct non-syllable forms, so
/// this enumeration covers the field exhaustively rather than approximately.
public enum PinyinToken: Hashable, Sendable {
    /// An ordinary toned syllable.
    case syllable(PinyinSyllable)

    /// A separator appearing inside the reading: `,` between alternatives, or
    /// `·` as the interpunct in transliterated foreign names.
    case separator(String)

    /// Latin text kept verbatim — `A` in `A A zhi4`, or `OK`. Letter names and
    /// loanwords appear in readings and are not syllables.
    case literal(String)

    /// CC-CEDICT's `xx5`, which marks a reading it does not know. Preserved as
    /// a distinct case rather than dropped, so the UI can say "unknown" rather
    /// than silently showing a short reading.
    case unknown
}

/// Parsing and rendering of pinyin readings.
public enum Pinyin {
    // MARK: - Parsing

    /// Parses CC-CEDICT's numeric pinyin field into tokens.
    ///
    /// The field is space-separated, and every element is one of four shapes.
    /// Anything unrecognised becomes a ``PinyinToken/literal(_:)`` rather than
    /// being discarded, so no information is lost even if the format gains
    /// something new upstream.
    ///
    ///     parse(numeric: "ni3 hao3")   // [syllable(ni3), syllable(hao3)]
    ///     parse(numeric: "lu:3")       // [syllable(lü3)]
    ///     parse(numeric: "Bei3 jing1") // capitals preserved
    ///     parse(numeric: "xx5")        // [unknown]
    public static func parse(numeric field: String) -> [PinyinToken] {
        field
            .split(separator: " ", omittingEmptySubsequences: true)
            .flatMap(splittingSeparators(from:))
            .map(token(for:))
    }

    /// Splits `,` and `·` off a piece so they are recognised whether or not
    /// they are spaced.
    ///
    /// CC-CEDICT is not consistent about this -- both `ha1 , ha1` and
    /// `ha1, ha1` occur. Treating a separator as a token only when it stands
    /// alone leaves `ha1,` as literal text, so the syllable never gets
    /// converted and renders as `ha1,` beside a properly rendered neighbour.
    private static func splittingSeparators(from piece: Substring) -> [Substring] {
        guard piece.contains(",") || piece.contains("·") else { return [piece] }

        var pieces: [Substring] = []
        var current = piece.startIndex
        for index in piece.indices where piece[index] == "," || piece[index] == "·" {
            if current < index {
                pieces.append(piece[current ..< index])
            }
            pieces.append(piece[index ... index])
            current = piece.index(after: index)
        }
        if current < piece.endIndex {
            pieces.append(piece[current...])
        }
        return pieces
    }

    private static func token(for piece: Substring) -> PinyinToken {
        if piece == "," || piece == "·" {
            return .separator(String(piece))
        }
        if piece == "xx5" || piece == "xx" {
            return .unknown
        }

        // A syllable is letters (with `:` for ü) followed by a single digit.
        // The value is range-checked *before* narrowing: a field ending in a
        // Unicode numeral such as 万 has a wholeNumberValue of 10000, and
        // UInt8(_:) traps on it rather than falling through to a literal.
        if let last = piece.last,
           let digit = last.wholeNumberValue,
           (1 ... 5).contains(digit),
           let tone = Tone(rawValue: UInt8(digit))
        {
            let base = piece.dropLast()
            if !base.isEmpty, base.allSatisfy({ $0.isLetter || $0 == ":" }) {
                return .syllable(PinyinSyllable(base: String(base), tone: tone))
            }
        }
        return .literal(String(piece))
    }

    // MARK: - Rendering

    /// Renders tokens for display.
    ///
    /// Syllables within a run are joined without spaces, which is how pinyin is
    /// normally written for a word (`Běijīng`, not `Běi jīng`), with an
    /// apostrophe inserted only where one is needed to keep the syllable
    /// boundary unambiguous — see ``needsApostrophe(after:before:)``.
    public static func display(_ tokens: [PinyinToken], style: PinyinStyle = .diacritic) -> String {
        var out = ""
        var previousSyllable: PinyinSyllable?

        for token in tokens {
            switch token {
            case let .syllable(syllable):
                out += joiner(before: syllable, after: previousSyllable, style: style, out: out)
                out += rendered(syllable, style: style)
                previousSyllable = syllable

            case let .separator(separator):
                out += separator == "," ? ", " : separator
                previousSyllable = nil

            case let .literal(text):
                if !out.isEmpty, !out.hasSuffix(" ") {
                    out += " "
                }
                out += text
                previousSyllable = nil

            case .unknown:
                if !out.isEmpty, !out.hasSuffix(" ") {
                    out += " "
                }
                // Numeric style is the cross-dictionary merge key, so it must
                // round-trip to CC-CEDICT's own spelling. Rendering `?` there
                // would collapse every unknown reading onto a single key and
                // let unrelated entries merge.
                out += style == .numeric ? "xx5" : "?"
                previousSyllable = nil
            }
        }
        return out
    }

    /// What, if anything, goes between the previous output and this syllable.
    ///
    /// Three cases: a spaced style always separates; a syllable following
    /// another may need an apostrophe; and a syllable following a literal or
    /// an unknown needs a space, without which the letter names in
    /// `A A zhi4` run into the reading after them.
    private static func joiner(
        before syllable: PinyinSyllable,
        after previous: PinyinSyllable?,
        style: PinyinStyle,
        out: String,
    )
        -> String
    {
        guard let previous else {
            return out.isEmpty || out.hasSuffix(" ") ? "" : " "
        }
        if style == .numeric || style == .diacriticSpaced {
            return " "
        }
        if startsAProperNoun(syllable) {
            return " "
        }
        return needsApostrophe(after: previous, before: syllable) ? "'" : ""
    }

    /// Whether a syllable begins a new proper noun, and so takes a space.
    ///
    /// CC-CEDICT separates *every* syllable with a space, so the spacing in
    /// the source says nothing about word boundaries — `Bei3 jing1` is one
    /// word. Capitalisation does say something: a capital marks a syllable
    /// that begins a proper noun, so a capitalised syllable part-way through
    /// a reading is where one name ends and the next begins.
    ///
    /// That single rule produces standard orthography across the cases:
    ///
    ///     Bei3 jing1            → Běijīng      (one word, unchanged)
    ///     Lin2 Chong1           → Lín Chōng    (surname, given name)
    ///     Ding1 Ru3 chang1      → Dīng Rǔchāng (given name's syllables joined)
    ///     Bei3 jing1 Da4 xue2   → Běijīng Dàxué
    ///
    /// It affects 4,559 of CC-CEDICT's 107,619 entries — 4.2%, almost all
    /// personal and place names, which before this ran together as
    /// `LínChōng`.
    ///
    /// What it cannot do: a capital says where a unit *starts* and nothing
    /// says where one *ends*, so a lowercase syllable following a name still
    /// attaches to it. `yi1 Zhong1 yi1 Tai2` comes out as `yī Zhōngyī Tái`
    /// rather than `yī Zhōng yī Tái`. The same shape has different answers
    /// — `Zhong1 guo2` must join — and capitalisation cannot tell them
    /// apart, because CC-CEDICT does not record word boundaries at all.
    private static func startsAProperNoun(_ syllable: PinyinSyllable) -> Bool {
        syllable.base.first?.isUppercase ?? false
    }

    private static func rendered(_ syllable: PinyinSyllable, style: PinyinStyle) -> String {
        switch style {
        case .diacritic, .diacriticSpaced: syllable.diacritic
        case .numeric: syllable.numeric
        case .toneless: syllable.base
        }
    }

    /// Whether a syllable boundary needs an apostrophe to stay readable.
    ///
    /// Without one, `Xi'an` would be written `Xian` and read as a single
    /// syllable. The convention is to separate when the following syllable
    /// begins with a vowel and the preceding one could otherwise absorb it —
    /// which in practice means the previous syllable ended in a vowel or in
    /// `n`/`ng`.
    ///
    ///     Xi1 an1   → Xī'ān
    ///     Bei3 jing1 → Běijīng   (j cannot start a vowel run)
    static func needsApostrophe(
        after previous: PinyinSyllable,
        before next: PinyinSyllable,
    )
        -> Bool
    {
        guard let first = next.base.lowercased().first, "aeo".contains(first) else { return false }
        let tail = previous.base.lowercased()
        guard let last = tail.last else { return false }
        // `ng` must be tested explicitly: it ends in `g`, so checking only the
        // final character silently omits it and `Chang2 an1` joins as
        // `chángān` instead of `Cháng'ān`.
        return "aeiouü".contains(last) || tail.hasSuffix("n") || tail.hasSuffix("ng")
    }
}

/// How a reading should be written out.
public enum PinyinStyle: Sendable, Hashable {
    /// `Běijīng` — syllables joined, tones as diacritics. The reading style.
    case diacritic
    /// `Běi jīng` — as above but spaced, for per-syllable display.
    case diacriticSpaced
    /// `Bei3 jing1` — CC-CEDICT's own style, and the cross-dictionary key.
    case numeric
    /// `Beijing` — no tones, for lenient search.
    case toneless
}
