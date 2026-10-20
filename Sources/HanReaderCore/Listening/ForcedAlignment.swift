// HanReader — MIT licensed. See LICENSE.

import Foundation

/// What a speech recogniser heard, and when.
///
/// Deliberately not the recogniser's own type: this module has no business
/// importing Speech, and the alignment below is worth testing against
/// segments written by hand with deliberate mistakes in them — which is the
/// only way to test the case that matters.
public struct RecognisedSpeech: Hashable, Sendable {
    /// One run of recognised text with the span of audio it came from.
    public struct Segment: Hashable, Sendable {
        public let text: String
        public let start: Double
        public let end: Double

        public init(text: String, start: Double, end: Double) {
            self.text = text
            self.start = start
            self.end = end
        }
    }

    public let segments: [Segment]
    /// The recording's full length, for the last phrase to end at.
    public let duration: Double

    public init(segments: [Segment], duration: Double) {
        self.segments = segments
        self.duration = duration
    }
}

/// Works out where each phrase of a transcript is said in a recording.
///
/// ### The recogniser does not have to be right
///
/// This is forced alignment, not transcription: the words are already known.
/// What the recogniser supplies is *timing*, and it supplies that even where
/// it misheard — a character it got wrong sits between characters it got
/// right, and those carry the clock across it. A recogniser that is 80%
/// accurate still places every phrase, because the 20% it fluffed is bridged
/// rather than trusted.
///
/// That is also why `confidence` is reported per phrase: it is the share of
/// a phrase's characters the recogniser actually matched, so a phrase whose
/// timing was mostly inferred can be offered to the reader for checking
/// instead of silently believed.
///
/// ### Why it reuses the dictation scorer's alignment
///
/// Lining up a transcript against a recognition is the same operation as
/// lining up a transcript against what a learner typed. `SequenceAlignment`
/// does both, which is why the two halves of this milestone are one piece of
/// work rather than two.
public enum ForcedAlignment {
    /// Places each phrase in the recording.
    ///
    /// - Parameters:
    ///   - phrases: UTF-16 ranges into `transcript`, from `PhraseSplitter`.
    ///   - recognised: what the recogniser heard, in order.
    /// - Returns: one `Phrase` per range, in the same order, with times that
    ///   never run backwards.
    /// - Parameter maximumDuration: a phrase longer than this is cut again
    ///   at its own punctuation, now that the clock is known. A character
    ///   budget is only a proxy for duration and a poor one on material with
    ///   pauses: on a real 听力 recording, eighteen characters came to ten
    ///   seconds and six phrases in eighteen ran past the cap, the longest
    ///   at thirty. Pass nil to keep whatever was handed in.
    public static func align(
        phrases: [Range<Int>],
        in transcript: String,
        to recognised: RecognisedSpeech,
        maximumDuration: Double? = 7,
    )
        -> [Phrase]
    {
        let expected = Timeline.scorable(transcript)
        let heard = Timeline(recognised)

        guard !expected.isEmpty, !heard.characters.isEmpty else {
            return spread(phrases, across: recognised.duration)
        }

        let steps = SequenceAlignment.align(
            reference: expected.map(\.character),
            candidate: heard.characters,
        )

        // Transcript character index -> the time it was heard at. Only
        // matched characters are anchors; a substitution is the recogniser
        // guessing, and its timing is no better than its reading.
        var anchors: [Int: ClosedRange<Double>] = [:]
        for step in steps where step.operation == .match {
            guard let reference = step.reference, let candidate = step.candidate else { continue }
            anchors[reference] = heard.span(of: candidate)
        }

        var ranges = phrases
        if let maximumDuration {
            ranges = recut(
                ranges,
                in: transcript,
                expected: expected,
                anchors: anchors,
                maximumDuration: maximumDuration,
            )
        }
        return place(
            ranges,
            expected: expected,
            anchors: anchors,
            duration: recognised.duration,
        )
    }

    // MARK: - Placing

    private static func place(
        _ phrases: [Range<Int>],
        expected: [Timeline.Position],
        anchors: [Int: ClosedRange<Double>],
        duration: Double,
    )
        -> [Phrase]
    {
        // Which scorable characters fall in each phrase. Both lists are in
        // order, so this is one walk rather than a search per phrase.
        var bounds: [(lower: Int, upper: Int)] = []
        var cursor = 0
        for phrase in phrases {
            while cursor < expected.count, expected[cursor].offset < phrase.lowerBound {
                cursor += 1
            }
            let lower = cursor
            var upper = cursor
            while upper < expected.count, expected[upper].offset < phrase.upperBound {
                upper += 1
            }
            bounds.append((lower, upper))
        }

        let anchored = anchors.keys.sorted()
        var placed: [Phrase] = []
        var previousEnd = 0.0
        for (index, phrase) in phrases.enumerated() {
            let (lower, upper) = bounds[index]
            let matched = (lower ..< upper).compactMap { anchors[$0] }
            let confidence = upper > lower ? Double(matched.count) / Double(upper - lower) : 0

            // A phrase the recogniser matched nothing in gets a slot between
            // its neighbours rather than a zero-length one at the start of
            // the recording, which would be unplayable and look like a bug.
            var start = matched.first?.lowerBound ?? previousEnd
            var end = matched.last?.upperBound ?? start

            // Characters the recogniser misheard at a phrase's edge are
            // still *said* in the recording, and anchoring only on matches
            // cuts them off: a phrase whose first character was misheard
            // begins after that character has been spoken, and the reader
            // hears it clipped. Reach out to where the neighbouring content
            // actually ends and begins instead.
            if !matched.isEmpty {
                if let first = (lower ..< upper).first(where: { anchors[$0] != nil }),
                   first > lower,
                   let previous = anchored.last(where: { $0 < lower }),
                   let span = anchors[previous]
                {
                    start = min(start, span.upperBound)
                }
                if let last = (lower ..< upper).last(where: { anchors[$0] != nil }),
                   last < upper - 1,
                   let next = anchored.first(where: { $0 >= upper }),
                   let span = anchors[next]
                {
                    end = max(end, span.lowerBound)
                }
            }

            placed.append(Phrase(
                index: index,
                start: start,
                end: end,
                textRange: phrase,
                confidence: confidence,
                origin: .recognised,
            ))
            previousEnd = end
        }
        return tidy(placed, duration: duration)
    }

    /// Makes the times playable: ordered, non-overlapping, inside the
    /// recording, and with nothing of zero length.
    ///
    /// The alignment can produce all four problems honestly — a phrase whose
    /// only anchor is one character has start equal to end, and two phrases
    /// sharing an anchor overlap. A transport handed those would play
    /// silence or play the neighbour's words, and the reader would blame
    /// their ears.
    static func tidy(_ phrases: [Phrase], duration: Double) -> [Phrase] {
        guard !phrases.isEmpty else { return [] }
        let limit = duration > 0 ? duration : phrases.map(\.end).max() ?? 0

        var result: [Phrase] = []
        var floor = 0.0
        for (offset, phrase) in phrases.enumerated() {
            var start = min(max(phrase.start, floor), limit)
            var end = min(max(phrase.end, start), limit)

            // Borrow from the next phrase's start, so a phrase the
            // recogniser never anchored is still long enough to hear.
            if end <= start {
                let next = offset + 1 < phrases.count ? phrases[offset + 1].start : limit
                end = min(max(next, start + minimumDuration), limit)
            }
            // And then once more, unconditionally. Stretching one phrase
            // moves the floor under the next, which can squeeze *it* below
            // the minimum — so the repair has to run forward, not just on
            // the phrase that was short to begin with. Without this a
            // recogniser that anchored almost nothing produced a run of
            // phrases a transport seeks past without a sound.
            if end - start < minimumDuration {
                end = min(start + minimumDuration, limit)
            }
            // At the very end of a short recording there is nothing left to
            // stretch into, so take the span out of the silence before it —
            // but never back past the phrase before, or two phrases replay
            // the same audio and the reader transcribes the same words
            // twice without being told why.
            if end - start < minimumDuration {
                start = max(floor, max(0, end - minimumDuration))
                end = max(end, start)
            }

            result.append(Phrase(
                index: offset,
                start: start,
                end: end,
                textRange: phrase.textRange,
                confidence: phrase.confidence,
                origin: phrase.origin,
                grade: phrase.grade,
            ))
            floor = end
        }
        return result
    }

    /// No recognition at all: hand out equal slices so the reader can still
    /// step through and fix the boundaries by hand.
    ///
    /// Confidence zero throughout, which is what tells the UI to offer the
    /// boundary editor rather than present these as answers.
    static func spread(_ phrases: [Range<Int>], across duration: Double) -> [Phrase] {
        guard !phrases.isEmpty else { return [] }
        let slice = (duration > 0 ? duration : 0) / Double(phrases.count)
        return phrases.enumerated().map { index, range in
            Phrase(
                index: index,
                start: Double(index) * slice,
                end: Double(index + 1) * slice,
                textRange: range,
                confidence: 0,
                origin: .recognised,
            )
        }
    }

    /// Shortest span worth calling a phrase. Below this a transport seeks and
    /// stops before any sound reaches the speaker.
    static let minimumDuration = 0.25
}

// MARK: - Flattening what was heard

extension ForcedAlignment {
    /// The recogniser's segments as one character sequence with a clock
    /// attached.
    struct Timeline {
        /// One character of the transcript, and where it sits in the text.
        struct Position: Hashable {
            let character: Character
            /// UTF-16 offset, so a phrase's range can be compared against it.
            let offset: Int
        }

        let characters: [Character]
        /// Time span of each character in `characters`.
        private let spans: [ClosedRange<Double>]

        init(_ recognised: RecognisedSpeech) {
            var characters: [Character] = []
            var spans: [ClosedRange<Double>] = []
            for segment in recognised.segments {
                let scorable = Self.scorable(segment.text).map(\.character)
                guard !scorable.isEmpty else { continue }
                // Spread the segment's span evenly across its characters.
                // Apple's Chinese segments are words, so a four-character
                // segment covering 0.8 s puts each character within 200 ms —
                // far finer than a phrase boundary needs.
                let span = max(0, segment.end - segment.start)
                let step = span / Double(scorable.count)
                for (index, character) in scorable.enumerated() {
                    let start = segment.start + Double(index) * step
                    characters.append(character)
                    spans.append(start ... (start + step))
                }
            }
            self.characters = characters
            self.spans = spans
        }

        func span(of index: Int) -> ClosedRange<Double> {
            spans.indices.contains(index) ? spans[index] : 0 ... 0
        }

        /// Characters worth aligning, with where each sits in the text.
        ///
        /// Punctuation and spacing are dropped from both sides: a recogniser
        /// invents its own punctuation, and matching the transcript's commas
        /// against it would be aligning two different authors' habits rather
        /// than the same speech.
        static func scorable(_ text: String) -> [Position] {
            var result: [Position] = []
            var offset = 0
            for character in text {
                let width = character.utf16.count
                let keep = character.unicodeScalars.contains { scalar in
                    switch ScalarClass.classify(scalar) {
                    case .han, .latin, .number: true
                    case .punctuation, .whitespace, .other: false
                    }
                }
                if keep {
                    result.append(Position(character: character, offset: offset))
                }
                offset += width
            }
            return result
        }
    }
}
