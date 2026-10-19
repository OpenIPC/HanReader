// HanReader — MIT licensed. See LICENSE.

import Foundation

/// What happened to one character of a dictation attempt.
///
/// Five outcomes rather than right-and-wrong, because the three kinds of
/// wrong are different skills and a learner needs to know which one failed.
public enum DictationOutcome: UInt8, Sendable, Hashable, CaseIterable {
    case correct

    /// The wrong character, but one that sounds exactly the same — 真 for 针,
    /// both `zhen1`.
    ///
    /// They heard it correctly and their input method offered the wrong
    /// candidate. Counting that as a listening mistake would be a lie about
    /// the one thing this exercise measures.
    case homophone

    /// The right syllable with the wrong tone — 是 `shi4` typed for 时
    /// `shi2`.
    ///
    /// The most useful signal in the exercise, and the one no other tool
    /// gives: tones are what a learner's ear loses first and what no amount
    /// of reading practice repairs.
    case toneSlip

    /// A character with no reading in common with the expected one. This is
    /// the only outcome that means "did not hear it".
    case misheard

    /// Expected but not typed.
    case missing

    /// Typed but not expected.
    case extra

    /// Whether this counts against the score. Everything except a correct
    /// character does; the distinction between them is for the reader, not
    /// for the arithmetic.
    public var isError: Bool {
        self != .correct
    }
}

/// One character of a checked attempt, ready to render.
public struct DictationMark: Hashable, Sendable {
    public let outcome: DictationOutcome
    /// What the transcript says. Nil for an extra character.
    public let expected: Character?
    /// What the learner typed. Nil for a missing character.
    public let typed: Character?
    /// Offset of `expected` in the phrase's text, in UTF-16 units, so the
    /// mark can be drawn over the right character. Nil for an extra.
    public let offset: Int?

    public init(
        outcome: DictationOutcome,
        expected: Character?,
        typed: Character?,
        offset: Int?,
    ) {
        self.outcome = outcome
        self.expected = expected
        self.typed = typed
        self.offset = offset
    }
}

/// A checked dictation attempt.
public struct DictationResult: Hashable, Sendable {
    public let marks: [DictationMark]
    /// Characters of the transcript that were typed correctly.
    public let correct: Int
    /// Characters the transcript expected — the denominator.
    public let expected: Int

    public init(marks: [DictationMark], correct: Int, expected: Int) {
        self.marks = marks
        self.correct = correct
        self.expected = expected
    }

    /// Zero to one. An empty phrase scores one: there was nothing to get
    /// wrong, and dividing by zero to say otherwise would be arithmetic
    /// masquerading as judgement.
    public var accuracy: Double {
        expected == 0 ? 1 : Double(correct) / Double(expected)
    }

    public var isPerfect: Bool {
        correct == expected && marks.allSatisfy { !$0.outcome.isError }
    }

    public func count(of outcome: DictationOutcome) -> Int {
        marks.count { $0.outcome == outcome }
    }
}

/// Checks what a learner typed against what was said.
///
/// ### Punctuation and spacing are not the exercise
///
/// Both sides are reduced to the characters a learner actually heard — Han,
/// Latin and digits — before anything is compared. Whether they typed 。 or
/// ，, or nothing at all, is a transcription convention; it is not evidence
/// about their ears. It is also unfair in a way that compounds: a learner
/// typing through a Chinese IME gets punctuation inserted for them, so
/// scoring it would mark some of them down for their keyboard.
///
/// ### Three kinds of wrong
///
/// Where a character is wrong, the dictionary already open is asked what
/// both characters sound like, through `DictionaryLookup.readings(forCharacter:)`.
/// Sharing a reading with its tone is a homophone; sharing only the syllable
/// is a tone slip; sharing nothing is a mishearing. That is the whole reason
/// for building this inside HanReader rather than using a general-purpose
/// dictation tool — the readings are already here.
public enum DictationComparison {
    /// Compares an attempt against the expected text.
    ///
    /// - Parameter readings: consulted only for characters that did not
    ///   match, which on a good attempt is almost none.
    public static func check(
        typed: String,
        against expected: String,
        readings: (Character) -> [CharacterReading] = { _ in [] },
    )
        -> DictationResult
    {
        let expectedCharacters = scorable(expected)
        let typedCharacters = scorable(typed)

        let steps = SequenceAlignment.align(
            reference: expectedCharacters.map(\.character),
            candidate: typedCharacters.map(\.character),
        )

        let marks = steps.compactMap {
            mark(for: $0, expected: expectedCharacters, typed: typedCharacters, readings: readings)
        }
        return DictationResult(
            marks: marks,
            correct: marks.count { $0.outcome == .correct },
            expected: expectedCharacters.count,
        )
    }

    /// Turns one alignment step into something renderable.
    private static func mark(
        for step: AlignmentStep,
        expected: [Scorable],
        typed: [Scorable],
        readings: (Character) -> [CharacterReading],
    )
        -> DictationMark?
    {
        switch step.operation {
        case .match:
            guard let index = step.reference else { return nil }
            return DictationMark(
                outcome: .correct,
                expected: expected[index].character,
                typed: expected[index].character,
                offset: expected[index].offset,
            )
        case .substitute:
            guard let index = step.reference, let other = step.candidate else { return nil }
            return DictationMark(
                outcome: outcome(
                    typed: typed[other].character,
                    expected: expected[index].character,
                    readings: readings,
                ),
                expected: expected[index].character,
                typed: typed[other].character,
                offset: expected[index].offset,
            )
        case .delete:
            guard let index = step.reference else { return nil }
            return DictationMark(
                outcome: .missing,
                expected: expected[index].character,
                typed: nil,
                offset: expected[index].offset,
            )
        case .insert:
            guard let index = step.candidate else { return nil }
            return DictationMark(
                outcome: .extra,
                expected: nil,
                typed: typed[index].character,
                offset: nil,
            )
        }
    }

    /// Which kind of wrong a substitution is.
    static func outcome(
        typed: Character,
        expected: Character,
        readings: (Character) -> [CharacterReading],
    )
        -> DictationOutcome
    {
        // No early-out for a character the dictionaries do not know: an empty
        // set is disjoint from everything, so both tiers below already fall
        // through to `.misheard`. A guard saying so would read as though it
        // were load-bearing.
        let typedReadings = readings(typed)
        let expectedReadings = readings(expected)

        // Compared case-insensitively: a surname is written `Zhen1` and is
        // the same sound as `zhen1`. Treating those as different readings
        // would call 真/针 a mishearing whenever one of them happened to be
        // a surname, which for single characters is most of them.
        let typedNumeric = Set(typedReadings.map { $0.numeric.lowercased() })
        let expectedNumeric = Set(expectedReadings.map { $0.numeric.lowercased() })
        if !typedNumeric.isDisjoint(with: expectedNumeric) {
            return .homophone
        }

        let typedBases = Set(typedReadings.compactMap { base(of: $0.numeric) })
        let expectedBases = Set(expectedReadings.compactMap { base(of: $0.numeric) })
        if !typedBases.isDisjoint(with: expectedBases) {
            return .toneSlip
        }
        return .misheard
    }

    /// The syllable without its tone digit. `zhen1` → `zhen`.
    ///
    /// Taken off the numeric spelling rather than re-parsed: the numeric form
    /// is the cross-dictionary key this app already stores everywhere, and
    /// parsing it back into a `PinyinSyllable` to read `.base` would be the
    /// same answer at more cost and with more ways to disagree.
    static func base(of numeric: String) -> String? {
        let trimmed = numeric.lowercased()
        guard let last = trimmed.last else { return nil }
        let base = last.isNumber ? String(trimmed.dropLast()) : trimmed
        return base.isEmpty ? nil : base
    }

    /// A character worth scoring, with where it sits in the original text.
    struct Scorable: Hashable {
        let character: Character
        /// UTF-16 offset into the text it came from.
        let offset: Int
    }

    /// Drops punctuation and whitespace, keeping each survivor's position so
    /// a mark can still be drawn over the right character of the phrase.
    static func scorable(_ text: String) -> [Scorable] {
        var result: [Scorable] = []
        var offset = 0
        for character in text {
            let width = character.utf16.count
            let counts = character.unicodeScalars.contains { scalar in
                switch ScalarClass.classify(scalar) {
                case .han, .latin, .number: true
                case .punctuation, .whitespace, .other: false
                }
            }
            if counts {
                result.append(Scorable(character: character, offset: offset))
            }
            offset += width
        }
        return result
    }
}
