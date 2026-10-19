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
    public private(set) var isPlaying = false
    public private(set) var duration = 0.0

    /// The playhead, published **at most once a second**.
    ///
    /// The engine reports four times a second; the display shows `m:ss`. The
    /// prototype published every tick straight to the main actor, so the
    /// thread laying out CJK text was woken ten times a second to render a
    /// string that had not changed.
    public private(set) var observedTime = 0.0

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
    @ObservationIgnored public private(set) var playhead = 0.0

    /// True when playback was stopped by something other than the reader —
    /// a phone call, headphones unplugged, a word being spoken — so it can be
    /// resumed without resuming audio the reader had deliberately paused.
    @ObservationIgnored private var wasInterrupted = false

    @ObservationIgnored private let engine: any AudioEngine
    @ObservationIgnored private let session: any PlaybackSession
    @ObservationIgnored private var hasActivatedSession = false

    public init(
        engine: (any AudioEngine)? = nil,
        session: (any PlaybackSession)? = nil,
    ) {
        self.engine = engine ?? AVPlayerAudioEngine()
        self.session = session ?? SystemPlaybackSession()
        configure()
    }

    private func configure() {
        engine.onTime = { [weak self] time in self?.report(time) }
        engine.onDuration = { [weak self] seconds in
            guard let self else { return }
            duration = seconds
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
        engine.load(url)
        state = .ready
        duration = engine.duration
        isPlaying = false
        wasInterrupted = false
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
        wasInterrupted = false
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
        wasInterrupted = false
        onStateChange?()
    }

    public func pause() {
        guard isPlaying else { return }
        engine.pause()
        isPlaying = false
        wasInterrupted = false
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
        let target = clamp(time)
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
        wasInterrupted = true
        onStateChange?()
    }

    public func resumeAfterSpeech() {
        guard wasInterrupted, state == .ready else { return }
        engine.play()
        isPlaying = true
        wasInterrupted = false
        onStateChange?()
    }

    private func handle(_ interruption: PlaybackInterruption) {
        switch interruption {
        case .began:
            guard isPlaying else { return }
            engine.pause()
            isPlaying = false
            wasInterrupted = true
            onStateChange?()
        case .ended:
            resumeAfterSpeech()
        case .outputGone:
            // Headphones pulled out. Pausing is not politeness, it is the
            // difference between a quiet room and the reader's audio playing
            // through the speaker to everyone around them — and it must not
            // be resumable automatically, or plugging back in starts it in
            // the open.
            guard isPlaying else { return }
            engine.pause()
            isPlaying = false
            wasInterrupted = false
            onStateChange?()
        }
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
        engine.pause()
        isPlaying = false
        wasInterrupted = false
        if duration > 0 {
            playhead = duration
            observedTime = duration
        }
        deactivateSession()
        onStateChange?()
    }

    // MARK: - Session

    private func activateSession() {
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

    private func clamp(_ time: Double) -> Double {
        guard duration > 0 else { return max(0, time) }
        return min(max(0, time), duration)
    }

    /// How close to the end counts as finished, for deciding whether play
    /// means "resume" or "start again".
    static let endOfTrackTolerance = 0.25
}
