// HanReader — MIT licensed. See LICENSE.

import Foundation
import Testing
@testable import HanReaderPlayback

/// Playing one phrase at a time, which is what listening practice is.
///
/// The spy engine is what makes this testable at all: whether a phrase stops
/// at its own end, how many times it is played, and whether a pause during
/// the silence between repeats really stops it, are all statements about
/// calls rather than about sound.
@MainActor
@Suite("Phrase playback")
struct PhrasePlaybackTests {
    /// Waits for something to become true, rather than sleeping for a
    /// guessed interval and hoping.
    ///
    /// A fixed sleep just over the gap passes here and fails on a slower
    /// machine, which is a flaky test dressed as a timing assertion. The
    /// claim being made is "this happens", not "this happens within 500
    /// milliseconds", so the deadline is generous and the polling is tight.
    private func eventually(
        _ condition: () -> Bool,
        within seconds: Double = 5,
    ) async
        -> Bool
    {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() {
                return true
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    private func fixture(duration: Double = 100) -> (SpyEngine, PlaybackModel) {
        let engine = SpyEngine()
        let model = PlaybackModel(engine: engine, session: SpySession())
        model.load(URL(fileURLWithPath: "/tmp/track.m4a"))
        engine.declareDuration(duration)
        return (engine, model)
    }

    // MARK: - Stopping where the phrase stops

    /// A phrase that runs a quarter-second into the next one has given the
    /// answer away, so the stop is the player's own rather than something
    /// watched for. The time observer reports four times a second, which
    /// would overshoot by up to 250 ms.
    @Test("Playing a phrase sets an exact stop time")
    func phraseStopsAtItsOwnEnd() {
        let (engine, model) = fixture()
        model.play(segment: 12 ..< 17)

        #expect(engine.stopTimes.last == 17)
        #expect(engine.seeks.last == 12)
        #expect(model.isPlaying)
        #expect(model.segment == 12 ..< 17)
        // And the position is published at once, so the transport does not
        // show the previous phrase for a quarter of a second.
        #expect(model.displayTime == 12)
    }

    @Test("Leaving phrase playback restores the whole recording")
    func clearingTheSegmentRemovesTheStopTime() {
        let (engine, model) = fixture()
        model.play(segment: 12 ..< 17)
        model.clearSegment()

        #expect(model.segment == nil)
        #expect(engine.stopTimes.last == .some(nil))
    }

    @Test("Unloading forgets the phrase as well as the track")
    func unloadingClearsTheSegment() {
        let (engine, model) = fixture()
        model.play(segment: 12 ..< 17)
        model.unload()

        #expect(model.segment == nil)
        #expect(!model.isPlaying)
        #expect(engine.stopTimes.last == .some(nil))
    }

    // MARK: - The drill

    /// Once through is pressing play on a phrase, and nothing more should
    /// happen when it ends.
    @Test("A phrase played once stops and says so")
    func playedOnce() {
        let (engine, model) = fixture()
        var finished = 0
        model.onSegmentFinished = { finished += 1 }

        model.play(segment: 12 ..< 17)
        #expect(engine.playCount == 1)
        engine.reachEnd()

        #expect(!model.isPlaying)
        #expect(finished == 1)
        #expect(engine.playCount == 1)
    }

    /// Three times through, with no gap, is three plays and one report at
    /// the end — not three reports.
    @Test("A phrase drilled three times plays three times and reports once")
    func repeatedThreeTimes() async {
        let (engine, model) = fixture()
        var finished = 0
        model.onSegmentFinished = { finished += 1 }

        model.play(segment: 12 ..< 17, drill: .init(repeats: 3, gap: 0))
        #expect(engine.playCount == 1)

        engine.reachEnd()
        await Task.yield()
        #expect(engine.playCount == 2)
        #expect(finished == 0)

        engine.reachEnd()
        await Task.yield()
        #expect(engine.playCount == 3)
        #expect(finished == 0)

        engine.reachEnd()
        #expect(engine.playCount == 3)
        #expect(finished == 1)
        #expect(!model.isPlaying)
    }

    /// Each repeat starts at the beginning of the phrase, not wherever the
    /// previous pass left the playhead.
    @Test("Every repeat seeks back to the start of the phrase")
    func repeatsSeekBack() async {
        let (engine, model) = fixture()
        model.play(segment: 12 ..< 17, drill: .init(repeats: 2, gap: 0))
        engine.reachEnd()
        await Task.yield()

        #expect(engine.seeks.suffix(2) == [12, 12])
    }

    /// The gap is the point of a drill rather than a detail of it: it is
    /// where the learner says the phrase back, or writes it down.
    @Test("A gap between repeats delays the next play")
    func gapDelaysTheNextPass() async {
        let (engine, model) = fixture()
        model.play(segment: 12 ..< 17, drill: .init(repeats: 2, gap: 0.3))
        engine.reachEnd()

        // Immediately after the phrase ends, nothing is playing.
        #expect(!model.isPlaying)
        #expect(engine.playCount == 1)

        #expect(await eventually { engine.playCount == 2 })
        #expect(model.isPlaying)
    }

    /// A reader pressing pause during the silence must not find the phrase
    /// starting again a second later. The transport has to stay stopped.
    @Test("Pausing during the gap stops the drill")
    func pausingDuringTheGapStopsIt() async throws {
        let (engine, model) = fixture()
        model.play(segment: 12 ..< 17, drill: .init(repeats: 3, gap: 0.2))
        engine.reachEnd()
        model.pause()

        // A negative claim, so this one does have to wait — comfortably past
        // the gap, to be sure the repeat did not merely arrive late.
        try await Task.sleep(for: .milliseconds(800))
        #expect(engine.playCount == 1)
        #expect(!model.isPlaying)
    }

    /// And choosing another phrase mid-drill abandons the old one rather
    /// than letting its remaining repeats play over the new one.
    @Test("Starting another phrase abandons the drill in progress")
    func anotherPhraseCancelsTheDrill() async throws {
        let (engine, model) = fixture()
        model.play(segment: 12 ..< 17, drill: .init(repeats: 3, gap: 0.2))
        engine.reachEnd()

        model.play(segment: 30 ..< 35)
        try await Task.sleep(for: .milliseconds(800))

        #expect(model.segment == 30 ..< 35)
        #expect(engine.seeks.last == 30)
        // Two plays: the first phrase once, the second once. The abandoned
        // repeat never happened.
        #expect(engine.playCount == 2)
    }

    @Test("A drill asking for nonsense is clamped rather than trusted")
    func drillSettingsAreClamped() {
        #expect(PlaybackModel.Drill(repeats: 0, gap: -5).repeats == 1)
        #expect(PlaybackModel.Drill(repeats: 0, gap: -5).gap == 0)
    }

    // MARK: - Interaction with the rest of the transport

    /// The whole-track finish path must not fire for a phrase, or the first
    /// phrase of a recording would look like the end of it.
    @Test("A phrase ending is not the recording ending")
    func phraseEndIsNotTrackEnd() {
        let (engine, model) = fixture(duration: 100)
        model.play(segment: 12 ..< 17)
        engine.reachEnd()

        // Not parked at the end of the file.
        #expect(model.playhead < 20)
        #expect(model.segment != nil)
    }

    @Test("Speaking a word still ducks a phrase, and resumes it")
    func speechStillDucks() {
        let (_, model) = fixture()
        model.play(segment: 12 ..< 17)
        model.pauseForSpeech()
        #expect(!model.isPlaying)
        model.resumeAfterSpeech()
        #expect(model.isPlaying)
    }
}
