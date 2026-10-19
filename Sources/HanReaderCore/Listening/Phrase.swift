// HanReader — MIT licensed. See LICENSE.

public import Foundation

/// Where a phrase's boundaries came from.
public enum PhraseOrigin: String, Sendable, Hashable, CaseIterable {
    /// Placed by aligning the transcript against speech recognition.
    case recognised
    /// Placed or corrected by the reader.
    ///
    /// Distinguished so that re-aligning a recording can leave alone the
    /// boundaries somebody has already fixed by hand. A reader who drags a
    /// boundary and then re-runs alignment should not have to do it twice.
    case manual
}

/// What the reader thought of a phrase, for deciding what to drill again.
///
/// Three levels, matching WorkAudioBook's EASY/MID/HARD — enough to filter a
/// replay, and deliberately **not** a spaced-repetition schedule. The
/// project's 1.0 scope rules out an SRS, and a grade that only means "show me
/// this one again" keeps the promise.
public enum PhraseGrade: String, Sendable, Hashable, CaseIterable {
    case easy
    case medium
    case hard
}

/// One unit of listening practice: a span of text and the span of recording
/// that says it.
public struct Phrase: Hashable, Sendable, Identifiable {
    /// Position within its text, counting from zero. A phrase has no
    /// identity apart from where it sits, and re-aligning replaces the lot.
    public let index: Int
    /// Seconds into the recording.
    public let start: Double
    public let end: Double
    /// UTF-16 offsets into the text's content — the same unit as
    /// `Token.range` and `ReadingPosition.characterOffset`.
    public let textRange: Range<Int>
    /// How much of this phrase the recogniser matched outright, rather than
    /// had bridged across its own mistakes. Zero to one.
    public let confidence: Double
    public let origin: PhraseOrigin
    public let grade: PhraseGrade?

    public var id: Int {
        index
    }

    public init(
        index: Int,
        start: Double,
        end: Double,
        textRange: Range<Int>,
        confidence: Double = 1,
        origin: PhraseOrigin = .recognised,
        grade: PhraseGrade? = nil,
    ) {
        self.index = index
        self.start = start
        self.end = end
        self.textRange = textRange
        self.confidence = confidence
        self.origin = origin
        self.grade = grade
    }

    public var duration: Double {
        max(0, end - start)
    }

    /// The span to play, as a range the transport can take.
    ///
    /// Empty when the boundaries are the wrong way round, which a
    /// badly-dragged handle can produce. An empty range plays nothing, which
    /// is a great deal better than a range that traps.
    public var audioRange: Range<Double> {
        start < end ? start ..< end : start ..< start
    }

    /// The text of this phrase, out of its document's content.
    public func text(in content: String) -> String {
        let utf16 = Array(content.utf16)
        guard textRange.lowerBound >= 0, textRange.upperBound <= utf16.count else { return "" }
        return String(decoding: utf16[textRange], as: UTF16.self)
    }
}

/// The last attempt at one phrase.
public struct DictationAttempt: Hashable, Sendable {
    public let phraseIndex: Int
    public let typed: String
    public let accuracy: Double
    /// How many times this phrase has been attempted, so a learner can see
    /// that the one they keep failing is the one they keep failing.
    public let attempts: Int
    public let updatedAt: Date

    public init(
        phraseIndex: Int,
        typed: String,
        accuracy: Double,
        attempts: Int,
        updatedAt: Date,
    ) {
        self.phraseIndex = phraseIndex
        self.typed = typed
        self.accuracy = accuracy
        self.attempts = attempts
        self.updatedAt = updatedAt
    }

    /// Whether this attempt is good enough to stop drilling the phrase.
    ///
    /// Not a perfect score: a learner who typed every character correctly but
    /// chose one wrong homophone heard the phrase, and being sent back to it
    /// for an input-method slip teaches nothing about listening.
    public func isPassing(threshold: Double = 1) -> Bool {
        accuracy >= threshold
    }
}
