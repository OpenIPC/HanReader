// HanReader — MIT licensed. See LICENSE.

import Foundation
import HanReaderCore
import HanReaderPersistence
import HanReaderPlayback
import Testing
@testable import HanReaderUI

/// Where the reader is in the recording: which phrase opens, which ones the
/// filter keeps, and what moving between them does.
@MainActor
@Suite("Listening practice")
struct PracticeModelTests {
    private typealias Support = PracticeTestSupport

    // MARK: - Which phrase to start on

    /// Reopening a text resumes rather than putting the reader back at the
    /// top of something half done.
    @Test("Opening starts at the first phrase not yet passed")
    func resumesWhereLeftOff() async throws {
        let model = try await Support.practising(attempts: [0: 1, 1: 1])
        await model.load()
        #expect(model.current == 2)
    }

    @Test("A text finished to the end opens at its first phrase")
    func finishedTextOpensAtTheStart() async throws {
        let model = try await Support.practising(attempts: [0: 1, 1: 1, 2: 1])
        await model.load()
        #expect(model.current == 0)
    }

    // MARK: - The replay filter

    /// A phrase is still work if it was graded hard, if it was never
    /// attempted, or if the last attempt did not pass — the replay filter
    /// WorkAudioBook spells as "play only bookmarks".
    @Test("Needing work means graded hard, unattempted, or failed")
    func needsWork() async throws {
        let model = try await Support.practising(grades: [0: .hard], attempts: [0: 1, 1: 0.4])
        await model.load()

        model.filter = .needsWork
        let indices = model.visible.map(\.index)
        #expect(indices.contains(0)) // passed, but graded hard
        #expect(indices.contains(1)) // attempted and failed
        #expect(indices.contains(2)) // never attempted
    }

    @Test("A passed phrase with no hard grade drops out of the filter")
    func passedPhrasesLeaveTheFilter() async throws {
        let model = try await Support.practising(attempts: [0: 1])
        await model.load()
        model.filter = .needsWork
        #expect(!model.visible.map(\.index).contains(0))
    }

    // MARK: - Moving between phrases

    /// Navigation follows the filter, or a reader drilling the hard ones is
    /// marched through the easy ones between them.
    @Test("Moving on skips phrases the filter has excluded")
    func navigationFollowsTheFilter() async throws {
        let model = try await Support.practising(attempts: [1: 1])
        await model.load()
        model.filter = .needsWork
        model.select(0)
        model.advance(by: 1)
        #expect(model.current == 2)
    }

    /// Found on the running app: passing a phrase under the filter dropped
    /// it from the list at once, so moving on counted from the top of what
    /// was left and skipped the phrase that came next.
    @Test("Passing a phrase does not skip the one after it")
    func passingDoesNotSkipAhead() async throws {
        let model = try await Support.practising()
        await model.load()
        model.filter = .needsWork
        model.select(0)
        model.typed = model.text
        await model.check()

        // Still on the list, so the reader can see what they just did and
        // the strip still shows where they are.
        #expect(model.visible.map(\.index).contains(0))

        model.advance(by: 1)
        #expect(model.current == 1)
        // And now that they have moved off it, it is gone.
        #expect(!model.visible.map(\.index).contains(0))
    }

    @Test("Selecting a phrase that is not there changes nothing")
    func selectIgnoresAnUnknownIndex() async throws {
        let model = try await Support.practising()
        await model.load()
        model.typed = "第一句"
        model.select(99)
        #expect(model.current == 0)
        // And it did not clear the field on the way, which is what makes an
        // ignored tap different from a tap on the phrase already open.
        #expect(model.typed == "第一句")
    }

    @Test("Moving past the last phrase stays on it")
    func navigationStopsAtTheEnd() async throws {
        let model = try await Support.practising()
        await model.load()
        model.select(2)
        model.advance(by: 1)
        #expect(model.current == 2)
        model.select(0)
        model.advance(by: -1)
        #expect(model.current == 0)
    }

    @Test("Returning to a phrase shows what was typed before")
    func previousAnswerComesBack() async throws {
        let model = try await Support.practising()
        await model.load()
        model.typed = "第一句话"
        await model.check()
        model.advance(by: 1)
        #expect(model.typed.isEmpty)

        model.advance(by: -1)
        #expect(model.typed == "第一句话")
    }

    // MARK: - Before there are phrases

    @Test("A text with no audio says so rather than offering to listen")
    func noAudio() async throws {
        let services = try AppServices.inMemory()
        guard case let .imported(id) = try await services.library.importText(
            title: "无声",
            content: "没有录音。",
        ) else {
            throw Support.FixtureError.importFailed
        }
        let model = Support.model(textID: id, services: services)
        await model.load()
        #expect(model.phase == .noAudio)
    }

    @Test("A recording nobody has listened to offers to be listened to")
    func audioWithoutPhrasesNeedsAlignment() async throws {
        let (services, id) = try await Support.services(content: Support.content)
        let model = Support.model(textID: id, services: services)
        await model.load()
        #expect(model.phase == .needsAlignment)
    }

    @Test("Only a missing model is offered as something to fix")
    func obstacleRecoverability() {
        #expect(PracticeModel.AlignmentObstacle.modelMissing.canInstall)
        #expect(!PracticeModel.AlignmentObstacle.systemTooOld.canInstall)
        #expect(!PracticeModel.AlignmentObstacle.languageUnsupported.canInstall)
        #expect(!PracticeModel.AlignmentObstacle.failed("…").canInstall)
    }
}
