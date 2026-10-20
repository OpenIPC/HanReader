// HanReader — MIT licensed. See LICENSE.

import Foundation
import Testing
@testable import HanReaderPlayback

private struct Fixture {
    let engine: SpyEngine
    let session: SpySession
    let model: PlaybackModel
}

@MainActor
private func fixture(duration: Double = 100) -> Fixture {
    let engine = SpyEngine()
    let session = SpySession()
    let model = PlaybackModel(engine: engine, session: session)
    model.load(URL(fileURLWithPath: "/tmp/track.m4a"))
    engine.declareDuration(duration)
    return Fixture(engine: engine, session: session, model: model)
}

@MainActor
@Suite("Playback transport")
struct PlaybackModelTests {
    // MARK: - Scrub on commit

    /// The prototype bound the scrubber straight to `player.seek`, so every
    /// drag delta issued a frame-accurate seek; they cancelled each other and
    /// fought the position observer writing the old value back. This is the
    /// test that pins the fix, and it is about counting calls — which is the
    /// whole reason the engine is behind a protocol.
    @Test("A drag issues no seeks at all")
    func draggingIssuesNoSeeks() {
        let bench = fixture()
        bench.model.beginScrub(at: 10)
        for position in stride(from: 11.0, through: 40.0, by: 1) {
            bench.model.scrub(to: position)
        }
        #expect(bench.engine.seeks.isEmpty)
        // And the thumb follows the finger, not the player.
        #expect(bench.model.displayTime == 40)
        #expect(bench.model.isScrubbing)
    }

    @Test("Committing issues exactly one seek")
    func commitIssuesOneSeek() {
        let bench = fixture()
        bench.model.beginScrub(at: 10)
        bench.model.scrub(to: 20)
        bench.model.scrub(to: 30)
        bench.model.endScrub()

        #expect(bench.engine.seeks == [30])
        #expect(!bench.model.isScrubbing)
        #expect(bench.model.displayTime == 30)
    }

    /// The other half of the fight: while the finger is down the engine is
    /// still reporting from where it was, and letting that through is what
    /// made the prototype's thumb jump backwards under the finger.
    @Test("Engine reports are ignored while dragging")
    func reportsAreIgnoredWhileDragging() {
        let bench = fixture()
        bench.engine.tick(3)
        bench.model.beginScrub(at: 50)
        bench.engine.tick(4)
        bench.engine.tick(5)

        #expect(bench.model.displayTime == 50)
        // And the published position is not merely overridden by the finger
        // — it is not written at all, so the bar is not re-rendered once per
        // second by a player that is standing still behind the drag.
        #expect(bench.model.observedTime == 3)
        // The exact playhead still tracks, because a drag that is abandoned
        // must leave the model knowing where the player actually is.
        #expect(bench.model.playhead == 5)
    }

    @Test("A commit outside the track is clamped to it")
    func commitIsClamped() {
        let bench = fixture(duration: 60)
        bench.model.beginScrub(at: 10)
        bench.model.scrub(to: 500)
        bench.model.endScrub()
        #expect(bench.engine.seeks == [60])

        bench.model.beginScrub(at: 10)
        bench.model.scrub(to: -20)
        bench.model.endScrub()
        #expect(bench.engine.seeks == [60, 0])
    }

    /// A drag that never began must not move the playhead — otherwise a
    /// stray gesture delivered after the finger came up seeks the track.
    @Test("Scrubbing without beginning does nothing")
    func scrubWithoutBeginIsIgnored() {
        let bench = fixture()
        bench.model.scrub(to: 42)
        bench.model.endScrub()
        #expect(bench.engine.seeks.isEmpty)
        #expect(bench.model.displayTime == 0)
    }

    // MARK: - Throttled publishing

    /// The display shows `m:ss`. The prototype published ten times a second
    /// to render the same string, on the actor laying out CJK text.
    @Test("The playhead is published at most once a second")
    func publishingIsThrottled() {
        let bench = fixture()
        // Four reports inside one second: the display shows `m:ss`, so there
        // is nothing new to say and nothing should reach the observed value.
        bench.engine.tick(0.25)
        bench.engine.tick(0.5)
        bench.engine.tick(0.75)
        #expect(bench.model.observedTime == 0)

        bench.engine.tick(1.0)
        #expect(bench.model.observedTime == 1.0)

        // And again through the next second.
        bench.engine.tick(1.25)
        bench.engine.tick(1.75)
        #expect(bench.model.observedTime == 1.0)
        bench.engine.tick(2.5)
        #expect(bench.model.observedTime == 2.5)
    }

    /// The throttle is about how *often* a value is published, not about
    /// rounding it: the published time is exact, there is simply at most one
    /// of them per second. The stored playhead tracks every report, so a
    /// reader who stops mid-sentence resumes mid-sentence rather than at the
    /// last whole second.
    @Test("The stored playhead tracks every report, the published one does not")
    func playheadTracksEveryReport() {
        let bench = fixture()
        bench.engine.tick(12.4)
        #expect(bench.model.playhead == 12.4)
        #expect(bench.model.observedTime == 12.4)

        bench.engine.tick(12.8)
        #expect(bench.model.playhead == 12.8)
        // Same second, so nothing new to display.
        #expect(bench.model.observedTime == 12.4)
    }

    // MARK: - The session

    /// Activating a session you are not using interrupts whatever the reader
    /// was listening to, for an app that might never make a sound.
    @Test("The audio session is activated on first play, not on load")
    func sessionIsActivatedLazily() {
        let bench = fixture()
        #expect(bench.session.activations == 0)
        bench.model.play()
        #expect(bench.session.activations == 1)
        bench.model.pause()
        bench.model.play()
        // Still once: it stays active across a pause.
        #expect(bench.session.activations == 1)
    }

    @Test("A session that will not activate does not stop playback")
    func sessionFailureIsNotFatal() {
        let bench = fixture()
        bench.session.failure = CocoaError(.featureUnsupported)
        bench.model.play()
        #expect(bench.model.isPlaying)
        #expect(bench.engine.playCount == 1)
    }

    // MARK: - Transport basics

    @Test("Loading parks the playhead where the reader left it")
    func loadResumesFromStoredPosition() {
        let engine = SpyEngine()
        let model = PlaybackModel(engine: engine, session: SpySession())
        model.load(URL(fileURLWithPath: "/tmp/track.m4a"), startingAt: 42)

        #expect(engine.seeks == [42])
        #expect(model.playhead == 42)
        // And does not start playing: opening a text should not fill the
        // room with sound.
        #expect(!model.isPlaying)
        #expect(engine.playCount == 0)
    }

    @Test("Loading from the start issues no seek")
    func loadFromZeroDoesNotSeek() {
        let engine = SpyEngine()
        let model = PlaybackModel(engine: engine, session: SpySession())
        model.load(URL(fileURLWithPath: "/tmp/track.m4a"))
        #expect(engine.seeks.isEmpty)
    }

    @Test("Playing a finished track starts it again")
    func playAfterFinishRestarts() {
        let bench = fixture(duration: 30)
        bench.model.play()
        bench.engine.onFinish?()
        #expect(!bench.model.isPlaying)
        #expect(bench.model.playhead == 30)

        bench.model.play()
        #expect(bench.engine.seeks == [0])
        #expect(bench.model.isPlaying)
    }

    @Test("Skipping is clamped to the track")
    func skipIsClamped() {
        let bench = fixture(duration: 30)
        bench.model.skip(by: 10)
        #expect(bench.engine.seeks == [10])
        bench.model.skip(by: 100)
        #expect(bench.engine.seeks == [10, 30])
        bench.model.skip(by: -100)
        #expect(bench.engine.seeks == [10, 30, 0])
    }

    @Test("Nothing moves before a track is loaded")
    func emptyTransportIsInert() {
        let engine = SpyEngine()
        let model = PlaybackModel(engine: engine, session: SpySession())
        model.play()
        model.skip(by: 10)
        model.seek(to: 5)
        model.beginScrub(at: 5)
        #expect(engine.playCount == 0)
        #expect(engine.seeks.isEmpty)
        #expect(!model.isPlaying)
        #expect(!model.isScrubbing)
    }

    @Test("A speed change reaches the engine once")
    func rateIsApplied() {
        let bench = fixture()
        let before = bench.engine.rates.count
        bench.model.rate = .slow
        #expect(bench.engine.rates.suffix(1) == [0.75])
        #expect(bench.engine.rates.count == before + 1)
        // Setting the same speed again is not a change.
        bench.model.rate = .slow
        #expect(bench.engine.rates.count == before + 1)
    }

    @Test("Unloading stops the track and releases the session")
    func unloadReleasesTheSession() {
        let bench = fixture()
        bench.model.play()
        bench.model.unload()
        #expect(!bench.model.isPlaying)
        #expect(bench.model.state == .empty)
        #expect(bench.session.deactivations == 1)
    }

    // MARK: - What the lock screen is told

    /// Now-playing info is extrapolated by the system from the last elapsed
    /// time and rate it was given, so pushing on every tick is both wasted
    /// work and a worse lock screen. It must be pushed on transitions.
    @Test("State changes are announced on transitions, not on ticks")
    func stateChangesAreAnnouncedOnTransitions() {
        let bench = fixture()
        var announcements = 0
        bench.model.onStateChange = { announcements += 1 }

        bench.model.play()
        #expect(announcements == 1)

        for second in 1 ... 8 {
            bench.engine.tick(Double(second))
        }
        #expect(announcements == 1)

        bench.model.pause()
        #expect(announcements == 2)
        bench.model.seek(to: 12)
        #expect(announcements == 3)
        bench.model.rate = .fast
        #expect(announcements == 4)
    }
}

@Suite("Playback rate")
struct PlaybackRateTests {
    @Test("Every rate has a label and normal speed reads as 1×")
    func labels() {
        #expect(PlaybackRate.normal.label == "1×")
        #expect(PlaybackRate.half.label == "0.5×")
        #expect(PlaybackRate.allCases.allSatisfy { !$0.label.isEmpty })
    }

    /// Ordered slowest to fastest, because the menu is built from
    /// `allCases` and a jumbled speed picker is a bug the compiler cannot
    /// see.
    @Test("Rates are ordered slowest first")
    func ordering() {
        let rates = PlaybackRate.allCases.map(\.rawValue)
        #expect(rates == rates.sorted())
    }
}

/// Everything about who is allowed to resume narration, and when.
///
/// Its own suite because the rules are not obvious and there are several:
/// the system may take the audio away and give it back, a spoken word may
/// duck it, and the reader may simply have pressed pause — and only one of
/// those three is allowed to undo each of the others.
@MainActor
@Suite("Playback interruptions")
struct PlaybackInterruptionTests {
    @Test("An interruption pauses, and its end resumes")
    func interruptionResumes() {
        let bench = fixture()
        bench.model.play()
        bench.session.interrupt(.began)
        #expect(!bench.model.isPlaying)
        bench.session.interrupt(.ended)
        #expect(bench.model.isPlaying)
    }

    /// Audio the reader paused themselves must stay paused: a phone call
    /// ending is not permission to start something they stopped.
    @Test("An interruption does not resume audio the reader paused")
    func deliberatePauseIsNotResumed() {
        let bench = fixture()
        bench.model.play()
        bench.model.pause()
        bench.session.interrupt(.began)
        bench.session.interrupt(.ended)
        #expect(!bench.model.isPlaying)
    }

    /// Unplugging headphones must not play the reader's audio out loud to
    /// the room — and plugging them back in must not start it either.
    @Test("Losing the output pauses, and does not resume")
    func outputGoneDoesNotResume() {
        let bench = fixture()
        bench.model.play()
        bench.session.interrupt(.outputGone)
        #expect(!bench.model.isPlaying)
        bench.session.interrupt(.ended)
        #expect(!bench.model.isPlaying)
    }

    /// Review finding: the output can be lost while already paused by an
    /// interruption, and `.outputGone` returned early without clearing the
    /// interruption's claim — so the interruption ending resumed narration
    /// into a room with no headphones in it.
    @Test("Losing the output while interrupted cancels the resume")
    func outputLostDuringInterruption() {
        let bench = fixture()
        bench.model.play()
        bench.session.interrupt(.began)
        #expect(!bench.model.isPlaying)

        bench.session.interrupt(.outputGone)
        bench.session.interrupt(.ended)
        #expect(!bench.model.isPlaying)
    }

    /// Review finding: an interruption the system never invites us back from
    /// leaves its claim standing. With one shared flag, the next word the
    /// reader tapped ended by resuming narration the system had taken away.
    @Test("A word spoken after an unresumed interruption does not start the narration")
    func speechDoesNotResumeAnInterruption() {
        let bench = fixture()
        bench.model.play()
        // `.began` with no matching `.ended` — a call that was answered.
        bench.session.interrupt(.began)
        #expect(!bench.model.isPlaying)

        // The reader taps a word. Nothing is playing, so there is nothing to
        // duck, and the utterance ending must not start the narration.
        bench.model.pauseForSpeech()
        bench.model.resumeAfterSpeech()
        #expect(!bench.model.isPlaying)
    }

    /// And the converse: ducking for a word must not be undone by a system
    /// interruption ending.
    @Test("An interruption ending does not resume audio ducked for a word")
    func interruptionDoesNotResumeSpeechDucking() {
        let bench = fixture()
        bench.model.play()
        bench.model.pauseForSpeech()
        bench.session.interrupt(.ended)
        #expect(!bench.model.isPlaying)
        // The word finishing is what resumes it.
        bench.model.resumeAfterSpeech()
        #expect(bench.model.isPlaying)
    }

    /// Review finding: a narration replaced by a shorter file left the
    /// parked slider past its own end, and told a lock screen an elapsed
    /// time longer than the track.
    @Test("A position past a newly-known duration is pulled back to it")
    func parkedPositionIsClampedWhenDurationArrives() {
        let engine = SpyEngine()
        let model = PlaybackModel(engine: engine, session: SpySession())
        model.load(URL(fileURLWithPath: "/tmp/short.m4a"), startingAt: 300)
        #expect(model.playhead == 300)

        engine.declareDuration(45)
        #expect(model.playhead == 45)
        #expect(model.observedTime == 45)
    }

    @Test("A position inside the duration is left alone")
    func validParkedPositionSurvives() {
        let engine = SpyEngine()
        let model = PlaybackModel(engine: engine, session: SpySession())
        model.load(URL(fileURLWithPath: "/tmp/long.m4a"), startingAt: 30)
        engine.declareDuration(300)
        #expect(model.playhead == 30)
    }

    // MARK: - Speech

    /// The attached audio is usually the same narration, so hearing the
    /// spoken word over it is confusing rather than merely noisy.
    @Test("Speaking pauses the narration and resumes it after")
    func speechDucksPlayback() {
        let bench = fixture()
        bench.model.play()
        bench.model.pauseForSpeech()
        #expect(!bench.model.isPlaying)
        bench.model.resumeAfterSpeech()
        #expect(bench.model.isPlaying)
    }

    @Test("Speaking over paused audio leaves it paused")
    func speechDoesNotStartPausedAudio() {
        let bench = fixture()
        bench.model.pauseForSpeech()
        bench.model.resumeAfterSpeech()
        #expect(!bench.model.isPlaying)
        #expect(bench.engine.playCount == 0)
    }
}
