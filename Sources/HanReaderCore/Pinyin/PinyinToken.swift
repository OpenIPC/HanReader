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
        field.split(separator: " ", omittingEmptySubsequences: true).map(token(for:))
    }

    private static func token(for piece: Substring) -> PinyinToken {
        if piece == "," || piece == "·" {
            return .separator(String(piece))
        }
        if piece == "xx5" || piece == "xx" {
            return .unknown
        }

        // A syllable is letters (with `:` for ü) followed by a single digit.
        if let last = piece.last, let digit = last.wholeNumberValue,
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
                if let previous = previousSyllable {
                    if style == .numeric || style == .diacriticSpaced {
                        out += " "
                    } else if needsApostrophe(after: previous, before: syllable) {
                        out += "'"
                    }
                }
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
                out += "?"
                previousSyllable = nil
            }
        }
        return out
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
        return "aeiouü".contains(last) || last == "n"
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
