// HanReader — MIT licensed. See LICENSE.

import Foundation

/// Playing one phrase at a time, which is what listening practice is.
///
/// Separate from the transport's own body because it is a different mode of
/// use: the rest of `PlaybackModel` plays a recording, and this plays a
/// span of one, repeatedly, with silence in between for the learner to
/// write in.
extension PlaybackModel {
    // MARK: - One phrase at a time

    /// Plays a single phrase, stopping exactly at its end.
    public func play(segment range: Range<Double>, drill: Drill? = nil) {
        guard state == .ready else { return }
        cancelDrill()
        if let drill {
            self.drill = drill
        }
        segment = range
        repeatsPlayed = 0
        playSegmentOnce()
    }

    /// Goes back to playing the whole recording.
    public func clearSegment() {
        cancelDrill()
        segment = nil
        engine.setStopTime(nil)
        onStateChange?()
    }

    func playSegmentOnce() {
        guard let segment, state == .ready else { return }
        activateSession()
        engine.setStopTime(segment.upperBound)
        engine.seek(to: segment.lowerBound)
        playhead = segment.lowerBound
        observedTime = segment.lowerBound
        engine.play()
        isPlaying = true
        clearPauseReasons()
        onStateChange?()
    }

    /// One pass through the phrase ended, at exactly its end time.
    func finishSegmentPass() {
        engine.pause()
        isPlaying = false
        clearPauseReasons()
        repeatsPlayed += 1
        guard repeatsPlayed < drill.repeats else {
            onStateChange?()
            onSegmentFinished?()
            return
        }
        onStateChange?()
        drillTask = Task { [weak self] in
            guard let gap = self?.drill.gap, let wait = self?.wait else { return }
            if gap > 0 {
                await wait(gap)
            }
            guard !Task.isCancelled else { return }
            self?.playSegmentOnce()
        }
    }

    /// Awaits a repeat that is currently waiting out its gap.
    ///
    /// A test seam, and the reason there is no sleeping left in these
    /// tests: a repeat is scheduled on a task that suspends twice before it
    /// plays, so "yield a couple of times and hope" is as much a guess as
    /// sleeping was. Awaiting the task itself is exact.
    func awaitPendingRepeat() async {
        await drillTask?.value
    }

    func cancelDrill() {
        drillTask?.cancel()
        drillTask = nil
        repeatsPlayed = 0
    }
}
