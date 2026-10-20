// HanReader — MIT licensed. See LICENSE.

import Foundation
import HanReaderCore
import HanReaderPersistence
import HanReaderPlayback
import Testing
@testable import HanReaderUI

/// Marking an attempt: when the answer appears, what gets written down, and
/// which score decides whether a phrase is finished.
@MainActor
@Suite("Dictation marking")
struct PracticeCheckingTests {
    private typealias Support = PracticeTestSupport

    // MARK: - Hiding the answer

    /// The answer being on screen is the one thing that makes dictation
    /// worthless, so it is revealed by checking or by giving up, and by
    /// nothing else.
    @Test("The transcript stays hidden until it is checked")
    func transcriptIsHiddenUntilChecked() async throws {
        let model = try await Support.practising()
        await model.load()
        #expect(!model.isRevealed)

        model.typed = "第一句"
        await model.check()
        #expect(model.isRevealed)
    }

    @Test("Moving to another phrase hides the answer again")
    func movingHidesTheAnswerAgain() async throws {
        let model = try await Support.practising()
        await model.load()
        // Checked rather than revealed, so that the marking exists and its
        // disappearance is something the test can actually see.
        model.typed = "第一句"
        await model.check()
        #expect(model.isRevealed)
        #expect(model.result != nil)

        model.advance(by: 1)
        #expect(!model.isRevealed)
        #expect(model.result == nil)
    }

    /// Giving up shows the answer without recording an attempt — a reader
    /// who looked should not be marked as having answered.
    @Test("Giving up reveals without marking")
    func revealingDoesNotRecordAnAttempt() async throws {
        let model = try await Support.practising()
        await model.load()
        model.reveal()
        #expect(model.isRevealed)
        #expect(model.result == nil)
        #expect(model.attempts.isEmpty)
    }

    /// Showing the answer and then copying it demonstrates nothing about
    /// listening, so it must not drop the phrase out of the drill. The
    /// marking still appears — that is what was asked for.
    @Test("Checking after showing the answer marks but does not record")
    func checkingAfterRevealingDoesNotRecord() async throws {
        let model = try await Support.practising()
        await model.load()
        model.reveal()
        model.typed = model.text
        await model.check()

        #expect(model.result?.accuracy == 1)
        #expect(model.attempts.isEmpty)
    }

    @Test("Checking without having looked still records")
    func checkingWithoutRevealingRecords() async throws {
        let model = try await Support.practising()
        await model.load()
        model.typed = model.text
        await model.check()
        #expect(model.attempts[model.current]?.accuracy == 1)
    }

    // MARK: - Checking

    @Test("Checking records the attempt and keeps the marking")
    func checkingRecords() async throws {
        let model = try await Support.practising()
        await model.load()
        model.typed = "第一句话"
        await model.check()

        #expect(model.result != nil)
        #expect(model.attempts[model.current]?.typed == "第一句话")
    }

    /// The stored score is the listening one, so an input-method slip does
    /// not keep a phrase in the drill. That is the contract `isPassing`
    /// documents, and it is only true if the right number is written down.
    @Test("The recorded score is the listening score")
    func recordsTheListeningScore() async throws {
        let model = try await Support.practising()
        await model.load()
        model.typed = model.text
        await model.check()
        #expect(model.attempts[model.current]?.accuracy == 1)
    }

    /// The two scores only differ when a homophone is involved, so this is
    /// the test that can tell them apart — and the one that fails if the
    /// strict score is written down instead.
    @Test("A homophone slip is recorded as heard, not as a mistake")
    func homophoneCountsAsHeard() async throws {
        let (services, id) = try await Support.services(
            content: "我有针。",
            lookup: Support.HomophoneDictionary(),
        )
        try await services.library.savePhrases(
            [Phrase(index: 0, start: 0, end: 4, textRange: 0 ..< 3)],
            for: id,
        )
        let model = Support.model(textID: id, services: services)
        await model.load()
        model.typed = "我有真"
        await model.check()

        #expect(model.result?.count(of: .homophone) == 1)
        // Strictly, one character in three is wrong.
        #expect(model.result?.accuracy != 1)
        // What gets stored is what was heard, which was all of it.
        #expect(model.attempts[0]?.accuracy == 1)
        #expect(model.attempts[0]?.isPassing() == true)
    }

    // MARK: - Grading

    @Test("A grade is recorded and tapping it again clears it")
    func grading() async throws {
        let model = try await Support.practising()
        await model.load()
        await model.grade(.hard)
        #expect(model.phrase?.grade == .hard)

        await model.grade(nil)
        #expect(model.phrase?.grade == nil)
    }
}
