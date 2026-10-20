// HanReader — MIT licensed. See LICENSE.

import Foundation

/// Which end of a phrase is being dragged.
public enum PhraseBoundary: Sendable, Hashable {
    case start
    case end
}

/// Moving a phrase's boundaries by hand.
///
/// Forced alignment is right most of the time and wrong in a way the reader
/// can hear: a boundary lands half a syllable late and the next phrase opens
/// with the tail of the last word. Correcting that is a drag, and this is the
/// arithmetic behind it — kept here, away from the view, because the rules
/// are about phrases rather than about pixels.
///
/// Nothing here decides *which words* belong to a phrase. Only the times
/// move, which is why `LibraryRepository.movePhrase` writes times alone and
/// marks the phrase `manual` so a later re-alignment leaves it be.
public enum BoundaryEditing {
    /// The shortest a phrase may be dragged down to.
    ///
    /// Not zero: a phrase of no length plays nothing, and a reader who
    /// collapses one by accident has no handle left to pull it back out
    /// with — the two would sit on the same pixel.
    public static let minimumDuration = 0.25

    /// Moves one boundary, keeping an abutting neighbour attached to it.
    ///
    /// Where two phrases touch, the boundary between them is one thing and
    /// not two: alignment emits them that way, and a reader dragging the
    /// line between two sentences means "the first ends here and the second
    /// starts here". Moving only one side would open a silent gap, or an
    /// overlap, that they never asked for and would then have to repair from
    /// the other phrase.
    ///
    /// Where there is already a gap — silence the alignment deliberately
    /// left out — the handles are independent, and a drag is clamped at the
    /// neighbour rather than pushing it.
    ///
    /// - Returns: every phrase whose times changed, in index order. Empty if
    ///   the drag asked for nothing the rules allow.
    public static func move(
        _ boundary: PhraseBoundary,
        of index: Int,
        to time: Double,
        in phrases: [Phrase],
        duration: Double,
    )
        -> [Phrase]
    {
        guard let position = phrases.firstIndex(where: { $0.index == index }) else { return [] }
        let phrase = phrases[position]
        let previous = position > 0 ? phrases[position - 1] : nil
        let next = position < phrases.count - 1 ? phrases[position + 1] : nil

        switch boundary {
        case .start:
            let floor = previous
                .map { abuts($0.end, phrase.start) ? $0.start + minimumDuration : $0.end } ?? 0
            let ceiling = phrase.end - minimumDuration
            guard floor <= ceiling else { return [] }
            let start = time.clamped(to: floor ... ceiling)
            guard start != phrase.start else { return [] }
            var moved = [phrase.moved(start: start, end: phrase.end)]
            if let previous, abuts(previous.end, phrase.start) {
                moved.insert(previous.moved(start: previous.start, end: start), at: 0)
            }
            return moved

        case .end:
            let floor = phrase.start + minimumDuration
            let ceiling = next
                .map { abuts(phrase.end, $0.start) ? $0.end - minimumDuration : $0.start } ??
                duration
            guard floor <= ceiling else { return [] }
            let end = time.clamped(to: floor ... ceiling)
            guard end != phrase.end else { return [] }
            var moved = [phrase.moved(start: phrase.start, end: end)]
            if let next, abuts(phrase.end, next.start) {
                moved.append(next.moved(start: end, end: next.end))
            }
            return moved
        }
    }

    /// Places the boundary between two phrases at one time.
    ///
    /// Different from dragging, and deliberately so. A drag is a correction
    /// to one phrase and stops at its neighbour, leaving any silence the
    /// alignment excluded where it is. A tap is a statement about *both*
    /// phrases — "the last one ended here and this one starts here" — made
    /// while the recording plays, so it closes whatever gap was there. A
    /// reader tapping sentences in has no way to express "and leave 300
    /// milliseconds of silence between them", and no reason to want to.
    ///
    /// - Parameter index: the phrase the boundary opens. Phrase zero opens
    ///   at the start of the recording and has no boundary before it.
    /// - Returns: both phrases, or nothing if the tap asked for something
    ///   the rules do not allow.
    public static func place(
        boundaryBefore index: Int,
        at time: Double,
        in phrases: [Phrase],
        duration: Double,
    )
        -> [Phrase]
    {
        guard let position = phrases.firstIndex(where: { $0.index == index }), position > 0 else {
            return []
        }
        let previous = phrases[position - 1]
        let tail = Array(phrases[position...])

        // The tap decides where the boundary is. It is held off only by the
        // phrase behind it needing a length, and by the phrases ahead of it
        // needing one each — never by where a placeholder split happened to
        // put the phrase being opened. A spoken sentence that runs past its
        // placeholder is the ordinary case, not the exception, and pinning
        // the tap to the placeholder would record the boundary somewhere
        // the reader did not press.
        let floor = previous.start + minimumDuration
        let ceiling = duration - minimumDuration * Double(tail.count)
        guard floor <= ceiling else { return [] }
        let boundary = time.clamped(to: floor ... ceiling)
        guard boundary != previous.end || boundary != tail[0].start else { return [] }

        var moved = [previous.moved(start: previous.start, end: boundary)]
        moved += reflow(tail, from: boundary, to: duration)
        return moved
    }

    /// Lays the phrases ahead of a tap out over the recording that is left.
    ///
    /// Only the ones nobody has placed. A `manual` phrase further down the
    /// text is somebody's decision and the tap in front of it says nothing
    /// about it, so the reflow stops there — which is also what keeps
    /// stopping part-way from costing the reader the second half of a good
    /// alignment.
    ///
    /// The first phrase is the one the tap opens, so its start is the
    /// boundary and it is `manual`. The rest keep their origin: they are
    /// still guesses, and a later re-alignment should be free to replace
    /// them.
    private static func reflow(
        _ tail: [Phrase],
        from boundary: Double,
        to duration: Double,
    )
        -> [Phrase]
    {
        let reflowed = tail.prefix { $0.origin != .manual }
        // At least the one being opened, even where the next phrase was
        // placed by hand and is therefore left alone.
        let count = max(1, reflowed.count)
        let slice = max(minimumDuration, (duration - boundary) / Double(count))
        return (0 ..< count).map { offset in
            let phrase = tail[offset]
            let start = boundary + Double(offset) * slice
            let end = start + slice
            return offset == 0
                ? phrase.moved(start: start, end: end)
                : phrase.at(start: start, end: end)
        }
    }

    /// Whether two phrases meet rather than merely come close.
    ///
    /// A tolerance rather than equality, because these times have been
    /// through a recogniser, a re-cut and a round trip through SQLite as
    /// doubles. A millisecond is far below anything a reader can hear or
    /// aim at, and treating a one-microsecond gap as a gap would make the
    /// shared-boundary rule fire or not fire unpredictably.
    static func abuts(_ end: Double, _ start: Double) -> Bool {
        abs(start - end) < 0.001
    }

    /// The span of recording to draw around a phrase.
    ///
    /// Context either side, because a boundary cannot be judged from the
    /// phrase alone: the question is always whether the syllable just
    /// outside belongs inside, and a strip cropped to the phrase hides
    /// exactly that. Clamped to the recording, and widened on the other side
    /// when one end runs out, so the window keeps its width at the start and
    /// end of a file instead of shrinking where there is least to see.
    public static func window(
        around phrase: Phrase,
        duration: Double,
        context: Double = 1.5,
    )
        -> Range<Double>
    {
        let width = min(duration, phrase.duration + context * 2)
        guard width > 0 else { return 0 ..< max(duration, minimumDuration) }
        var start = phrase.start - context
        if start < 0 {
            start = 0
        }
        if start + width > duration {
            start = max(0, duration - width)
        }
        return start ..< start + width
    }
}

extension Phrase {
    /// The same phrase at a different place in the recording.
    ///
    /// Marked `manual`, because every caller here is a reader correcting
    /// what the recogniser did, and that is precisely what a later
    /// re-alignment must not overwrite.
    /// The same phrase at new times, with its origin and confidence left
    /// alone — for times that were shuffled on a reader's behalf rather
    /// than chosen by them.
    func at(start: Double, end: Double) -> Phrase {
        Phrase(
            index: index,
            start: start,
            end: end,
            textRange: textRange,
            confidence: confidence,
            origin: origin,
            grade: grade,
        )
    }

    func moved(start: Double, end: Double) -> Phrase {
        Phrase(
            index: index,
            start: start,
            end: end,
            textRange: textRange,
            // A boundary somebody placed is not a guess, whatever the
            // recogniser thought of it beforehand — so the warning triangle
            // goes away once they have fixed it.
            confidence: 1,
            origin: .manual,
            grade: grade,
        )
    }
}

extension Double {
    fileprivate func clamped(to range: ClosedRange<Double>) -> Double {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
