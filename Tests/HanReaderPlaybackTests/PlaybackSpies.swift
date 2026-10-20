// HanReader — MIT licensed. See LICENSE.

import Foundation
@testable import HanReaderPlayback

/// A player that makes no sound and counts what it was asked to do.
///
/// The transport's hardest requirements are about calls rather than about
/// audio — how many seeks a drag issues, how often state is pushed to a lock
/// screen — and those are assertions only against a spy.
@MainActor
final class SpyEngine: AudioEngine {
    private(set) var seeks: [Double] = []
    /// Whether each seek asked to land exactly, which is what a phrase needs.
    private(set) var exactSeeks: [Bool] = []
    private(set) var playCount = 0
    private(set) var pauseCount = 0
    private(set) var rates: [Double] = []
    private(set) var loaded: [URL] = []
    private(set) var stopTimes: [Double?] = []

    var duration = 0.0
    var currentTime = 0.0

    var onTime: ((Double) -> Void)?
    var onDuration: ((Double) -> Void)?
    var onFinish: (() -> Void)?

    func load(_ url: URL) {
        loaded.append(url)
    }

    func play() {
        playCount += 1
    }

    func pause() {
        pauseCount += 1
    }

    func seek(to time: Double, exactly: Bool) {
        seeks.append(time)
        exactSeeks.append(exactly)
        currentTime = time
    }

    func setRate(_ rate: Double) {
        rates.append(rate)
    }

    func setStopTime(_ time: Double?) {
        stopTimes.append(time)
    }

    /// The player reaching the stop time, which it reports as the end of the
    /// item — the same path a finished track takes.
    func reachEnd() {
        onFinish?()
    }

    /// Delivers a position the way the real engine does, four times a second.
    func tick(_ time: Double) {
        currentTime = time
        onTime?(time)
    }

    func declareDuration(_ seconds: Double) {
        duration = seconds
        onDuration?(seconds)
    }
}

@MainActor
final class SpySession: PlaybackSession {
    private(set) var activations = 0
    private(set) var deactivations = 0
    var failure: (any Error)?
    var onInterruption: ((PlaybackInterruption) -> Void)?

    func activate() throws {
        if let failure {
            throw failure
        }
        activations += 1
    }

    func deactivate() {
        deactivations += 1
    }

    func interrupt(_ interruption: PlaybackInterruption) {
        onInterruption?(interruption)
    }
}
