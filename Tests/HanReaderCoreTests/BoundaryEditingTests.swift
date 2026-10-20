// HanReader — MIT licensed. See LICENSE.

import Foundation
import HanReaderCore
import Testing

@Suite("Moving a phrase boundary")
struct BoundaryEditingTests {
    /// Three phrases that meet, which is what alignment usually emits.
    private func abutting() -> [Phrase] {
        [
            Phrase(index: 0, start: 0, end: 5, textRange: 0 ..< 5),
            Phrase(index: 1, start: 5, end: 10, textRange: 5 ..< 10),
            Phrase(index: 2, start: 10, end: 15, textRange: 10 ..< 15),
        ]
    }

    /// The same three with silence left out between them, which alignment
    /// also emits wherever the speaker paused.
    private func spaced() -> [Phrase] {
        [
            Phrase(index: 0, start: 0, end: 4, textRange: 0 ..< 5),
            Phrase(index: 1, start: 5, end: 9, textRange: 5 ..< 10),
            Phrase(index: 2, start: 10, end: 14, textRange: 10 ..< 15),
        ]
    }

    private func move(
        _ boundary: PhraseBoundary,
        of index: Int,
        to time: Double,
        in phrases: [Phrase],
        duration: Double = 15,
    )
        -> [Phrase]
    {
        BoundaryEditing.move(boundary, of: index, to: time, in: phrases, duration: duration)
    }

    // MARK: - A boundary two phrases share

    /// Where two phrases meet, the line between them is one thing. Moving
    /// only one side would open a gap, or an overlap, that the reader never
    /// asked for and would then have to repair from the other phrase.
    @Test("Dragging a shared start moves the phrase before it too")
    func sharedStartMovesBoth() {
        let moved = move(.start, of: 1, to: 4, in: abutting())
        #expect(moved.map(\.index) == [0, 1])
        #expect(moved[0].end == 4)
        #expect(moved[1].start == 4)
    }

    @Test("Dragging a shared end moves the phrase after it too")
    func sharedEndMovesBoth() {
        let moved = move(.end, of: 1, to: 11, in: abutting())
        #expect(moved.map(\.index) == [1, 2])
        #expect(moved[0].end == 11)
        #expect(moved[1].start == 11)
    }

    // MARK: - A gap between two phrases

    /// Silence the alignment deliberately left out is not a boundary to
    /// share. Here the handles are independent and a drag stops at the
    /// neighbour rather than pushing it.
    @Test("Across a gap only the dragged phrase moves")
    func gapLeavesTheNeighbourAlone() {
        let moved = move(.start, of: 1, to: 4.5, in: spaced())
        #expect(moved.map(\.index) == [1])
        #expect(moved[0].start == 4.5)
    }

    @Test("A drag across a gap stops at the neighbour")
    func gapClampsAtTheNeighbour() {
        let moved = move(.start, of: 1, to: 1, in: spaced())
        #expect(moved.map(\.index) == [1])
        // Phrase 0 ends at 4, so phrase 1 cannot start before it.
        #expect(moved[0].start == 4)
    }

    // MARK: - What a drag may not do

    @Test("A phrase cannot be dragged shorter than the minimum")
    func minimumDuration() {
        let moved = move(.start, of: 1, to: 9.9, in: abutting())
        #expect(moved.last?.start == 10 - BoundaryEditing.minimumDuration)
        #expect(moved.last?.duration == BoundaryEditing.minimumDuration)
    }

    /// Dragging a shared boundary must not collapse the *neighbour* either,
    /// which is the direction it is easy to forget: the clamp that protects
    /// the phrase being dragged does nothing for the one coming with it.
    @Test("Dragging a shared boundary cannot collapse the neighbour")
    func neighbourKeepsItsMinimum() {
        let moved = move(.start, of: 1, to: 0, in: abutting())
        #expect(moved.first?.index == 0)
        #expect(moved.first?.duration == BoundaryEditing.minimumDuration)
        #expect(moved.last?.start == BoundaryEditing.minimumDuration)
    }

    @Test("A phrase cannot be dragged shorter than the minimum from its end")
    func minimumDurationFromTheEnd() {
        let moved = move(.end, of: 1, to: 5.1, in: abutting())
        #expect(moved.first?.index == 1)
        #expect(moved.first?.end == 5 + BoundaryEditing.minimumDuration)
        #expect(moved.first?.duration == BoundaryEditing.minimumDuration)
    }

    /// The mirror of the start case, and just as easy to forget: the clamp
    /// that protects the phrase being dragged does nothing for the one that
    /// comes with it.
    @Test("Dragging a shared end cannot collapse the next phrase")
    func nextKeepsItsMinimum() {
        let moved = move(.end, of: 1, to: 15, in: abutting())
        #expect(moved.map(\.index) == [1, 2])
        #expect(moved[0].end == 15 - BoundaryEditing.minimumDuration)
        #expect(moved[1].duration == BoundaryEditing.minimumDuration)
    }

    @Test("Across a gap only the dragged phrase's end moves")
    func gapLeavesTheNextPhraseAlone() {
        let moved = move(.end, of: 1, to: 9.5, in: spaced())
        #expect(moved.map(\.index) == [1])
        #expect(moved[0].end == 9.5)
    }

    @Test("The last phrase cannot be dragged past the end of the recording")
    func endOfRecording() {
        let moved = move(.end, of: 2, to: 99, in: spaced(), duration: 15)
        #expect(moved.last?.end == 15)
    }

    @Test("The first phrase cannot be dragged before the start")
    func startOfRecording() {
        // Starting at 2 rather than 0, so there is somewhere to be dragged
        // *from* and the clamp is what stops it rather than the drag being
        // a no-op.
        let phrases = [Phrase(index: 0, start: 2, end: 6, textRange: 0 ..< 5)]
        let moved = move(.start, of: 0, to: -3, in: phrases)
        #expect(moved.last?.start == 0)
    }

    @Test("A drag that changes nothing reports nothing")
    func noChange() {
        #expect(move(.start, of: 1, to: 5, in: abutting()).isEmpty)
        #expect(move(.end, of: 1, to: 10, in: abutting()).isEmpty)
    }

    @Test("A phrase that is not there cannot be dragged")
    func unknownPhrase() {
        #expect(move(.start, of: 99, to: 3, in: abutting()).isEmpty)
    }

    // MARK: - Tapping a boundary in

    /// A tap is a statement about both phrases, made while the recording
    /// plays — so unlike a drag it closes whatever silence the alignment
    /// left between them.
    @Test("A tap closes the gap between two phrases")
    func tapClosesTheGap() {
        let placed = BoundaryEditing.place(boundaryBefore: 1, at: 4.5, in: spaced(), duration: 15)
        #expect(placed[0].end == 4.5)
        #expect(placed[1].start == 4.5)
    }

    @Test("A tap before the previous phrase has begun is held off")
    func tapCannotCollapseThePreviousPhrase() {
        let placed = BoundaryEditing.place(boundaryBefore: 1, at: 0, in: spaced(), duration: 15)
        #expect(placed[0].duration == BoundaryEditing.minimumDuration)
        #expect(placed[1].start == BoundaryEditing.minimumDuration)
    }

    /// The tap decides where the boundary is. It is held off only by the
    /// phrases either side needing a length — never by where a placeholder
    /// split happened to put the phrase being opened, because a spoken
    /// sentence running past its placeholder is the ordinary case.
    @Test("A tap past the end of the recording stops where there is still room")
    func tapStopsWhereThereIsRoom() {
        let placed = BoundaryEditing.place(boundaryBefore: 1, at: 99, in: spaced(), duration: 15)
        // Two phrases still to come, each needing its minimum.
        #expect(placed[0].end == 15 - BoundaryEditing.minimumDuration * 2)
    }

    @Test("A tap past a phrase's placeholder end still lands where it was pressed")
    func tapBeatsThePlaceholder() {
        // Phrase 1's placeholder runs 5 to 9, and the sentence it holds is
        // still being spoken at 11.
        let placed = BoundaryEditing.place(boundaryBefore: 1, at: 11, in: spaced(), duration: 30)
        #expect(placed[0].end == 11)
        #expect(placed[1].start == 11)
    }

    /// A phrase somebody placed is their decision, and a tap in front of it
    /// says nothing about it — which is what keeps stopping part-way from
    /// costing the reader the second half of a good alignment.
    @Test("A tap leaves phrases placed by hand alone")
    func tapLeavesManualPhrasesAlone() {
        let phrases = [
            Phrase(index: 0, start: 0, end: 5, textRange: 0 ..< 5),
            Phrase(index: 1, start: 5, end: 10, textRange: 5 ..< 10),
            Phrase(index: 2, start: 10, end: 15, textRange: 10 ..< 15, origin: .manual),
        ]
        let placed = BoundaryEditing.place(boundaryBefore: 1, at: 3, in: phrases, duration: 15)
        #expect(placed.map(\.index) == [0, 1])
        #expect(placed[1].origin == .manual)
    }

    @Test("The phrases a tap reflows are still guesses")
    func reflowedPhrasesKeepTheirOrigin() {
        let placed = BoundaryEditing.place(boundaryBefore: 1, at: 3, in: spaced(), duration: 15)
        #expect(placed.map(\.index) == [0, 1, 2])
        // The one it opens was placed; the one behind it was only moved out
        // of the way.
        #expect(placed[1].origin == .manual)
        #expect(placed[2].origin == .recognised)
        // And they share what is left rather than stacking up as stubs.
        #expect(placed[1].duration == 6)
        #expect(placed[2].duration == 6)
    }

    /// The first phrase opens where the recording does, so there is no
    /// boundary in front of it to tap.
    @Test("There is no boundary before the first phrase")
    func noBoundaryBeforeTheFirst() {
        #expect(BoundaryEditing.place(boundaryBefore: 0, at: 1, in: spaced(), duration: 15).isEmpty)
    }

    @Test("A tap on a phrase that is not there places nothing")
    func tapOnAnUnknownPhrase() {
        #expect(BoundaryEditing.place(boundaryBefore: 99, at: 1, in: spaced(), duration: 15)
            .isEmpty)
    }

    @Test("A tap exactly where the boundary already is changes nothing")
    func tapOnTheSamePlace() {
        #expect(BoundaryEditing.place(boundaryBefore: 1, at: 5, in: abutting(), duration: 15)
            .isEmpty)
    }

    @Test("A tapped boundary is marked by hand on both sides")
    func tapRecordsItsOrigin() {
        let placed = BoundaryEditing.place(boundaryBefore: 1, at: 4.5, in: spaced(), duration: 15)
        // The two phrases the boundary belongs to. Anything further along
        // was only moved out of the way; `reflowedPhrasesKeepTheirOrigin`
        // is what pins that.
        #expect(placed[0].origin == .manual)
        #expect(placed[1].origin == .manual)
    }

    // MARK: - What a move records

    /// A boundary somebody placed is not a guess, and re-aligning must not
    /// overwrite it — which is what `origin` is for.
    @Test("A moved phrase is marked manual and fully confident")
    func moveRecordsItsOrigin() {
        let phrases = [Phrase(
            index: 0,
            start: 0,
            end: 5,
            textRange: 0 ..< 5,
            confidence: 0.2,
            origin: .recognised,
            grade: .hard,
        )]
        let moved = move(.end, of: 0, to: 6, in: phrases)
        #expect(moved.last?.origin == .manual)
        #expect(moved.last?.confidence == 1)
        // And it is still the same phrase: same words, same grade.
        #expect(moved.last?.textRange == 0 ..< 5)
        #expect(moved.last?.grade == .hard)
    }

    // MARK: - What to draw

    /// A boundary cannot be judged from the phrase alone — the question is
    /// always whether the syllable just outside belongs inside.
    @Test("The window shows context either side of the phrase")
    func windowAddsContext() {
        let window = BoundaryEditing.window(
            around: Phrase(index: 1, start: 5, end: 10, textRange: 5 ..< 10),
            duration: 60,
            context: 1.5,
        )
        #expect(window.lowerBound == 3.5)
        #expect(window.upperBound == 11.5)
    }

    /// At either end of a file the window keeps its width instead of
    /// shrinking, so the strip does not get smaller exactly where a reader
    /// is most likely to be fixing the first or last boundary.
    @Test("The window keeps its width at the ends of the recording")
    func windowKeepsItsWidthAtTheEnds() {
        let first = BoundaryEditing.window(
            around: Phrase(index: 0, start: 0, end: 5, textRange: 0 ..< 5),
            duration: 60,
            context: 1.5,
        )
        #expect(first.lowerBound == 0)
        #expect(first.upperBound - first.lowerBound == 8)

        let last = BoundaryEditing.window(
            around: Phrase(index: 9, start: 55, end: 60, textRange: 0 ..< 5),
            duration: 60,
            context: 1.5,
        )
        #expect(last.upperBound == 60)
        #expect(last.upperBound - last.lowerBound == 8)
    }

    @Test("A window wider than the recording is the whole recording")
    func windowCannotExceedTheRecording() {
        let window = BoundaryEditing.window(
            around: Phrase(index: 0, start: 0, end: 4, textRange: 0 ..< 5),
            duration: 4,
            context: 10,
        )
        #expect(window.lowerBound == 0)
        #expect(window.upperBound == 4)
    }
}
