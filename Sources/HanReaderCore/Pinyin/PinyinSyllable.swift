// HanReader — MIT licensed. See LICENSE.

import Foundation

/// One pinyin syllable: a toneless base plus a tone.
///
/// The base is stored in the form CC-CEDICT writes, except that the two ways of
/// spelling ü are normalised to the character itself. CC-CEDICT uses `u:`
/// (`lu:3` → lǚ), and `v` is the other common convention; both become `ü` here
/// so that equality and lookup behave.
///
/// Case is preserved, because it is meaningful: CC-CEDICT capitalises proper
/// nouns and surnames (`Bei3 jing1`, `Su4` versus `su4`), and that distinction
/// is used to rank candidate readings for a character.
public struct PinyinSyllable: Hashable, Sendable {
    /// The toneless base, with ü normalised — `ai`, `lü`, `Bei`, `ng`.
    public let base: String

    public let tone: Tone

    public init(base: String, tone: Tone) {
        self.base = Self.normalisingUmlaut(base)
        self.tone = tone
    }

    /// Folds `u:` and `v` to `ü`, preserving case.
    static func normalisingUmlaut(_ base: String) -> String {
        guard base.contains(":") || base.contains("v") || base.contains("V") else { return base }
        var out = base
        out = out.replacingOccurrences(of: "u:", with: "ü")
        out = out.replacingOccurrences(of: "U:", with: "Ü")
        out = out.replacingOccurrences(of: "v", with: "ü")
        out = out.replacingOccurrences(of: "V", with: "Ü")
        return out
    }
}

// MARK: - Rendering

extension PinyinSyllable {
    /// The syllable with its tone as a diacritic: `ai4` → `ài`, `lü4` → `lǜ`.
    ///
    /// Tone placement follows the standard rule, which a scan of every base in
    /// CC-CEDICT confirms is unambiguous here:
    ///
    /// 1. A neutral tone carries no mark at all.
    /// 2. Otherwise mark `a` if present, else `o`, else `e`.
    /// 3. Otherwise mark the *last* of `i`, `u`, `ü` — which is what makes
    ///    `liu4` → `liù` and `dui4` → `duì` come out right.
    ///
    /// Step 2 can never be ambiguous: no pinyin base contains both `o` and `e`.
    /// That was verified against all 430 distinct bases in CC-CEDICT rather
    /// than assumed, and it is the reason this can be a simple priority scan
    /// rather than a table of exceptions. It also means the relative order of
    /// `o` and `e` below is arbitrary — swapping them changes no output, and
    /// no test can tell the difference.
    ///
    /// Note that `ü` participates only in step 3, so `lüe4` is `lüè` — the mark
    /// lands on the `e`, not the `ü`.
    public var diacritic: String {
        // An early-out rather than a load-bearing guard: with no neutral
        // entries in the precomposed table and no combining mark for the
        // neutral tone, the paths below would return the bare base anyway.
        guard tone != .neutral else { return base }
        guard let index = toneCarrierIndex() else { return diacriticWithoutVowel() }

        var characters = Array(base)
        if let marked = Self.precomposed[Character(String(characters[index]))]?[tone] {
            characters[index] = marked
            return String(characters)
        }
        return diacriticWithoutVowel()
    }

    /// The syllable in CC-CEDICT's numeric style, with ü written `u:`.
    ///
    /// `ài` → `ai4`, `ma` → `ma5`. The neutral tone is always written `5`,
    /// never `0`.
    public var numeric: String {
        let asciiBase = base
            .replacingOccurrences(of: "ü", with: "u:")
            .replacingOccurrences(of: "Ü", with: "U:")
        return "\(asciiBase)\(tone.rawValue)"
    }

    /// The index of the character that should carry the tone mark, or `nil`
    /// for a base with no vowel at all (`m`, `n`, `ng`, `hm`, `hng`).
    private func toneCarrierIndex() -> Int? {
        let characters = Array(base)
        for wanted in ["aA", "oO", "eE"] {
            if let i = characters.firstIndex(where: { wanted.contains($0) }) {
                return i
            }
        }
        // The *last* of i/u/ü, so that `iu` marks the u and `ui` marks the i.
        return characters.lastIndex(where: { "iIuUüÜ".contains($0) })
    }

    /// Fallback for bases with no vowel: attach a combining mark to the final
    /// letter and normalise.
    ///
    /// Needed for the syllabic nasals — `m`, `n`, `ng`, `hm`, `hng`. These are
    /// rare but real: CC-CEDICT contains `m2` (ḿ), among others. There is no
    /// precomposed character for most of these combinations, so this is the
    /// one place the renderer composes rather than looks up.
    private func diacriticWithoutVowel() -> String {
        guard let mark = tone.combiningMark, !base.isEmpty else { return base }
        return (base + String(mark)).precomposedStringWithCanonicalMapping
    }

    /// Precomposed tone-marked vowels, indexed by bare vowel then tone.
    ///
    /// A table rather than composition-plus-NFC because these characters all
    /// exist precomposed, and precomposed forms are what fonts render well and
    /// what string comparison and search expect.
    private static let precomposed: [Character: [Tone: Character]] = [
        "a": [.first: "ā", .second: "á", .third: "ǎ", .fourth: "à"],
        "e": [.first: "ē", .second: "é", .third: "ě", .fourth: "è"],
        "i": [.first: "ī", .second: "í", .third: "ǐ", .fourth: "ì"],
        "o": [.first: "ō", .second: "ó", .third: "ǒ", .fourth: "ò"],
        "u": [.first: "ū", .second: "ú", .third: "ǔ", .fourth: "ù"],
        "ü": [.first: "ǖ", .second: "ǘ", .third: "ǚ", .fourth: "ǜ"],
        "A": [.first: "Ā", .second: "Á", .third: "Ǎ", .fourth: "À"],
        "E": [.first: "Ē", .second: "É", .third: "Ě", .fourth: "È"],
        "I": [.first: "Ī", .second: "Í", .third: "Ǐ", .fourth: "Ì"],
        "O": [.first: "Ō", .second: "Ó", .third: "Ǒ", .fourth: "Ò"],
        "U": [.first: "Ū", .second: "Ú", .third: "Ǔ", .fourth: "Ù"],
        "Ü": [.first: "Ǖ", .second: "Ǘ", .third: "Ǚ", .fourth: "Ǜ"],
    ]
}
