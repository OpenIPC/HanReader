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
    /// Plays a single phrase, stopping exactly at its end.
    ///
    /// Asking for the phrase that is already loaded picks it up where it
    /// stopped, a little way back, rather than starting it again — the
    /// difference between pausing to think halfway through a long sentence
    /// and never getting to the end of one.
    public func play(segment range: Range<Double>, drill: Drill? = nil) {
        guard state == .ready else { return }
        let resuming = segment == range && !isPlaying
        cancelDrill()
        if let drill {
            self.drill = drill
        }
        segment = range
        if resuming {
            resumeSegment()
        } else {
            repeatsPlayed = 0
            playSegmentOnce()
        }
    }

    /// Goes back to playing the whole recording.
    public func clearSegment() {
        cancelDrill()
        segment = nil
        engine.setStopTime(nil)
        onStateChange?()
    }

    /// How far back a resumed phrase rewinds.
    ///
    /// Picking up exactly where the sound stopped drops the listener into
    /// the middle of a word with no run-up, and starting the phrase again
    /// makes a long sentence impossible to finish — pause once near the end
    /// and you are back at the beginning. Podcasts solves it with a short
    /// rewind, and so does this.
    public static let resumeRewind = 2.0

    func playSegmentOnce() {
        play(segment: segment, from: nil)
    }

    /// Picks the phrase up again from a little before where it stopped.
    func resumeSegment() {
        guard let segment else { return }
        let from = max(segment.lowerBound, playhead - Self.resumeRewind)
        // Close enough to the start that a rewind would land there anyway,
        // or past the end after a finished pass: begin the phrase again.
        let isNearlyOver = playhead >= segment.upperBound - 0.05
        play(segment: segment, from: isNearlyOver ? nil : from)
    }

    private func play(segment: Range<Double>?, from: Double?) {
        guard let segment, state == .ready else { return }
        activateSession()
        engine.setStopTime(segment.upperBound)
        let start = from ?? segment.lowerBound
        // Exactly, because the target is the first syllable. A tolerance
        // here is what makes a sentence begin mid-word.
        engine.seek(to: start, exactly: true)
        playhead = start
        observedTime = start
        engine.play()
        isPlaying = true
        clearPauseReasons()
        onStateChange?()
    }

    /// One pass through the phrase ended, at exactly its end time.
    ///
    /// The gap is taken **after every pass, including the last**. It is the
    /// interval the learner writes in, so skipping it on the final pass
    /// means a caller that advances from `onSegmentFinished` moves on the
    /// instant the audio stops — no time to answer, which is the one thing
    /// the drill exists to provide.
    func finishSegmentPass() {
        engine.pause()
        isPlaying = false
        clearPauseReasons()
        repeatsPlayed += 1
        let wasLast = repeatsPlayed >= drill.repeats
        let phrase = segment

        // Scheduled *before* the state callback runs, so that a `pause()`
        // issued from inside it finds a task to cancel. Assigning afterwards
        // meant cancellation found nothing and the repeat started anyway,
        // despite the reader having paused.
        drillTask = Task { [weak self] in
            guard let self else { return }
            if drill.gap > 0 {
                await wait(drill.gap)
            }
            guard !Task.isCancelled else { return }
            guard wasLast else {
                playSegmentOnce()
                return
            }
            // Belt and braces, and said plainly: every path that changes
            // the segment today also cancels this task, so the check above
            // already covers it and mutation testing shows this line is
            // unreachable. It is kept because `segment` has an internal
            // setter and the cost of being wrong here is a listener told
            // "finished" about a phrase the reader has already left —
            // which would advance them past the one they just chose.
            guard segment == phrase else { return }
            onSegmentFinished?()
        }
        onStateChange?()
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
