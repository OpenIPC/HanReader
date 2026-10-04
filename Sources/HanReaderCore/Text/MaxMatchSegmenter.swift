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

/// Segments Han text by choosing the highest-scoring sequence of words.
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
/// **Not** greedy longest-match. Greedy takes the longest dictionary word at
/// each step, which is the characteristic failure of maximum-matching
/// segmenters: a rare long headword overlapping two common short ones wins
/// purely for being longer. The lexicon carries a weight per word that
/// penalises length precisely to express that preference, so this maximises
/// total weight over the whole run instead — a shortest-path problem, solved
/// by dynamic programming in O(n · maxWordLength).
///
/// Ties are broken towards *fewer* words, so an exact dictionary match still
/// beats an equally-weighted split, and then towards the earlier boundary, so
/// the result is deterministic.
public struct MaxMatchSegmenter: HanWordSegmenting {
    private let lexicon: Lexicon

    public init(lexicon: Lexicon) {
        self.lexicon = lexicon
    }

    public func split(_ run: String) -> [String] {
        guard !lexicon.isEmpty else { return run.map(String.init) }

        let characters = Array(run)
        let count = characters.count
        guard count > 0 else { return [] }

        // Best score for the prefix ending at each position, and how long the
        // word ending there was.
        var score = [Double](repeating: -.infinity, count: count + 1)
        var wordLength = [Int](repeating: 1, count: count + 1)
        var wordCount = [Int](repeating: 0, count: count + 1)
        score[0] = 0

        for end in 1 ... count {
            let longest = min(lexicon.maximumLength, end)
            for length in 1 ... longest {
                let start = end - length
                guard score[start] > -.infinity else { continue }

                let candidate = String(characters[start ..< end])
                // A single character is always a legitimate word in Chinese,
                // so it is always a candidate -- but it scores low enough that
                // any real dictionary word beats it.
                let weight = lexicon.weight(of: candidate)
                    ?? (length == 1 ? Self.unknownCharacterWeight : nil)
                guard let weight else { continue }

                let total = score[start] + weight
                let words = wordCount[start] + 1
                let better = total > score[end]
                    || (total == score[end] && words < wordCount[end])
                if better {
                    score[end] = total
                    wordLength[end] = length
                    wordCount[end] = words
                }
            }
        }

        var words: [String] = []
        var position = count
        while position > 0 {
            let length = wordLength[position]
            words.append(String(characters[(position - length) ..< position]))
            position -= length
        }
        return words.reversed()
    }

    /// Score for a character the lexicon does not know.
    ///
    /// Low but finite: a path through unknown characters must stay reachable,
    /// or text outside the dictionary could not be segmented at all. Below
    /// any real weight, so a dictionary word always wins.
    static let unknownCharacterWeight = 0.0
}
