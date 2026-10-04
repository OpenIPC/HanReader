// HanReader — MIT licensed. See LICENSE.

import Foundation

/// The segmentation word list, held in memory for matching.
///
/// Built from a dictionary's derived lexicon. Indexed by length so the matcher
/// can try the longest plausible prefix first without scanning.
public struct Lexicon: Sendable {
    private let weights: [String: Double]
    /// Longest word present, so the matcher never tries a prefix that cannot
    /// match.
    public let maximumLength: Int

    public init(_ lexemes: [Lexeme]) {
        var weights: [String: Double] = [:]
        var longest = 0
        for lexeme in lexemes {
            weights[lexeme.word] = lexeme.weight
            longest = max(longest, lexeme.characterLength)
        }
        self.weights = weights
        maximumLength = min(longest, LexiconBuilder.maximumWordLength)
    }

    /// Convenience for tests and for a reader with no dictionary installed.
    public init(words: [String]) {
        self.init(words.map {
            Lexeme(
                word: $0,
                characterLength: $0.count,
                weight: LexiconBuilder.weight(length: $0.count, senseCount: 1),
            )
        })
    }

    public func contains(_ word: some StringProtocol) -> Bool {
        weights[String(word)] != nil
    }

    public func weight(of word: some StringProtocol) -> Double? {
        weights[String(word)]
    }

    public var isEmpty: Bool {
        weights.isEmpty
    }

    public var count: Int {
        weights.count
    }
}

/// Segments Han text by backward maximum matching over a lexicon.
///
/// Exists alongside the Apple tokenizer for three reasons, in order of weight:
///
/// 1. **It is deterministic.** `NLTokenizer` is a closed model whose output
///    can change with an OS release, so no test can pin it. This one can be
///    asserted exactly, which is what makes the segmentation suite meaningful.
/// 2. It works where `NaturalLanguage` does not — the Linux CI job, and any
///    future non-Apple platform.
/// 3. Its vocabulary is the dictionary's own, so a word it finds is a word the
///    reader can actually look up. That removes the prototype's silent
///    mismatch, where the tokenizer produced a token no dictionary defined and
///    the UI reported "not found" for what was really a segmentation error.
///
/// **Backward** rather than forward matching: scanning from the right is
/// empirically more accurate for Chinese, because modifiers precede heads, and
/// it costs nothing extra.
public struct MaxMatchSegmenter: HanWordSegmenting {
    private let lexicon: Lexicon

    public init(lexicon: Lexicon) {
        self.lexicon = lexicon
    }

    public func split(_ run: String) -> [String] {
        guard !lexicon.isEmpty else { return run.map(String.init) }

        let characters = Array(run)
        guard !characters.isEmpty else { return [] }

        var words: [String] = []
        var end = characters.count

        while end > 0 {
            let longest = min(lexicon.maximumLength, end)
            var matched = false

            // Longest first, from the right.
            for length in stride(from: longest, through: 2, by: -1) {
                let candidate = String(characters[(end - length) ..< end])
                if lexicon.contains(candidate) {
                    words.append(candidate)
                    end -= length
                    matched = true
                    break
                }
            }

            if !matched {
                // No multi-character match: take one character. A single
                // character is always a legitimate word in Chinese, so this is
                // a real fallback rather than a failure.
                words.append(String(characters[end - 1]))
                end -= 1
            }
        }

        return words.reversed()
    }
}
