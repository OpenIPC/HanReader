// HanReader — MIT licensed. See LICENSE.

import Foundation
import HanReaderCore

/// Answers "what does this word say, and what does it mean".
///
/// An actor, and off the main thread on purpose. The prototype did the
/// opposite in two ways that compounded: it prefetched a dictionary entry for
/// *every distinct token in the document* when a text was opened, and it did
/// so on the main actor. Opening a novel therefore blocked the first frame
/// behind tens of thousands of database queries, and clicking down the sidebar
/// started a new prefetch without cancelling the last, so several whole-
/// document prefetches raced each other.
///
/// What replaces it:
///
/// - **Demand-driven.** Readings are fetched for the words on screen and a
///   little either side, and a full sense payload only when a word is tapped.
/// - **Cached, including the misses.** See `BoundedCache`: a lookup that finds
///   nothing is an answer, and 77% of BKRS entries have no reading, so a cache
///   that only remembered successes would re-query for most of the page on
///   every frame.
/// - **Batched.** `readings(for:)` takes the whole visible window at once, so
///   a screenful is one actor hop rather than four hundred.
actor DictionaryService {
    private let lookup: any DictionaryLookup
    /// The dictionaries a definition may come from, in the reader's order.
    ///
    /// Separate from `lookup`, which is the *reading* path: a reader can turn
    /// off CC-CEDICT's English definitions and still need its readings, since
    /// 77% of BKRS entries carry none. Nil when the service was built from a
    /// single lookup, as the tests and previews do.
    private let set: DictionarySet?
    /// Keyed on the word *and* its context, not the word alone. 重 is
    /// `zhòng` after 很 and `chóng` on its own, so a cache keyed on the word
    /// would serve whichever of the two was asked for first to every
    /// occurrence in the book.
    private var readingCache: BoundedCache<ReadingRequest, TokenReading?>
    private var entryCache: BoundedCache<String, [DictionaryEntry]>

    /// Whether a database read has already failed.
    ///
    /// A container is opened once at launch, so a read that fails afterwards
    /// means the file has gone bad — in which case *every* subsequent read
    /// fails too. Logging each one would bury the first report under a
    /// thousand copies of itself on the next scroll.
    private var hasReportedFailure = false

    /// - Parameters:
    ///   - capacity: how many readings to remember. Four thousand covers
    ///     several screens of dense text in both directions, which is the
    ///     working set while scrolling, and costs a few hundred kilobytes.
    ///   - entryCapacity: how many full entry lists to remember. Smaller,
    ///     and deliberately so: a reading is a short string while an entry
    ///     carries every sense, and BKRS entries can be long. A thousand
    ///     still covers two screens, so scrolling back to a word just
    ///     annotated and tapping it does not query again.
    init(lookup: some DictionaryLookup, capacity: Int = 4096, entryCapacity: Int = 1024) {
        self.lookup = lookup
        set = lookup as? DictionarySet
        readingCache = BoundedCache(capacity: capacity)
        entryCache = BoundedCache(capacity: entryCapacity)
    }

    /// Every gloss-providing dictionary's answer for a word, grouped by
    /// reading and labelled with where it came from.
    ///
    /// Grouped because 了 is `le` in one dictionary and `liǎo` in another,
    /// and a reader tapping it should see two readings with two answers each
    /// rather than four entries with no indication which are the same word.
    /// Labelled because CC-CEDICT is CC BY-SA and attribution has to reach
    /// the reader at the point they read the gloss.
    func groups(for word: String) -> [ReadingGroup] {
        guard let set else {
            // Built from a single lookup, so there is nothing to attribute
            // and nothing to merge; one unnamed group keeps the caller's
            // shape the same either way.
            let entries = entries(for: word)
            guard !entries.isEmpty else { return [] }
            return Dictionary(grouping: entries, by: \.readingKey)
                .sorted { $0.key < $1.key }
                .map { key, entries in
                    ReadingGroup(
                        readingKey: key,
                        entries: entries.map { AttributedEntry(dictionary: "", entry: $0) },
                    )
                }
        }
        let result = set.groups(for: word)
        for slug in result.failures where !hasReportedFailure {
            hasReportedFailure = true
            Log.error("dictionary", "\(slug) could not be read")
        }
        return result.groups
    }

    // MARK: - Readings

    /// Readings for a window of words, as one batch.
    ///
    /// Returns only the requests that have one, so the caller can treat a
    /// missing key and a word with no reading identically — which it should,
    /// because they look identical on the page.
    func readings(
        for requests: some Sequence<ReadingRequest>,
    )
        -> [ReadingRequest: TokenReading]
    {
        var result: [ReadingRequest: TokenReading] = [:]
        for request in requests {
            if let reading = reading(for: request) {
                result[request] = reading
            }
        }
        return result
    }

    func reading(for request: ReadingRequest) -> TokenReading? {
        if let cached = readingCache.value(forKey: request) {
            return cached
        }
        let word = request.word
        // Routed through `entries(for:)` rather than letting the composer do
        // its own lookup. The composer would query for exactly the same rows
        // and throw them away, so annotating a word and then tapping it ran
        // the same whole-word query twice -- once to find out how it sounds
        // and once to find out what it means.
        let reading = ReadingComposer.reading(
            from: entries(for: word),
            context: request.context,
        )
            ?? attempt("composed reading for \(word)", default: nil) {
                try ReadingComposer.composedReading(for: word, in: lookup)
            }
        readingCache.insert(reading, forKey: request)
        return reading
    }

    // MARK: - Entries

    /// Every entry for a word, for the detail panel.
    ///
    /// A list rather than an optional: 和 has eight entries and 了 has two
    /// readings. The prototype's `WHERE simplified = ? LIMIT 1` is the bug
    /// this signature exists to make impossible.
    func entries(for word: String) -> [DictionaryEntry] {
        if let cached = entryCache.value(forKey: word) {
            return cached
        }
        let entries = attempt("entries for \(word)", default: []) {
            try lookup.entries(for: word)
        }
        entryCache.insert(entries, forKey: word)
        return entries
    }

    // MARK: - Failure handling

    /// Runs a database read, turning a failure into `fallback` rather than
    /// an error the reading surface has to handle per token.
    ///
    /// The fallback is a parameter rather than an optional return so that a
    /// lookup which legitimately answers "nothing" does not come back as a
    /// double optional — which reads badly and which the linter rightly
    /// objects to flattening with `?? nil`.
    ///
    /// A word that cannot be looked up renders with no annotation, which is
    /// exactly how a word the dictionary does not contain renders. Degrading
    /// to that is right: the alternative is an error banner over the text the
    /// reader is trying to read, once per token.
    private func attempt<T>(_ what: String, default fallback: T, _ body: () throws -> T) -> T {
        do {
            return try body()
        } catch {
            if !hasReportedFailure {
                hasReportedFailure = true
                Log.error(
                    "dictionary",
                    "lookup failed (\(what)): \(error). Further failures are not reported.",
                )
            }
            return fallback
        }
    }

    // MARK: - Testing

    /// Empties the caches. For tests that need to observe a cold lookup.
    func clearCaches() {
        readingCache.removeAll()
        entryCache.removeAll()
    }
}
