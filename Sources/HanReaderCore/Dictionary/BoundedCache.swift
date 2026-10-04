// HanReader — MIT licensed. See LICENSE.

import Foundation

/// A fixed-capacity cache that evicts whatever was used longest ago.
///
/// Small, and deliberately not clever: a dictionary of values plus a list of
/// keys in use order. At the capacities this is used at — a few thousand
/// words — the list operations are cheaper than the hashing and allocation
/// a linked-list implementation would add, and the whole thing fits on one
/// screen where its behaviour can be checked by reading it.
///
/// ### Why misses are cached too
///
/// `Value` is whatever the caller stores, and callers store an `Optional`.
/// That is the point rather than an accident: **77% of BKRS entries carry no
/// reading**, so for a reader using the Russian dictionary most lookups find
/// nothing — and a cache that only remembers successes would re-query the
/// database for every one of them, on every frame, forever. A miss is an
/// answer and gets remembered like any other.
public struct BoundedCache<Key: Hashable & Sendable, Value: Sendable>: Sendable {
    private var storage: [Key: Value] = [:]
    /// Keys in least-recently-used order. The oldest is at the front.
    private var order: [Key] = []

    public let capacity: Int

    /// - Parameter capacity: how many entries to keep. A non-positive
    ///   capacity makes the cache a no-op, which is a legitimate way to turn
    ///   caching off in a test rather than something to guard against.
    public init(capacity: Int) {
        self.capacity = capacity
        storage.reserveCapacity(max(0, capacity))
        order.reserveCapacity(max(0, capacity))
    }

    public var count: Int {
        storage.count
    }

    public var isEmpty: Bool {
        storage.isEmpty
    }

    /// Reads a value, marking it as just used.
    ///
    /// `mutating` because reading changes the eviction order. That is
    /// unavoidable for an LRU and it is why this is a `struct` held by an
    /// actor rather than something shared across threads.
    public mutating func value(forKey key: Key) -> Value? {
        guard let value = storage[key] else { return nil }
        touch(key)
        return value
    }

    /// Whether a key is present, without disturbing the order.
    public func contains(_ key: Key) -> Bool {
        storage.index(forKey: key) != nil
    }

    public mutating func insert(_ value: Value, forKey key: Key) {
        guard capacity > 0 else { return }
        if storage.updateValue(value, forKey: key) == nil {
            order.append(key)
        } else {
            touch(key)
        }
        while order.count > capacity {
            storage.removeValue(forKey: order.removeFirst())
        }
    }

    public mutating func removeAll() {
        storage.removeAll(keepingCapacity: true)
        order.removeAll(keepingCapacity: true)
    }

    private mutating func touch(_ key: Key) {
        guard let index = order.firstIndex(of: key) else { return }
        order.append(order.remove(at: index))
    }
}
