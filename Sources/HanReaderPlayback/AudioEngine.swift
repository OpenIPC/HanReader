// HanReader — MIT licensed. See LICENSE.

import AVFoundation
public import Foundation
import HanReaderCore

/// The player underneath `PlaybackModel`.
///
/// A seam, and it earns its place: the transport's hardest requirement is
/// about *how many* seeks a drag issues, which is a statement about calls
/// made rather than about sound produced. Against `AVPlayer` that can only be
/// checked by ear; against a spy it is an assertion. The prototype's scrubber
/// issued a frame-accurate seek on every drag delta, and nothing short of
/// counting them catches that.
///
/// Deliberately not an `AsyncSequence` of positions. The engine reports four
/// times a second forever, and a sequence would make cancellation the
/// caller's problem on every path out.
public protocol AudioEngine: AnyObject {
    /// Seconds, or zero until the asset has loaded far enough to say.
    var duration: Double { get }
    var currentTime: Double { get }

    func load(_ url: URL)
    func play()
    func pause()
    func seek(to time: Double)
    /// Applied immediately when playing, and remembered for the next `play()`
    /// when not.
    func setRate(_ rate: Double)

    /// Stop here rather than at the end of the track, or nil to play on.
    ///
    /// Needed because listening practice plays one phrase, and a phrase that
    /// runs a quarter-second into the next one has given the answer away.
    func setStopTime(_ time: Double?)

    /// Called about four times a second while playing. What reaches the UI is
    /// throttled further — see `PlaybackModel.report(_:)`.
    var onTime: ((Double) -> Void)? { get set }
    /// Called once the asset knows how long it is.
    var onDuration: ((Double) -> Void)? { get set }
    var onFinish: (() -> Void)? { get set }
}

/// `AVPlayer`, behind the seam.
final class AVPlayerAudioEngine: AudioEngine {
    /// Four times a second.
    ///
    /// The prototype observed at 10 Hz and published every tick, so the main
    /// actor — the one laying out CJK text — was woken ten times a second to
    /// re-render the same `m:ss` string. Four is already more than the
    /// display needs; `PlaybackModel` throttles what it publishes down to
    /// once a second on top of this.
    static let observationInterval = 0.25

    private let player = AVPlayer()
    private var timeObserver: Any?
    private var finishObserver: (any NSObjectProtocol)?
    private var durationTask: Task<Void, Never>?
    private var rate = 1.0

    /// Unsubscription, captured as a closure so `deinit` can run it.
    ///
    /// `deinit` is nonisolated and this engine is not: the player and its
    /// observer token are neither `Sendable` nor reachable from there. A
    /// closure built on the main actor, holding what it needs, is — and by
    /// the time `deinit` runs nothing else holds this engine, so there is no
    /// concurrent access for the `unsafe` to paper over. It is rebuilt
    /// whenever the observers change.
    private nonisolated(unsafe) var teardown: (() -> Void)?

    private(set) var duration = 0.0

    var currentTime: Double {
        let time = player.currentTime().seconds
        return time.isFinite ? time : 0
    }

    var onTime: ((Double) -> Void)?
    var onDuration: ((Double) -> Void)?
    var onFinish: (() -> Void)?

    init() {
        let interval = CMTime(seconds: Self.observationInterval, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: interval,
            queue: .main,
        ) { [weak self] time in
            let seconds = time.seconds
            guard seconds.isFinite else { return }
            Task { @MainActor [weak self] in
                self?.onTime?(seconds)
            }
        }
        rebuildTeardown()
    }

    deinit {
        teardown?()
    }

    /// Rebuilt rather than appended to, so a reload cannot leave the previous
    /// track's observers to be removed twice.
    private func rebuildTeardown() {
        let player = player
        let time = timeObserver
        let finish = finishObserver
        teardown = {
            if let time {
                player.removeTimeObserver(time)
            }
            if let finish {
                NotificationCenter.default.removeObserver(finish)
            }
        }
    }

    func load(_ url: URL) {
        durationTask?.cancel()
        duration = 0
        if let finishObserver {
            NotificationCenter.default.removeObserver(finishObserver)
        }

        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)
        // Pinned, not fixed. Measured on macOS 26 this is already the
        // default, so M7 was never shipping a chipmunk voice at 0.75 — a
        // claim made in the plan and checked only now. What it does buy is
        // certainty: the documented default has been `.spectral` in the
        // past, this app also runs on macOS 14 and iOS 17, and a recording
        // slowed down for a learner must be a slower voice rather than a
        // deeper one on every one of them. `.timeDomain` is Apple's
        // recommendation for speech and is what WorkAudioBook bundles
        // SoundTouch to do.
        item.audioTimePitchAlgorithm = .timeDomain
        player.replaceCurrentItem(with: item)

        finishObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: item,
            queue: .main,
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.onFinish?()
            }
        }
        rebuildTeardown()

        // Loaded asynchronously rather than read from `item.duration`, which
        // is `indefinite` until the asset has been inspected — and reading it
        // synchronously blocks whichever thread asks.
        durationTask = Task { [weak self] in
            guard let loaded = try? await asset.load(.duration) else { return }
            let seconds = loaded.seconds
            guard seconds.isFinite, seconds > 0 else { return }
            await MainActor.run { [weak self] in
                self?.duration = seconds
                self?.onDuration?(seconds)
            }
        }
    }

    func play() {
        // `rate` doubles as the play command: setting it non-zero starts
        // playback at that speed, which is how a speed setting survives a
        // pause and resume.
        player.rate = Float(rate)
    }

    func pause() {
        player.pause()
    }

    func seek(to time: Double) {
        let target = CMTime(seconds: max(0, time), preferredTimescale: 600)
        // A tolerance, deliberately. The prototype seeked with
        // `toleranceBefore: .zero, toleranceAfter: .zero`, which forces a
        // frame-accurate seek — expensive, and pointless for spoken audio
        // where a tenth of a second is inaudible.
        let tolerance = CMTime(seconds: 0.1, preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: tolerance, toleranceAfter: tolerance)
    }

    func setRate(_ rate: Double) {
        self.rate = rate
        if player.rate != 0 {
            player.rate = Float(rate)
        }
    }

    /// `forwardPlaybackEndTime` rather than watching the clock.
    ///
    /// The time observer reports four times a second, so stopping by hand
    /// overshoots by up to 250 ms — audible, and enough to leak the first
    /// syllable of the next phrase to a learner who is about to be asked to
    /// transcribe it. The player stops itself at exactly this point and
    /// reports it as the end of the item, which is the same path a finished
    /// track already takes.
    func setStopTime(_ time: Double?) {
        guard let item = player.currentItem else { return }
        guard let time else {
            item.forwardPlaybackEndTime = .invalid
            return
        }
        item.forwardPlaybackEndTime = CMTime(seconds: max(0, time), preferredTimescale: 600)
    }
}
