// HanReader — MIT licensed. See LICENSE.

import Foundation
import HanReaderCore
import HanReaderPersistence
import HanReaderPlayback
import Testing
@testable import HanReaderUI

/// Practising without pressing anything: the answer marks itself when it is
/// finished, a correct one moves on, and arriving at a phrase plays it.
@MainActor
@Suite("Practice flow")
struct PracticeFlowTests {
    private typealias Support = PracticeTestSupport

    /// A model whose waits return at once, so these assert the order things
    /// happen in rather than the clock they happen on.
    private func flowing() async throws -> (model: PracticeModel, engine: SilentEngine) {
        let (services, id) = try await Support.services(content: Support.content)
        try await services.library.savePhrases(
            (0 ..< 3).map { Support.phrase($0) },
            for: id,
        )
        let engine = SilentEngine()
        let playback = PlaybackModel(engine: engine, session: SilentSession(), wait: { _ in })
        let model = PracticeModel(textID: id, services: services, playback: playback)
        model.wait = { _ in }
        await model.load()
        engine.onDuration?(30)
        return (model, engine)
    }

    // MARK: - Knowing when an answer is finished

    @Test("An answer as long as the sentence is finished")
    func completeness() async throws {
        let (model, _) = try await flowing()
        #expect(!model.isAnswerComplete)

        model.typed = "第一句"
        #expect(!model.isAnswerComplete)

        model.typed = "第一句话"
        #expect(model.isAnswerComplete)
    }

    /// Counting what will be scored, not what was typed: an input method
    /// inserting its own punctuation must not hold the check back, and must
    /// not trigger one early either.
    @Test("Punctuation does not count towards being finished")
    func punctuationDoesNotCount() async throws {
        let (model, _) = try await flowing()
        model.typed = "第一句，"
        #expect(!model.isAnswerComplete)
    }

    // MARK: - Checking without being asked

    @Test("Finishing the answer marks it")
    func finishingChecks() async throws {
        let (model, _) = try await flowing()
        model.typed = "第一句"
        await model.answerChanged()
        #expect(model.result == nil)

        model.typed = "第一句话"
        await model.answerChanged()
        #expect(model.result != nil)
        #expect(model.attempts[0]?.typed == "第一句话")
    }

    /// A reader who gave up and read the transcript must not have it marked
    /// for them the moment they copy a character into the field.
    @Test("A revealed phrase is not marked automatically")
    func revealedPhrasesAreNotChecked() async throws {
        let (model, _) = try await flowing()
        model.reveal()
        model.typed = model.text
        await model.answerChanged()
        #expect(model.result == nil)
    }

    @Test("An answer already marked is not marked again")
    func noSecondCheck() async throws {
        let (model, _) = try await flowing()
        model.typed = model.text
        await model.answerChanged()
        let attempts = model.attempts[0]?.attempts

        model.typed = model.text + "话"
        await model.answerChanged()
        #expect(model.attempts[0]?.attempts == attempts)
    }

    /// A phrase with nothing in it is not an answer waiting to be marked.
    /// Without this, an empty sentence counts as finished the moment the
    /// screen opens.
    @Test("A phrase with no text is never finished")
    func emptyPhraseIsNotComplete() async throws {
        let (services, id) = try await Support.services(content: Support.content)
        let model = Support.model(textID: id, services: services)
        await model.load()
        #expect(model.text.isEmpty)
        #expect(!model.isAnswerComplete)
    }

    // MARK: - Moving on

    @Test("A correct answer moves to the next phrase by itself")
    func correctAnswerAdvances() async throws {
        let (model, _) = try await flowing()
        model.typed = model.text
        await model.answerChanged()
        await model.awaitPendingAdvance()
        #expect(model.current == 1)
    }

    /// A wrong answer stays put. The marking is the point of the exercise
    /// and taking it away unasked is the one thing worse than an extra
    /// button.
    @Test("A wrong answer stays where it is")
    func wrongAnswerStays() async throws {
        let (model, _) = try await flowing()
        model.typed = "第二句话"
        await model.answerChanged()
        await model.awaitPendingAdvance()
        #expect(model.current == 0)
        #expect(model.result != nil)
    }

    @Test("The last phrase does not move on")
    func lastPhraseStays() async throws {
        let (model, _) = try await flowing()
        model.select(2)
        model.typed = model.text
        await model.answerChanged()
        await model.awaitPendingAdvance()
        #expect(model.current == 2)
    }

    /// Moving by hand during the pause after a correct answer wins. The
    /// automatic move is a convenience and must never fight the reader.
    @Test("Moving by hand cancels a pending move")
    func manualMoveWins() async throws {
        let (model, _) = try await flowing()
        model.wait = { _ in try? await Task.sleep(for: .milliseconds(50)) }
        model.typed = model.text
        await model.answerChanged()

        // Moved to phrase 2 themselves while the pause was still running. A
        // stale move would take them on to phrase 3 — one they never asked
        // for and did not see — so phrase 1 is deliberately not the target
        // here: landing there would be indistinguishable from the automatic
        // move having worked.
        model.select(1)
        await model.awaitPendingAdvance()
        try await Task.sleep(for: .milliseconds(120))
        #expect(model.current == 1)
    }

    // MARK: - Playing on arrival

    @Test("Arriving at a phrase plays it")
    func arrivalPlays() async throws {
        let (model, _) = try await flowing()
        model.playOnArrival()
        #expect(model.playback.isPlaying)
    }

    /// The editor is for placing boundaries, where arriving somewhere is a
    /// drag rather than a decision to practise.
    @Test("The boundary editor does not play on arrival")
    func editorDoesNotPlay() async throws {
        let (model, _) = try await flowing()
        model.startEditing()
        model.playOnArrival()
        #expect(!model.playback.isPlaying)
    }

    @Test("A phrase already answered does not play again")
    func answeredPhrasesDoNotReplay() async throws {
        let (model, _) = try await flowing()
        model.typed = model.text
        await model.check()
        model.playback.pause()

        model.playOnArrival()
        #expect(!model.playback.isPlaying)
    }
}
