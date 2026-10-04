// HanReader — MIT licensed. See LICENSE.

import Foundation

/// A word in the segmentation lexicon.
public struct Lexeme: Hashable, Sendable {
    public let word: String
    public let characterLength: Int
    /// Higher is preferred when two segmentations compete. Length is
    /// penalised, so a plausible short word beats an implausible long one.
    public let weight: Double

    public init(word: String, characterLength: Int, weight: Double) {
        self.word = word
        self.characterLength = characterLength
        self.weight = weight
    }
}

/// A candidate reading for a single character.
public struct CharacterReading: Hashable, Sendable {
    public let character: Character
    public let numeric: String
    public let display: String
    /// 0 is the best candidate.
    public let rank: Int

    public init(character: Character, numeric: String, display: String, rank: Int) {
        self.character = character
        self.numeric = numeric
        self.display = display
        self.rank = rank
    }
}

/// Derives the segmentation lexicon, per-character readings and syllable
/// inventory from a parsed dictionary.
///
/// These are the three things the reader needs that are not definitions, and
/// all three come from the data rather than from tables written out by hand.
public enum LexiconBuilder {
    /// Longest word admitted to the lexicon.
    ///
    /// Measured against BKRS: 532,881 of its headwords are seven characters or
    /// more — idioms, proper nouns and phrase-level entries. Maximum-matching
    /// over a set containing those swallows whole clauses, so the lexicon is
    /// capped even though the dictionary is not. Six covers 91% of headwords
    /// and matches the longest pinyin syllable run the segmenter will try.
    public static let maximumWordLength = 6

    // MARK: - Lexicon

    /// Builds the word list used for segmentation.
    ///
    /// Three filters, each for a reason:
    ///
    /// - **Pure Han only.** A headword containing Latin letters or digits
    ///   (`卡拉OK`, `3C产品`) is matched by the tokenizer's Latin and number
    ///   handling instead, and admitting it here would let a Han-run scan run
    ///   past a script boundary.
    /// - **Length-capped**, as above.
    /// - **Not a bare cross-reference.** An entry whose only sense is
    ///   "variant of X" is a spelling note, and treating it as a word to
    ///   segment towards produces confident nonsense.
    public static func lexicon(from entries: [DictionaryEntry]) -> [Lexeme] {
        var best: [String: Double] = [:]

        for entry in entries {
            let word = entry.headword.simplified
            let length = word.count
            guard length >= 1, length <= maximumWordLength else { continue }
            guard word.allSatisfy(\.isHan) else { continue }
            guard entry.senses.contains(where: { $0.kind == .definition }) else { continue }

            // More senses suggests a more established word, which is the only
            // frequency-like signal CC-CEDICT offers.
            let score = weight(length: length, senseCount: entry.senses.count)
            best[word] = max(best[word] ?? 0, score)
        }

        return best
            .map { Lexeme(word: $0.key, characterLength: $0.key.count, weight: $0.value) }
            .sorted { $0.word < $1.word }
    }

    /// Weight for a candidate word.
    ///
    /// Length is penalised rather than rewarded. Greedy longest-match already
    /// prefers long matches structurally; without a counterweight it will
    /// reach for a rare six-character idiom over two common words, which is
    /// the characteristic failure of maximum-matching segmenters.
    public static func weight(length: Int, senseCount: Int) -> Double {
        let lengthPenalty = 1.0 / Double(length)
        let senseBonus = min(Double(senseCount), 8) / 8
        return lengthPenalty + senseBonus
    }

    // MARK: - Character readings

    /// Collects per-character readings, best candidate first.
    ///
    /// Required rather than nice to have: 77% of BKRS entries carry no reading
    /// at all, so without this a reader using a Russian dictionary would see
    /// pinyin on almost nothing.
    ///
    /// Ranking is a heuristic, and the UI says so by rendering a composed
    /// reading differently from a dictionary one. CC-CEDICT has no frequency
    /// data, so the signals available are:
    ///
    /// 1. Lowercase over capitalised — capitals mark surnames and proper
    ///    nouns, which are rarely the reading wanted for a character in prose.
    /// 2. More senses, as a proxy for how established the reading is.
    /// 3. A real definition over a bare cross-reference.
    /// 4. Alphabetical, purely so the output is deterministic.
    private struct Candidate {
        let numeric: String
        let display: String
        let isCapitalised: Bool
        let senseCount: Int
        let hasDefinition: Bool
    }

    public static func characterReadings(from entries: [DictionaryEntry]) -> [CharacterReading] {
        var byCharacter: [Character: [String: Candidate]] = [:]

        for entry in entries {
            let word = entry.headword.simplified
            guard word.count == 1, let character = word.first, character.isHan else { continue }
            guard let syllable = entry.reading.compactMap({ token -> PinyinSyllable? in
                if case let .syllable(syllable) = token {
                    return syllable
                }
                return nil
            }).first else { continue }

            let candidate = Candidate(
                numeric: syllable.numeric,
                display: syllable.diacritic,
                isCapitalised: syllable.base.first?.isUppercase ?? false,
                senseCount: entry.senses.count,
                hasDefinition: entry.senses.contains { $0.kind == .definition },
            )
            // Keep the strongest candidate per distinct reading, so the same
            // reading appearing in several entries does not crowd out others.
            let existing = byCharacter[character]?[candidate.numeric.lowercased()]
            if existing == nil || candidate.senseCount > (existing?.senseCount ?? 0) {
                byCharacter[character, default: [:]][candidate.numeric.lowercased()] = candidate
            }
        }

        var readings: [CharacterReading] = []
        for (character, candidates) in byCharacter {
            let ordered = candidates.values.sorted { lhs, rhs in
                if lhs.isCapitalised != rhs.isCapitalised {
                    return !lhs.isCapitalised
                }
                if lhs.hasDefinition != rhs.hasDefinition {
                    return lhs.hasDefinition
                }
                if lhs.senseCount != rhs.senseCount {
                    return lhs.senseCount > rhs.senseCount
                }
                return lhs.numeric < rhs.numeric
            }
            for (rank, candidate) in ordered.enumerated() {
                readings.append(CharacterReading(
                    character: character,
                    numeric: candidate.numeric,
                    display: candidate.display,
                    rank: rank,
                ))
            }
        }
        return readings.sorted {
            ($0.character, $0.rank) < ($1.character, $1.rank)
        }
    }

    // MARK: - Syllable inventory

    /// The toneless syllable bases this dictionary actually uses.
    ///
    /// Feeds the syllabifier, which needs a base set to split a run-together
    /// BKRS reading. Observed rather than enumerated by hand, so it cannot
    /// disagree with the data it will be used against.
    public static func syllableBases(from entries: [DictionaryEntry]) -> Set<String> {
        var bases: Set<String> = []
        for entry in entries {
            for token in entry.reading {
                if case let .syllable(syllable) = token {
                    bases.insert(syllable.base.lowercased())
                }
            }
        }
        return bases
    }
}

extension Character {
    fileprivate static func < (lhs: Character, rhs: Character) -> Bool {
        String(lhs) < String(rhs)
    }
}
