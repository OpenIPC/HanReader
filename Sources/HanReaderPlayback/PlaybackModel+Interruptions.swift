// HanReader — MIT licensed. See LICENSE.

import Foundation

/// Who is allowed to stop the narration, and who is allowed to start it
/// again.
///
/// Its own file because the rules are not obvious and there are several:
/// the system may take the audio away and give it back, a spoken word may
/// duck it, the reader may have pressed pause, and a drill may be waiting
/// out a gap. Only one of those is allowed to undo each of the others.
extension PlaybackModel {
    func handle(_ interruption: PlaybackInterruption) {
        switch interruption {
        case .began:
            // Before the guard: during a gap nothing is playing, and a
            // pending repeat would otherwise start during the interruption.
            cancelDrill()
            guard isPlaying else { return }
            engine.pause()
            isPlaying = false
            pausedByInterruption = true
            onStateChange?()
        case .ended:
            guard pausedByInterruption, state == .ready else { return }
            pausedByInterruption = false
            engine.play()
            isPlaying = true
            onStateChange?()
        case .outputGone:
            // Headphones pulled out. Pausing is not politeness, it is the
            // difference between a quiet room and the reader's audio playing
            // through the speaker to everyone around them — and it must not
            // be resumable automatically, or plugging back in starts it in
            // the open.
            //
            // The reasons are cleared *before* the guard, not after it: the
            // output can be lost while already paused by an interruption,
            // and leaving that reason set means the interruption ending
            // resumes narration into a room with no headphones in it.
            clearPauseReasons()
            // Likewise, and this is the one that matters most: headphones
            // pulled out during the gap would otherwise be followed by the
            // phrase starting through whatever speaker is left.
            cancelDrill()
            guard isPlaying else { return }
            engine.pause()
            isPlaying = false
            onStateChange?()
        }
    }
}
