// HanReader — MIT licensed. See LICENSE.

import Foundation

/// Reads diacritic pinyin back into syllables.
///
/// This exists for one reason: matching readings *across* dictionaries.
/// CC-CEDICT stores `liao3`, BKRS stores `liǎo`, and 了 has to group under one
/// reading rather than appearing twice. Converting the diacritic form back to
/// the numeric one gives a key both sides agree on.
///
/// It is deliberately **never used for display.** A mis-syllabification here
/// degrades to an extra reading group in the UI, which is untidy; using it to
/// render would instead put wrong pinyin on the screen, which is a correctness
/// failure for a learner. The diacritic text the dictionary supplied is always
/// what gets shown.
public enum PinyinSyllabifier {
    // MARK: - Single syllable

    /// Converts one diacritic syllable to its toned form: `ài` → (`ai`, 4).
    ///
    /// Works by decomposing to NFD and reading the combining mark, so it
    /// handles both precomposed input (`à`) and already-decomposed input
    /// (`a` + U+0300) without caring which it was given.
    ///
    /// A syllable with no mark is the neutral tone, which is correct: that is
    /// exactly how the neutral tone is written.
    public static func syllable(fromDiacritic text: String) -> PinyinSyllable? {
        guard !text.isEmpty else { return nil }

        var tone = Tone.neutral
        var bare = String.UnicodeScalarView()

        for scalar in text.decomposedStringWithCanonicalMapping.unicodeScalars {
            switch scalar {
            case "\u{0304}": tone = .first
            case "\u{0301}": tone = .second
            case "\u{030C}": tone = .third
            case "\u{0300}": tone = .fourth
            // A diaeresis is part of ü, not a tone mark; keep it so the
            // recomposition below yields ü rather than a bare u.
            default: bare.append(scalar)
            }
        }

        let base = String(bare).precomposedStringWithCanonicalMapping
        guard base.allSatisfy(\.isLetter) else { return nil }
        return PinyinSyllable(base: base, tone: tone)
    }

    // MARK: - Continuous text

    /// Splits a continuous diacritic reading into syllables.
    ///
    /// BKRS writes multi-syllable readings run together (`sānbǐxīhé`), so they
    /// have to be segmented before they can be matched. Greedy longest-match
    /// over a known base set, with backtracking: greedy alone fails on
    /// sequences where a long match leaves an unparseable remainder.
    ///
    /// Apostrophes, hyphens and spaces are treated as hard boundaries, which is
    /// exactly what they are there to mark. Both the ASCII apostrophe and the
    /// typographic one are handled, because BKRS uses U+2019 (`tǔ'ěrqísītǎn`).
    ///
    /// - Parameters:
    ///   - text: a reading such as `sānbǐxīhé`.
    ///   - bases: the toneless bases to match against, lowercased. In the app
    ///     this comes from the set observed in CC-CEDICT; injecting it keeps
    ///     this function pure and testable, and lets the set grow without
    ///     touching the algorithm.
    /// - Returns: the syllables, or `nil` if the text cannot be segmented
    ///   cleanly. `nil` is a normal outcome, not an error: the caller falls
    ///   back to grouping by the raw string.
    public static func syllables(
        fromDiacritic text: String,
        bases: Set<String>,
    )
        -> [PinyinSyllable]?
    {
        let groups = text
            .split(whereSeparator: { $0 == "'" || $0 == "\u{2019}" || $0 == "-" || $0 == " " })
        guard !groups.isEmpty else { return nil }

        var result: [PinyinSyllable] = []
        for group in groups {
            guard let parsed = segment(Array(group), bases: bases) else { return nil }
            result.append(contentsOf: parsed)
        }
        return result.isEmpty ? nil : result
    }

    /// Longest-match-first segmentation with backtracking, memoised by
    /// starting position.
    ///
    /// Without memoisation this is exponential: a run with many valid prefix
    /// splits and an unmatchable tail re-explores the same suffixes once per
    /// path. `aaaa…az` against bases `a`, `aa`, `aaa`… is the degenerate
    /// shape, and 40 characters of it is already intractable. Each starting
    /// index is now resolved at most once, which makes the search linear in
    /// the number of positions times the (bounded) prefix length.
    ///
    /// Indices are passed rather than sliced arrays, so no copying happens per
    /// branch either.
    private static func segment(
        _ characters: [Character],
        bases: Set<String>,
    )
        -> [PinyinSyllable]?
    {
        // nil = not yet attempted; .some(nil) = attempted and failed.
        var memo = [Int: [PinyinSyllable]?](minimumCapacity: characters.count + 1)

        func solve(from start: Int) -> [PinyinSyllable]? {
            if start == characters.count {
                return []
            }
            if let cached = memo[start] {
                return cached
            }

            // The longest pinyin base is six characters (`chuang`, `shuang`),
            // so longer prefixes cannot match.
            let maximum = min(6, characters.count - start)
            for length in stride(from: maximum, through: 1, by: -1) {
                let candidate = String(characters[start ..< (start + length)])
                guard let syllable = syllable(fromDiacritic: candidate),
                      bases.contains(syllable.base.lowercased())
                else { continue }

                if let rest = solve(from: start + length) {
                    let result = [syllable] + rest
                    memo[start] = result
                    return result
                }
            }
            memo[start] = .some(nil)
            return nil
        }

        return solve(from: 0)
    }
}
