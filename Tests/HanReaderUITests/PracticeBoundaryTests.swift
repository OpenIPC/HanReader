// HanReader — MIT licensed. See LICENSE.

import Foundation
import HanReaderCore
import HanReaderPersistence
import HanReaderPlayback
import Testing
@testable import HanReaderUI

/// Placing phrase boundaries by hand: dragging one, and tapping them all in.
@MainActor
@Suite("Phrase boundaries")
struct PracticeBoundaryTests {
    private typealias Support = PracticeTestSupport

    /// A model over three phrases that meet, with the transport reporting a
    /// known length so the clamps have something to clamp against.
    private func editing() async throws -> (model: PracticeModel, engine: SilentEngine) {
        let (services, id) = try await Support.services(content: Support.content)
        try await services.library.savePhrases(
            (0 ..< 3).map { Support.phrase($0) },
            for: id,
        )
        let engine = SilentEngine()
        let playback = PlaybackModel(engine: engine, session: SilentSession(), wait: { _ in })
        let model = PracticeModel(textID: id, services: services, playback: playback)
        await model.load()
        // The transport learns a recording's length from the engine, and
        // nothing here loads a real file.
        engine.onDuration?(15)
        return (model, engine)
    }

    // MARK: - Dragging one boundary

    @Test("Dragging a boundary moves the phrase and the one it shares with")
    func draggingMovesBoth() async throws {
        let (model, _) = try await editing()
        model.select(1)
        await model.move(.start, to: 4)

        #expect(model.phrases[0].end == 4)
        #expect(model.phrases[1].start == 4)
    }

    /// Written straight through rather than held until the editor closes: a
    /// correction lost because a sheet was dismissed is a correction the
    /// reader makes twice.
    @Test("A dragged boundary is saved at once")
    func draggingPersists() async throws {
        let (model, _) = try await editing()
        model.select(1)
        await model.move(.start, to: 4)

        let stored = try await model.services.library.phrases(for: model.textID)
        #expect(stored[0].end == 4)
        #expect(stored[1].start == 4)
        // Marked by hand, which is what stops a later re-alignment
        // overwriting it.
        #expect(stored[1].origin == .manual)
    }

    @Test("A drag the rules do not allow changes nothing")
    func impossibleDragChangesNothing() async throws {
        let (model, _) = try await editing()
        model.select(1)
        await model.move(.start, to: 5)

        let stored = try await model.services.library.phrases(for: model.textID)
        #expect(stored.allSatisfy { $0.origin == .recognised })
    }

    /// The editor shows the transcript, because a boundary cannot be placed
    /// without knowing which words it is meant to contain — so opening it
    /// counts as having looked.
    @Test("Opening the editor reveals the phrase")
    func editingReveals() async throws {
        let (model, _) = try await editing()
        #expect(!model.isRevealed)
        model.startEditing()
        #expect(model.isEditing)
        #expect(model.isRevealed)

        model.stopEditing()
        #expect(!model.isEditing)
    }

    @Test("The editor draws context either side of the phrase")
    func editorWindow() async throws {
        let (model, _) = try await editing()
        model.select(1)
        // Phrase 1 runs 5 to 9, so the window is that plus context.
        #expect(model.editorWindow.lowerBound < 5)
        #expect(model.editorWindow.upperBound > 9)
    }

    // MARK: - Without any recognition

    /// For a Mac too old for `SpeechTranscriber`, or a system with no
    /// Chinese speech at all.
    @Test("Splitting without listening gives phrases to tap against")
    func splittingWithoutListening() async throws {
        let (services, id) = try await Support.services(content: Support.content)
        let engine = SilentEngine()
        let model = PracticeModel(
            textID: id,
            services: services,
            playback: PlaybackModel(engine: engine, session: SilentSession(), wait: { _ in }),
        )
        await model.load()
        engine.onDuration?(30)
        #expect(model.phase == .needsAlignment)

        await model.splitWithoutListening()
        #expect(model.phase == .ready)
        #expect(model.phrases.count == 3)
        // Confidence zero throughout, which is what tells the screen these
        // are placeholders rather than answers.
        #expect(model.phrases.allSatisfy { $0.confidence == 0 })
        #expect(model.phrases.last?.end == 30)
        // And the editor is open, because placeholders are the one case
        // where there is nothing to practise until they are fixed.
        #expect(model.isEditing)
    }

    // MARK: - Tapping them in

    @Test("Tapping along starts at the first phrase, from the top of the recording")
    func tapAlongStarts() async throws {
        let (model, engine) = try await editing()
        model.select(2)
        engine.onTime?(7)

        model.beginTapAlong()
        #expect(model.tapping?.next == 1)
        #expect(model.current == 0)
        #expect(model.upcoming?.index == 1)
        // Rewound, or the first tap would place a boundary against whatever
        // the reader happened to be listening to a moment earlier.
        #expect(model.playback.playhead == 0)
    }

    /// A tap is one fact, not two: it closes the phrase that was playing and
    /// opens the next. The fixture's phrases have silence between them, so
    /// this also pins that a tap closes the gap — which is what a reader
    /// tapping sentences in means, and what a drag deliberately does not do.
    @Test("A tap places the boundary where the recording is")
    func tapPlacesABoundary() async throws {
        let (model, engine) = try await editing()
        model.beginTapAlong()
        engine.onTime?(4.5)
        await model.tapBoundary()

        #expect(model.phrases[0].end == 4.5)
        #expect(model.phrases[1].start == 4.5)
        #expect(model.tapping?.next == 2)
        // And the reader is now looking at the phrase they just opened.
        #expect(model.current == 1)
    }

    @Test("Tapping through the last boundary ends it")
    func tapAlongFinishes() async throws {
        let (model, engine) = try await editing()
        model.beginTapAlong()
        engine.onTime?(4.5)
        await model.tapBoundary()
        engine.onTime?(8)
        await model.tapBoundary()

        #expect(model.tapping == nil)
        #expect(model.upcoming == nil)
        #expect(model.phrases[1].end == 8)
        #expect(model.phrases[2].start == 8)
    }

    @Test("A tap with nothing left to place does nothing")
    func tapAfterTheEnd() async throws {
        let (model, engine) = try await editing()
        model.beginTapAlong()
        engine.onTime?(4.5)
        await model.tapBoundary()
        engine.onTime?(8)
        await model.tapBoundary()

        let before = model.phrases
        engine.onTime?(12)
        await model.tapBoundary()
        #expect(model.phrases == before)
    }

    @Test("Stopping leaves the boundaries already placed")
    func cancellingKeepsWhatWasPlaced() async throws {
        let (model, engine) = try await editing()
        model.beginTapAlong()
        engine.onTime?(4.5)
        await model.tapBoundary()
        model.cancelTapAlong()

        #expect(model.tapping == nil)
        let stored = try await model.services.library.phrases(for: model.textID)
        #expect(stored[0].end == 4.5)
        #expect(stored[1].start == 4.5)
        // What was placed is marked by hand; what was merely shuffled out
        // of the way is not, so a later re-alignment is free to replace it.
        #expect(stored[0].origin == .manual)
        #expect(stored[2].origin == .recognised)
    }

    /// The bound lives here and `tapBoundary` goes through it, so this is
    /// the one place it has to hold — including for a position past the end
    /// that the normal run of taps never reaches.
    @Test("A position past the last phrase has nothing upcoming")
    func upcomingIsBounded() async throws {
        let (model, _) = try await editing()
        model.tapping = PracticeModel.TapAlong(next: model.phrases.count)
        #expect(model.upcoming == nil)

        model.tapping = PracticeModel.TapAlong(next: model.phrases.count - 1)
        #expect(model.upcoming?.index == model.phrases.count - 1)
    }

    /// Each tap lays the phrases ahead of it out over the recording that is
    /// left, so stopping needs no tidying up and never leaves a run of
    /// stubs piled up behind the playhead.
    @Test("A tap leaves the phrases ahead of it sharing what is left")
    func tappingLeavesTheRemainderSpread() async throws {
        let (model, engine) = try await editing()
        model.beginTapAlong()
        engine.onTime?(4.5)
        await model.tapBoundary()
        model.cancelTapAlong()

        let stored = try await model.services.library.phrases(for: model.textID)
        // Phrases 1 and 2 share the 10.5 seconds after the tap rather than
        // sitting at the shortest length the rules allow.
        #expect(stored[1].duration > BoundaryEditing.minimumDuration * 2)
        #expect(stored[2].duration > BoundaryEditing.minimumDuration * 2)
        #expect(stored[1].end == stored[2].start)
        #expect(stored.last?.end == 15)
    }

    /// Stopping with nothing tapped must change nothing. The old settling
    /// pass spread from the top of the list, so opening tap-along and
    /// pressing Stop replaced a good alignment with equal slices.
    @Test("Stopping before any tap leaves the alignment alone")
    func stoppingBeforeTappingChangesNothing() async throws {
        let (model, _) = try await editing()
        let before = try await model.services.library.phrases(for: model.textID)
        model.beginTapAlong()
        model.cancelTapAlong()

        let after = try await model.services.library.phrases(for: model.textID)
        #expect(after == before)
    }

    /// A boundary somebody placed is not a guess, however little the
    /// recogniser thought of it — and the warning it carried must not come
    /// back from the database.
    @Test("A corrected phrase stops being flagged uncertain")
    func movingClearsTheWarning() async throws {
        let (services, id) = try await Support.services(content: Support.content)
        try await services.library.savePhrases(
            [
                Phrase(index: 0, start: 0, end: 5, textRange: 0 ..< 4, confidence: 0.1),
                Phrase(index: 1, start: 5, end: 10, textRange: 5 ..< 9, confidence: 0.1),
            ],
            for: id,
        )
        let engine = SilentEngine()
        let model = PracticeModel(
            textID: id,
            services: services,
            playback: PlaybackModel(engine: engine, session: SilentSession(), wait: { _ in }),
        )
        await model.load()
        engine.onDuration?(15)
        model.select(1)
        await model.move(.start, to: 4)

        let stored = try await services.library.phrases(for: id)
        #expect(stored[1].confidence == 1)
    }

    @Test("A text with one phrase has no boundaries to tap")
    func nothingToTap() async throws {
        let (services, id) = try await Support.services(content: "一句话。")
        try await services.library.savePhrases(
            [Phrase(index: 0, start: 0, end: 4, textRange: 0 ..< 4)],
            for: id,
        )
        let model = Support.model(textID: id, services: services)
        await model.load()
        model.beginTapAlong()
        #expect(model.tapping == nil)
    }

    @Test("Closing the screen stops tapping along")
    func closingStopsTapping() async throws {
        let (model, _) = try await editing()
        model.beginTapAlong()
        await model.close()
        #expect(model.tapping == nil)
    }
}
