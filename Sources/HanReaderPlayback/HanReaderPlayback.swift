// HanReader — MIT licensed. See LICENSE.

import Foundation
import HanReaderCore

/// Namespace for the `HanReaderPlayback` module.
///
/// Per-text audio playback and word-level speech synthesis, plus the one
/// genuine platform divergence in the media stack: iOS requires an
/// `AVAudioSession` category, interruption handling and route-change handling,
/// while macOS requires none of it.
///
public enum HanReaderPlayback {
    /// Proves at compile time that this module links `HanReaderCore`.
    public static let coreVersion = HanReaderCore.version
}
