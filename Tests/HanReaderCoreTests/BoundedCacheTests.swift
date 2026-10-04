// HanReader — MIT licensed. See LICENSE.

import Testing
@testable import HanReaderCore

@Suite("Bounded cache")
struct BoundedCacheTests {
    @Test("Stores and returns a value")
    func roundTrip() {
        var cache = BoundedCache<String, Int>(capacity: 4)
        cache.insert(1, forKey: "a")
        #expect(cache.value(forKey: "a") == 1)
        #expect(cache.value(forKey: "b") == nil)
        #expect(cache.count == 1)
    }

    /// The reason the value type is left to the caller rather than being an
    /// optional internally: a lookup that found nothing is an answer, and
    /// **77% of BKRS entries have no reading**, so a cache that remembered
    /// only successes would re-query the database for most of the page on
    /// every frame.
    @Test("A remembered miss is distinguishable from an absent key")
    func negativeCaching() {
        var cache = BoundedCache<String, String?>(capacity: 4)
        cache.insert(nil, forKey: "unknown")

        #expect(cache.contains("unknown"))
        #expect(!cache.contains("never asked"))
        // Unwrapped rather than compared as a double optional. Written as
        // `found! == nil` the formatter rewrites it to `found == nil`, which
        // is the opposite claim and still compiles.
        if let remembered = cache.value(forKey: "unknown") {
            #expect(remembered == nil, "the remembered answer should be 'nothing'")
        } else {
            Issue.record("the miss was not remembered at all")
        }
    }

    @Test("Evicts the least recently used entry when full")
    func evictsOldest() {
        var cache = BoundedCache<String, Int>(capacity: 2)
        cache.insert(1, forKey: "a")
        cache.insert(2, forKey: "b")
        cache.insert(3, forKey: "c")

        #expect(cache.count == 2)
        #expect(cache.value(forKey: "a") == nil)
        #expect(cache.value(forKey: "b") == 2)
        #expect(cache.value(forKey: "c") == 3)
    }

    /// The property that makes it an LRU rather than a queue, and the one a
    /// naive implementation gets wrong: reading a value has to count as using
    /// it, or the word being re-read on every frame is the one that gets
    /// evicted.
    @Test("Reading a value protects it from eviction")
    func readingCountsAsUse() {
        var cache = BoundedCache<String, Int>(capacity: 2)
        cache.insert(1, forKey: "a")
        cache.insert(2, forKey: "b")
        _ = cache.value(forKey: "a")
        cache.insert(3, forKey: "c")

        #expect(cache.value(forKey: "a") == 1, "the recently read entry was evicted")
        #expect(cache.value(forKey: "b") == nil)
    }

    @Test("Checking for a key does not change the eviction order")
    func containsDoesNotTouch() {
        var cache = BoundedCache<String, Int>(capacity: 2)
        cache.insert(1, forKey: "a")
        cache.insert(2, forKey: "b")
        #expect(cache.contains("a"))
        cache.insert(3, forKey: "c")

        // `contains` is for asking without disturbing anything, so "a" is
        // still the oldest and still the one to go.
        #expect(cache.value(forKey: "a") == nil)
    }

    @Test("Overwriting a key updates it without growing the cache")
    func overwrite() {
        var cache = BoundedCache<String, Int>(capacity: 2)
        cache.insert(1, forKey: "a")
        cache.insert(2, forKey: "a")
        #expect(cache.count == 1)
        #expect(cache.value(forKey: "a") == 2)
    }

    @Test("Overwriting a key counts as using it")
    func overwriteCountsAsUse() {
        var cache = BoundedCache<String, Int>(capacity: 2)
        cache.insert(1, forKey: "a")
        cache.insert(2, forKey: "b")
        cache.insert(9, forKey: "a")
        cache.insert(3, forKey: "c")

        #expect(cache.value(forKey: "a") == 9)
        #expect(cache.value(forKey: "b") == nil)
    }

    /// A legitimate way to turn caching off in a test, rather than something
    /// to guard against at every call site.
    @Test("A capacity of zero stores nothing")
    func zeroCapacity() {
        var cache = BoundedCache<String, Int>(capacity: 0)
        cache.insert(1, forKey: "a")
        #expect(cache.isEmpty)
        #expect(cache.value(forKey: "a") == nil)
    }

    @Test("Clearing empties it")
    func clearing() {
        var cache = BoundedCache<String, Int>(capacity: 4)
        cache.insert(1, forKey: "a")
        cache.removeAll()
        #expect(cache.isEmpty)
        #expect(cache.value(forKey: "a") == nil)
        // Still usable afterwards.
        cache.insert(2, forKey: "b")
        #expect(cache.value(forKey: "b") == 2)
    }

    @Test("Never exceeds its capacity under churn")
    func staysBounded() {
        var cache = BoundedCache<Int, Int>(capacity: 8)
        for index in 0 ..< 1000 {
            cache.insert(index, forKey: index % 40)
            #expect(cache.count <= 8)
        }
    }
}
