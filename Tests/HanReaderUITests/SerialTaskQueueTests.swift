// HanReader — MIT licensed. See LICENSE.

import Foundation
import Testing
@testable import HanReaderUI

/// Collects what ran, in the order it ran.
private actor Recorder {
    private(set) var values: [Int] = []

    func append(_ value: Int) {
        values.append(value)
    }
}

@MainActor
@Suite("Serial task queue")
struct SerialTaskQueueTests {
    /// The guarantee, with the first item made deliberately slow so that an
    /// unordered implementation has every opportunity to finish the second
    /// one first.
    ///
    /// This is the test the model-level version could not be. Submitting two
    /// writes through `ReaderModel` and checking the result passes whether
    /// or not the chaining is there, because the two almost always complete
    /// in order anyway — verified by removing the chaining and watching it
    /// still pass.
    @Test("Slow work does not let later work overtake it")
    func ordersWork() async {
        let queue = SerialTaskQueue()
        let recorder = Recorder()

        queue.submit {
            try? await Task.sleep(for: .milliseconds(50))
            await recorder.append(1)
        }
        queue.submit {
            await recorder.append(2)
        }
        await queue.drain()

        #expect(await recorder.values == [1, 2])
    }

    @Test("A longer chain stays in order")
    func ordersManyItems() async {
        let queue = SerialTaskQueue()
        let recorder = Recorder()

        for index in 0 ..< 20 {
            queue.submit {
                // Decreasing delays: without chaining, later items would
                // finish first and the order would come out reversed.
                try? await Task.sleep(for: .milliseconds(20 - index))
                await recorder.append(index)
            }
        }
        await queue.drain()

        #expect(await recorder.values == Array(0 ..< 20))
    }

    @Test("Draining an empty queue returns immediately")
    func drainEmpty() async {
        await SerialTaskQueue().drain()
    }

    @Test("Work submitted after a drain still runs")
    func submitAfterDrain() async {
        let queue = SerialTaskQueue()
        let recorder = Recorder()

        queue.submit { await recorder.append(1) }
        await queue.drain()
        queue.submit { await recorder.append(2) }
        await queue.drain()

        #expect(await recorder.values == [1, 2])
    }
}
