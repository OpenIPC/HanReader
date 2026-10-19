// HanReader — MIT licensed. See LICENSE.

import Foundation
import Testing
@testable import HanReaderUI

@MainActor
@Suite("Audio transport formatting")
struct AudioBarTests {
    /// `m:ss`, because a transport is read at a glance. `Duration.formatted`
    /// spells this as "1 min, 4 sec", which is correct prose and unreadable
    /// as a clock that changes once a second.
    @Test(
        "A position reads as a clock",
        arguments: [
            (0.0, "0:00"),
            (4.0, "0:04"),
            (9.9, "0:09"),
            (64.0, "1:04"),
            (599.0, "9:59"),
            (600.0, "10:00"),
        ],
    )
    func clockFormatting(seconds: Double, expected: String) {
        #expect(AudioBar.clock(seconds) == expected)
    }

    /// An hour-long recording is a plausible thing to attach — a whole
    /// chapter read aloud — and `62:03` for an hour and two minutes is a
    /// clock nobody reads correctly.
    @Test("Over an hour, hours are shown")
    func longRecordings() {
        #expect(AudioBar.clock(3600) == "1:00:00")
        #expect(AudioBar.clock(3723) == "1:02:03")
    }

    /// A track whose duration has not loaded yet reports zero, and an
    /// `AVPlayer` with no item reports `NaN`. Neither may put `nan:0-2147483648`
    /// on screen.
    @Test("Nonsense values do not reach the screen")
    func degenerateValues() {
        #expect(AudioBar.clock(.nan) == "0:00")
        #expect(AudioBar.clock(.infinity) == "0:00")
        #expect(AudioBar.clock(-5) == "0:00")
    }

    /// VoiceOver gets prose, not a clock: "4:12" is announced as a time of
    /// day, which is wrong twice over.
    @Test("VoiceOver hears a duration, not a time of day")
    func spokenValues() {
        let spoken = AudioBar.spoken(252)
        #expect(spoken.contains("4"))
        #expect(spoken.lowercased().contains("minute"))
        #expect(!spoken.contains(":"))
        #expect(AudioBar.spoken(.nan) == "0 seconds")
    }
}
