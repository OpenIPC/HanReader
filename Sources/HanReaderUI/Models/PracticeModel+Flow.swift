// HanReader — MIT licensed. See LICENSE.

import Foundation
import HanReaderCore
import HanReaderPlayback

/// Practising without pressing anything.
///
/// The screen this grew out of asked for four deliberate actions per
/// sentence: play, check, grade, next. Three of them are inferable. A
/// learner has finished an answer when it is as long as the sentence; an
/// answer they heard correctly needs nothing said about it; and arriving at
/// a phrase means they want to hear it. What is left is typing, which is the
/// exercise.
///
/// Nothing here removes a control — the transport, Check and the grades are
/// all still there for the cases the inference gets wrong. They stop being
/// the way through.
extension PracticeModel {
    /// How long a passed phrase stays on screen before the next one.
    ///
    /// Long enough to read "8 of 8 correct" and see the marking, short
    /// enough that it does not feel like waiting. Moving on instantly would
    /// take the result away before it had been seen, which is the one piece
    /// of feedback the exercise exists to give.
    static let passPause = 1.2

    /// Whether the answer is as long as the sentence.
    ///
    /// The signal that a learner has finished. Counting the characters that
    /// will be scored rather than every character typed, so an input method
    /// inserting its own punctuation does not hold the check back — and a
    /// half-finished Pinyin syllable sitting in the IME's composition
    /// buffer is not in the field yet, so it cannot trigger one either.
    var isAnswerComplete: Bool {
        let expected = DictationComparison.scorableCount(of: text)
        return expected > 0 && DictationComparison.scorableCount(of: typed) >= expected
    }

    /// Called whenever the writing field changes.
    ///
    /// Checks as soon as the answer is long enough, and — if it was right —
    /// moves on by itself. A learner who typed the sentence correctly has
    /// said everything there is to say about it.
    func answerChanged() async {
        // `!isRevealed` covers an answer already marked as well as one the
        // reader gave up on: checking always reveals, so a phrase with a
        // result behind it is a revealed phrase.
        guard phase == .ready, !isRevealed, isAnswerComplete else { return }
        let phrase = current
        await check()
        guard current == phrase, let result else { return }
        if result.listeningAccuracy >= 1 {
            await advanceAfterPass(from: phrase)
        }
    }

    /// Moves on from a phrase that was answered correctly.
    private func advanceAfterPass(from phrase: Int) async {
        advanceTask?.cancel()
        advanceTask = Task { [weak self] in
            await self?.wait(Self.passPause)
            guard let self, !Task.isCancelled, current == phrase else { return }
            // Only if they have not moved themselves in the meantime. The
            // end of the list needs no guard of its own: `advance` clamps,
            // so the last phrase stays where it is.
            advance(by: 1)
            advanceTask = nil
        }
    }

    /// Waits for a pending move to land, so a test asserts where the reader
    /// ended up rather than racing it.
    func awaitPendingAdvance() async {
        await advanceTask?.value
    }

    /// Stops a pending move, for a learner who did something else first.
    func cancelAdvance() {
        advanceTask?.cancel()
        advanceTask = nil
    }

    /// Plays the phrase the reader has just arrived at.
    ///
    /// The whole screen is "listen, then write", so arriving at a phrase and
    /// having to ask for the sound is a step that is never not wanted. Held
    /// back while the boundary editor is open, where arriving somewhere is
    /// a drag rather than a decision to practise, and while tapping along,
    /// which is already playing the whole recording.
    func playOnArrival() {
        guard phase == .ready, !isEditing, tapping == nil, result == nil else { return }
        play()
    }
}
