// HanReader — MIT licensed. See LICENSE.

import Foundation
import HanReaderCore
import Testing
@testable import HanReaderUI

/// Counts queries, so that "cached" can be asserted rather than assumed.
private final class CountingDictionary: DictionaryLookup, @unchecked Sendable {
    private let lock = NSLock()
    private var _wordQueries = 0
    private var _characterQueries = 0

    var words: [String: [DictionaryEntry]] = [:]
    var characters: [Character: [CharacterReading]] = [:]
    var failsAlways = false

    var wordQueries: Int {
        lock.lock(); defer { lock.unlock() }
        return _wordQueries
    }

    var characterQueries: Int {
        lock.lock(); defer { lock.unlock() }
        return _characterQueries
    }

    func entries(for headword: String) throws -> [DictionaryEntry] {
        lock.lock()
        _wordQueries += 1
        lock.unlock()
        if failsAlways {
            throw StubError.unreadable
        }
        return words[headword] ?? []
    }

    func readings(forCharacter character: Character) throws -> [CharacterReading] {
        lock.lock()
        _characterQueries += 1
        lock.unlock()
        if failsAlways {
            throw StubError.unreadable
        }
        return characters[character] ?? []
    }
}

private enum StubError: Error { case unreadable }

private func entry(_ simplified: String, _ numeric: String) -> DictionaryEntry {
    DictionaryEntry(
        headword: Headword(simplified: simplified, traditional: nil),
        reading: Pinyin.parse(numeric: numeric),
        senses: [Sense(id: 0, kind: .definition, gloss: Gloss(text: "a definition"))],
    )
}

@Suite("Dictionary service")
struct DictionaryServiceTests {
    private func stub() -> CountingDictionary {
        let dictionary = CountingDictionary()
        dictionary.words = [
            "中国": [entry("中国", "Zhong1 guo2")],
            "和": (0 ..< 8).map { entry("和", "he\($0 % 4 + 1)") },
        ]
        dictionary.characters = [
            "北": [CharacterReading(character: "北", numeric: "bei3", display: "běi", rank: 0)],
            "京": [CharacterReading(character: "京", numeric: "jing1", display: "jīng", rank: 0)],
        ]
        return dictionary
    }

    @Test("Looks a word up")
    func lookup() async {
        let service = DictionaryService(lookup: stub())
        let reading = await service.reading(for: "中国")
        #expect(reading?.display == "Zhōngguó")
    }

    @Test("A whole window of words is one call")
    func batched() async {
        let service = DictionaryService(lookup: stub())
        let readings = await service.readings(for: ["中国", "北京", "unknown"])

        #expect(readings["中国"]?.display == "Zhōngguó")
        #expect(readings["北京"]?.source == .composed)
        // Words with no reading are absent rather than present-and-nil: on
        // the page the two are indistinguishable, so the caller should not
        // have to tell them apart either.
        #expect(readings["unknown"] == nil)
        #expect(readings.count == 2)
    }

    @Test("A word is looked up once")
    func cachesHits() async {
        let dictionary = stub()
        let service = DictionaryService(lookup: dictionary)

        for _ in 0 ..< 10 {
            _ = await service.reading(for: "中国")
        }
        #expect(dictionary.wordQueries == 1)
    }

    /// The cache has to remember that a word was *not* found, or the 77% of
    /// words with no reading would be re-queried on every frame — which is
    /// most of the page, several times a second, for a reader using the
    /// Russian dictionary.
    @Test("A word that is not in the dictionary is looked up once too")
    func cachesMisses() async {
        let dictionary = stub()
        let service = DictionaryService(lookup: dictionary)

        for _ in 0 ..< 10 {
            _ = await service.reading(for: "龘龘龘")
        }
        #expect(dictionary.wordQueries == 1)
        // And it did not keep re-trying the character fallback either.
        #expect(dictionary.characterQueries <= 1)
    }

    @Test("Clearing the caches makes the next lookup cold")
    func clearing() async {
        let dictionary = stub()
        let service = DictionaryService(lookup: dictionary)

        _ = await service.reading(for: "中国")
        await service.clearCaches()
        _ = await service.reading(for: "中国")
        #expect(dictionary.wordQueries == 2)
    }

    // MARK: - Entries

    /// 和 has eight entries. The prototype's `WHERE simplified = ? LIMIT 1`
    /// returned one of them, which is the bug this signature exists to make
    /// impossible.
    @Test("Every entry for a word comes back")
    func allEntries() async {
        let service = DictionaryService(lookup: stub())
        #expect(await service.entries(for: "和").count == 8)
    }

    @Test("Entries are cached too")
    func cachesEntries() async {
        let dictionary = stub()
        let service = DictionaryService(lookup: dictionary)

        for _ in 0 ..< 5 {
            _ = await service.entries(for: "和")
        }
        #expect(dictionary.wordQueries == 1)
    }

    @Test("A word with no entries caches the empty result")
    func cachesEmptyEntries() async {
        let dictionary = stub()
        let service = DictionaryService(lookup: dictionary)

        #expect(await service.entries(for: "龘").isEmpty)
        #expect(await service.entries(for: "龘").isEmpty)
        #expect(dictionary.wordQueries == 1)
    }

    /// Annotating a word and then tapping it used to run the same whole-word
    /// query twice: once through the composer to find out how it sounds, and
    /// once through `entries(for:)` to find out what it means.
    @Test("A word annotated and then tapped is queried once")
    func readingAndEntriesShareOneQuery() async {
        let dictionary = stub()
        let service = DictionaryService(lookup: dictionary)

        _ = await service.reading(for: "中国")
        _ = await service.entries(for: "中国")
        #expect(dictionary.wordQueries == 1)
    }

    @Test("The order does not matter")
    func tappedThenAnnotated() async {
        let dictionary = stub()
        let service = DictionaryService(lookup: dictionary)

        _ = await service.entries(for: "中国")
        _ = await service.reading(for: "中国")
        #expect(dictionary.wordQueries == 1)
    }

    // MARK: - Failure

    /// A word that cannot be looked up renders with no annotation — exactly
    /// how a word the dictionary does not contain renders. Degrading to that
    /// is right: the alternative is an error banner over the text the reader
    /// is trying to read, once per token.
    @Test("A broken database degrades to no annotation rather than an error")
    func readFailureDegrades() async {
        let dictionary = stub()
        dictionary.failsAlways = true
        let service = DictionaryService(lookup: dictionary)

        #expect(await service.reading(for: "中国") == nil)
        #expect(await service.entries(for: "中国").isEmpty)
    }

    @Test("A failure is not re-queried on every frame")
    func failureIsCached() async {
        let dictionary = stub()
        dictionary.failsAlways = true
        let service = DictionaryService(lookup: dictionary)

        for _ in 0 ..< 10 {
            _ = await service.reading(for: "中国")
        }
        #expect(dictionary.wordQueries == 1)
    }
}
