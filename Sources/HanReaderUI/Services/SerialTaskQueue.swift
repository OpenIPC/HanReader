// HanReader — MIT licensed. See LICENSE.

import Foundation

/// Runs asynchronous work one item at a time, in submission order.
///
/// Exists because "fire a `Task` per event" silently loses ordering the
/// moment the work suspends, and the place that bites here is reveal state:
/// two taps on the same word are a reveal and a hide, and landing in the
/// wrong order leaves the store saying "revealed" after the tap that hid it.
///
/// Extracted into its own type rather than written inline for a reason worth
/// recording: inline, the ordering guarantee could not be tested. A test at
/// the model level submits two writes and almost always sees them complete
/// in order anyway, so it passes whether or not the chaining is there — it
/// was written, and it did pass with the chaining removed. Here the work is
/// injectable, so a test can make the first item slow and prove the second
/// waits.
@MainActor
final class SerialTaskQueue {
    private var tail: Task<Void, Never>?

    init() {}

    /// Queues work to run after everything already submitted.
    func submit(_ work: @escaping @Sendable () async -> Void) {
        let previous = tail
        tail = Task {
            await previous?.value
            await work()
        }
    }

    /// Waits for everything submitted so far.
    ///
    /// Deliberately not a cancel: these are the last writes of a session and
    /// the whole point of the queue is that they land in order, so dropping
    /// the final one would be the bug this type exists to prevent.
    func drain() async {
        await tail?.value
    }
}
