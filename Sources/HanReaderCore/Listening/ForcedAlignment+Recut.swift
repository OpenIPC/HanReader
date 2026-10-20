// HanReader — MIT licensed. See LICENSE.

import Foundation

/// Cutting phrases again once the clock is known.
///
/// Split from `ForcedAlignment` itself because it is a separate idea that
/// only became possible after measuring real material: a character budget
/// stands in for duration while nothing better exists, and once the audio
/// has been listened to there *is* something better.
extension ForcedAlignment {
    // MARK: - Cutting again, by the clock

    /// Re-cuts phrases that turned out too long once their times were known.
    ///
    /// Only at punctuation the text already has, so a phrase never ends
    /// mid-clause — and a phrase with no punctuation left to cut at stays
    /// long rather than being chopped somewhere arbitrary. That happens:
    /// the vocabulary list read out at the end of an exercise is one
    /// unpunctuated minute, and a phrase is a better unit there than a cut
    /// in the middle of a word.
    static func recut(
        _ phrases: [Range<Int>],
        in transcript: String,
        expected: [Timeline.Position],
        anchors: [Int: ClosedRange<Double>],
        maximumDuration: Double,
    )
        -> [Range<Int>]
    {
        let typical = medianDuration(of: anchors)
        // Once for the document, not once per over-long phrase.
        let metrics = PhraseSplitter.Metrics(transcript)
        var result: [Range<Int>] = []
        for phrase in phrases {
            guard span(of: phrase, expected: expected, anchors: anchors)
                .map({ $0.upperBound - $0.lowerBound > maximumDuration }) == true
            else {
                result.append(phrase)
                continue
            }
            let points = cutPoints(
                in: phrase,
                metrics: metrics,
                expected: expected,
                anchors: anchors,
                typical: typical,
            )
            guard !points.isEmpty else {
                result.append(phrase)
                continue
            }
            // Every clause, then packed back up by measured time rather than
            // by a character count standing in for it.
            var pieces: [Range<Int>] = []
            var lower = phrase.lowerBound
            for point in points + [phrase.upperBound] where point > lower {
                pieces.append(lower ..< point)
                lower = point
            }
            result.append(contentsOf: pack(
                pieces,
                expected: expected,
                anchors: anchors,
                maximumDuration: maximumDuration,
            ))
        }
        return result
    }

    /// Where a phrase could be cut: at its own punctuation, and wherever
    /// the speaker paused.
    ///
    /// The pauses come free. A recogniser folds the silence before a
    /// character into that character's own span, so a character taking far
    /// longer than its neighbours is one that followed a gap — on a real
    /// 听力 recording a typical character runs 0.24 s and the first one
    /// after a pause runs 1.8. That is silence detection without decoding a
    /// single sample, and it is what actually rescues this material:
    /// recognised punctuation is sparse, so cutting at punctuation alone
    /// left six phrases in eighteen over the cap.
    static func cutPoints(
        in phrase: Range<Int>,
        metrics: PhraseSplitter.Metrics,
        expected: [Timeline.Position],
        anchors: [Int: ClosedRange<Double>],
        typical: Double,
    )
        -> [Int]
    {
        var points = Set(PhraseSplitter.cutPoints(in: phrase, metrics: metrics))
        let threshold = max(pauseFloor, typical * pauseMultiple)
        for (index, position) in expected.enumerated()
            where phrase.contains(position.offset) && position.offset > phrase.lowerBound
        {
            guard let anchor = anchors[index] else { continue }
            if anchor.upperBound - anchor.lowerBound > threshold {
                // Cut *before* the character, because the silence belongs to
                // the gap and the character starts what comes after it.
                points.insert(position.offset)
            }
        }
        return points.sorted()
    }

    private static func medianDuration(of anchors: [Int: ClosedRange<Double>]) -> Double {
        let durations = anchors.values
            .map { $0.upperBound - $0.lowerBound }
            .filter { $0 > 0 }
            .sorted()
        guard !durations.isEmpty else { return 0 }
        return durations[durations.count / 2]
    }

    /// A gap has to be this long to count, however brisk the speaker. Below
    /// it the "pause" is the natural lengthening at the end of a clause,
    /// which is not somewhere to break.
    static let pauseFloor = 0.6
    /// And this much longer than the speaker's own typical character.
    static let pauseMultiple = 3.0

    private static func pack(
        _ pieces: [Range<Int>],
        expected: [Timeline.Position],
        anchors: [Int: ClosedRange<Double>],
        maximumDuration: Double,
    )
        -> [Range<Int>]
    {
        var packed: [Range<Int>] = []
        for piece in pieces {
            guard let last = packed.last else {
                packed.append(piece)
                continue
            }
            let combined = last.lowerBound ..< piece.upperBound
            let duration = span(of: combined, expected: expected, anchors: anchors)
                .map { $0.upperBound - $0.lowerBound } ?? 0
            if duration <= maximumDuration {
                packed[packed.count - 1] = combined
            } else {
                packed.append(piece)
            }
        }
        return packed
    }

    /// When a range was heard, from the first anchored character in it to
    /// the last. Nil when the recogniser anchored none of it, which is the
    /// case re-cutting must leave alone — there is no clock to cut by.
    private static func span(
        of range: Range<Int>,
        expected: [Timeline.Position],
        anchors: [Int: ClosedRange<Double>],
    )
        -> ClosedRange<Double>?
    {
        var found: [ClosedRange<Double>] = []
        for (index, position) in expected.enumerated()
            where range.contains(position.offset)
        {
            if let anchor = anchors[index] {
                found.append(anchor)
            }
        }
        guard let first = found.first, let last = found.last else { return nil }
        return first.lowerBound ... max(first.lowerBound, last.upperBound)
    }
}
