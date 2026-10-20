// HanReader — MIT licensed. See LICENSE.

public import Foundation
import HanReaderCore
public import Observation

/// How fast the narration plays.
///
/// A fixed set rather than a continuous slider: this is audio in a language
/// the reader is learning, where the useful range is "slower than a native
/// speaker" to "slightly brisk", and a slider invites fiddling with a value
/// nobody can name.
public enum PlaybackRate: Double, CaseIterable, Sendable, Hashable {
    case half = 0.5
    case slow = 0.75
    case normal = 1.0
    case brisk = 1.25
    case fast = 1.5

    /// For the menu. Not localized: these read as numbers in every language
    /// this app ships in, and `0,75×` in a Russian locale would be a format
    /// applied to something that is not a quantity of anything.
    public var label: String {
        rawValue == 1 ? "1×" : "\(rawValue.formatted(.number.precision(.fractionLength(0 ... 2))))×"
    }
}

/// The per-text audio transport.
///
/// Scene-scoped: one per window, so two windows reading two texts play two
/// tracks, and closing a window stops its own. The prototype had one player
/// hanging off a per-window model, which is the same thing by accident rather
/// than by design.
@Observable
@MainActor
public final class PlaybackModel {
    /// What the transport is showing. Separate from `isPlaying` because a
    /// track that has not loaded yet is not a paused track — the controls
    /// should be disabled rather than look ready.
    public enum State: Equatable, Sendable {
        case empty
        case ready
        case failed(String)
    }

    public private(set) var state: State = .empty
    public internal(set) var isPlaying = false
    public private(set) var duration = 0.0

    /// The playhead, published **at most once a second**.
    ///
    /// The engine reports four times a second; the display shows `m:ss`. The
    /// prototype published every tick straight to the main actor, so the
    /// thread laying out CJK text was woken ten times a second to render a
    /// string that had not changed.
    public internal(set) var observedTime = 0.0

    /// Where the reader's finger is, while it is down.
    ///
    /// The whole of scrub-on-commit. While this is non-nil the engine is not
    /// touched and its reports are ignored, so the thumb follows the finger
    /// instead of fighting a stream of positions from a player that is still
    /// where it was.
    public private(set) var scrubTime: Double?

    /// What the transport draws: the finger if it is down, else the player.
    public var displayTime: Double {
        scrubTime ?? observedTime
    }

    public var isScrubbing: Bool {
        scrubTime != nil
    }

    /// The span being practised, or nil when the whole recording is playing.
    ///
    /// The setter is internal rather than private because phrase playback
    /// lives in its own file, and Swift's `private` reaches extensions in
    /// the same file only. Still closed to callers outside this module,
    /// which is the boundary that matters.
    public internal(set) var segment: Range<Double>?

    /// How a phrase is drilled: how many times through, and how long a gap
    /// to leave after each.
    ///
    /// The gap is the whole point of a drill and the reason this is not just
    /// a loop: it is where the learner says the phrase back, or writes it.
    /// WorkAudioBook spells the same two settings out as "repeat phrase" and
    /// "pause between phrases".
    public struct Drill: Hashable, Sendable {
        public var repeats: Int
        public var gap: Double

        public init(repeats: Int = 1, gap: Double = 0) {
            self.repeats = max(1, repeats)
            self.gap = max(0, gap)
        }

        /// Once through, no gap: pressing play on a phrase.
        public static let once = Self()
    }

    public var drill = Drill.once

    /// Called when a phrase has been played as many times as the drill asks.
    ///
    /// The transport deliberately does not advance by itself. Which phrase
    /// comes next is a question about the text and about what the reader has
    /// already passed, and neither belongs down here.
    public var onSegmentFinished: (() -> Void)?

    @ObservationIgnored var repeatsPlayed = 0
    @ObservationIgnored var drillTask: Task<Void, Never>?

    public var rate: PlaybackRate = .normal {
        didSet {
            guard rate != oldValue else { return }
            engine.setRate(rate.rawValue)
            onStateChange?()
        }
    }

    /// Called when something a lock screen or Control Centre would care about
    /// changed — not on every tick. Updating now-playing info four times a
    /// second is the other half of the same waste as publishing the playhead.
    public var onStateChange: (() -> Void)?

    /// The exact playhead, for persistence. Not the published one, which is
    /// rounded to the second for the display's benefit; a reader who stops
    /// mid-sentence should resume mid-sentence.
    @ObservationIgnored public internal(set) var playhead = 0.0

    /// True when playback was stopped by something other than the reader —
    /// a phone call, headphones unplugged, a word being spoken — so it can be
    /// resumed without resuming audio the reader had deliberately paused.
    /// Paused so a tapped word could be heard over it.
    ///
    /// Two flags rather than one, and that separation is the fix for a real
    /// confusion: a system interruption that never invites us back leaves its
    /// flag set, and with one shared flag the next word the reader tapped
    /// would end by resuming narration the system had taken away.
    @ObservationIgnored var pausedForSpeech = false

    /// Paused by the system — a call, an alarm, another app.
    @ObservationIgnored var pausedByInterruption = false

    @ObservationIgnored let engine: any AudioEngine
    @ObservationIgnored private let session: any PlaybackSession
    @ObservationIgnored private var hasActivatedSession = false

    /// Waits out the gap between repeats.
    ///
    /// Injectable because the alternative is a test that sleeps and hopes.
    /// A fixed sleep just over the gap passes on a fast machine and fails
    /// under parallel execution or on a slower runner — which is exactly
    /// what happened, locally green and red in CI. With the wait supplied,
    /// a test can let it return at once and assert the *order* of what
    /// happens rather than the clock it happens on.
    public typealias Wait = @Sendable (Double) async -> Void

    @ObservationIgnored let wait: Wait

    public init(
        engine: (any AudioEngine)? = nil,
        session: (any PlaybackSession)? = nil,
        wait: @escaping Wait = { seconds in
            try? await Task.sleep(for: .seconds(seconds))
        },
    ) {
        self.engine = engine ?? AVPlayerAudioEngine()
        self.session = session ?? SystemPlaybackSession()
        self.wait = wait
        configure()
    }

    private func configure() {
        engine.onTime = { [weak self] time in self?.report(time) }
        engine.onDuration = { [weak self] seconds in
            guard let self else { return }
            duration = seconds
            // A parked position is clamped once the length is known. A
            // narration replaced by a shorter file would otherwise show a
            // slider past its own end, and tell a lock screen an elapsed
            // time longer than the track.
            if playhead > seconds {
                playhead = seconds
                observedTime = seconds
            }
            onStateChange?()
        }
        engine.onFinish = { [weak self] in self?.finish() }
        session.onInterruption = { [weak self] interruption in
            self?.handle(interruption)
        }
    }

    // MARK: - Loading

    /// Loads a track and parks the playhead where the reader left it.
    ///
    /// Does not start playing. Opening a text should not fill the room with
    /// sound, and the stored playhead is a resume point rather than an
    /// instruction.
    public func load(_ url: URL, startingAt time: Double? = nil) {
        // Before anything else. A repeat still waiting out its gap would
        // otherwise wake against the *new* item, seek it to the old
        // phrase's bounds and start it there — and the finish that followed
        // would be handled as a phrase pass of a phrase from another text.
        cancelDrill()
        segment = nil
        engine.setStopTime(nil)
        engine.load(url)
        state = .ready
        duration = engine.duration
        isPlaying = false
        clearPauseReasons()
        scrubTime = nil
        let start = max(0, time ?? 0)
        playhead = start
        observedTime = start
        if start > 0 {
            engine.seek(to: start)
        }
        engine.setRate(rate.rawValue)
        onStateChange?()
    }

    /// Forgets the track, for a reader who closed the text or removed its
    /// audio.
    public func unload() {
        engine.pause()
        state = .empty
        isPlaying = false
        duration = 0
        observedTime = 0
        playhead = 0
        scrubTime = nil
        clearPauseReasons()
        cancelDrill()
        segment = nil
        engine.setStopTime(nil)
        deactivateSession()
        onStateChange?()
    }

    public func fail(_ message: String) {
        state = .failed(message)
        isPlaying = false
        onStateChange?()
    }

    // MARK: - Transport

    public func play() {
        guard state == .ready else { return }
        // Pressing play during the gap between repeats means "play now", so
        // the repeat that was going to start by itself is abandoned.
        // Without this both happen: the engine is started here and the
        // pending task restarts the phrase a moment later.
        cancelDrill()
        // The session is activated here and nowhere else. Activating it at
        // launch would interrupt whatever the reader was listening to, for an
        // app that might never play a sound.
        activateSession()
        // Pressing play on a finished track starts it again rather than doing
        // nothing, which is what a playhead sitting at the end would mean.
        if duration > 0, playhead >= duration - Self.endOfTrackTolerance {
            seek(to: 0)
        }
        engine.play()
        isPlaying = true
        clearPauseReasons()
        onStateChange?()
    }

    public func pause() {
        // Before the guard, not after it. During the gap between repeats
        // nothing is playing, so a guard on `isPlaying` returns without
        // stopping the pending repeat — and the reader presses pause, hears
        // silence, and then hears the phrase start again. Pausing has to
        // mean "stop", whether or not sound is coming out at this instant.
        cancelDrill()
        // No notification on this path, deliberately. Nothing observable
        // changed — `isPlaying` was already false — and announcing it is a
        // way to recurse for ever: a listener that responds to a state
        // change by pausing would be called by its own pause.
        guard isPlaying else { return }
        engine.pause()
        isPlaying = false
        // Deliberate, so neither the system nor a finished utterance may
        // start it again on the reader's behalf.
        clearPauseReasons()
        onStateChange?()
    }

    public func toggle() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }

    /// Jumps by a number of seconds, clamped to the track.
    public func skip(by seconds: Double) {
        guard state == .ready else { return }
        seek(to: playhead + seconds)
    }

    /// Moves the playhead and tells everyone, in one step.
    public func seek(to time: Double) {
        guard state == .ready else { return }
        // The reader has moved the playhead themselves, so a repeat waiting
        // to drag it back to the phrase's start is no longer what they
        // asked for.
        cancelDrill()
        let target = clamp(time)
        // And moving outside the phrase leaves phrase playback altogether,
        // rather than leaving a stop time that would halt them somewhere
        // unrelated to where they went.
        if let segment, !segment.contains(target) {
            self.segment = nil
            engine.setStopTime(nil)
        }
        engine.seek(to: target)
        playhead = target
        // Published immediately rather than left to the next report, or the
        // thumb springs back to where it was for a quarter of a second.
        observedTime = target
        onStateChange?()
    }

    // MARK: - Scrubbing

    /// The reader's finger went down on the scrubber.
    public func beginScrub(at time: Double) {
        guard state == .ready else { return }
        scrubTime = clamp(time)
    }

    /// The finger moved. **No seek is issued**, by design.
    public func scrub(to time: Double) {
        guard scrubTime != nil else { return }
        scrubTime = clamp(time)
    }

    /// The finger came up, and exactly one seek is issued.
    public func endScrub() {
        guard let target = scrubTime else { return }
        scrubTime = nil
        seek(to: target)
    }

    // MARK: - Speech and interruptions

    /// Ducks the narration while a word is spoken.
    ///
    /// For this app the attached audio is usually the *same* narration, so
    /// hearing the word and the recording at once is confusing rather than
    /// merely noisy. Resumes only if it was this that paused it — a reader
    /// who paused the audio and then tapped a word should not find it
    /// playing again.
    public func pauseForSpeech() {
        guard isPlaying else { return }
        engine.pause()
        isPlaying = false
        pausedForSpeech = true
        onStateChange?()
    }

    /// Resumes only narration that *this* paused for a word.
    public func resumeAfterSpeech() {
        guard pausedForSpeech, state == .ready else { return }
        pausedForSpeech = false
        engine.play()
        isPlaying = true
        onStateChange?()
    }

    // MARK: - Engine reports

    /// Throttles the engine's four-a-second down to the one-a-second the
    /// display can actually show, while keeping `playhead` exact.
    private func report(_ time: Double) {
        playhead = time
        // Ignored while dragging: the engine is still reporting from where it
        // was, and letting that through is what makes a scrubber stutter
        // under the finger.
        guard scrubTime == nil else { return }
        guard Int(time) != Int(observedTime) else { return }
        observedTime = time
    }

    private func finish() {
        // A phrase reaching its own end comes through the same path as a
        // track reaching the end of the file, because `forwardPlaybackEndTime`
        // *is* the end of the item as far as the player is concerned.
        if segment != nil {
            finishSegmentPass()
            return
        }
        engine.pause()
        isPlaying = false
        clearPauseReasons()
        if duration > 0 {
            playhead = duration
            observedTime = duration
        }
        deactivateSession()
        onStateChange?()
    }

    // MARK: - Session

    func activateSession() {
        guard !hasActivatedSession else { return }
        do {
            try session.activate()
            hasActivatedSession = true
        } catch {
            Log.error("playback", "could not activate the audio session: \(error)")
        }
    }

    private func deactivateSession() {
        guard hasActivatedSession else { return }
        session.deactivate()
        hasActivatedSession = false
    }

    func clearPauseReasons() {
        pausedForSpeech = false
        pausedByInterruption = false
    }

    private func clamp(_ time: Double) -> Double {
        guard duration > 0 else { return max(0, time) }
        return min(max(0, time), duration)
    }

    /// How close to the end counts as finished, for deciding whether play
    /// means "resume" or "start again".
    static let endOfTrackTolerance = 0.25
}
