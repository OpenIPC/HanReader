// HanReader — MIT licensed. See LICENSE.

import Foundation
import HanReaderCore
import HanReaderPersistence
import Testing
@testable import HanReaderUI

/// Shared fixtures for the model suites.
///
/// A namespace rather than file-scoped `private` declarations, for two
/// reasons that both bite in this module: a `private` type here would need
/// `nonisolated` as well, and SwiftFormat and SwiftLint disagree about the
/// order of those two modifiers; and `entry` is a name three test files want.
nonisolated enum ModelTestSupport {
    struct SmallDictionary: DictionaryLookup {
        static func entry(_ simplified: String, _ numeric: String) -> DictionaryEntry {
            DictionaryEntry(
                headword: Headword(simplified: simplified, traditional: nil),
                reading: Pinyin.parse(numeric: numeric),
                senses: [Sense(
                    id: 0,
                    kind: .definition,
                    gloss: Gloss(text: "a definition of \(simplified)"),
                )],
            )
        }

        static let words: [String: [DictionaryEntry]] = [
            "我": [entry("我", "wo3")],
            "爱": [entry("爱", "ai4")],
            "你": [entry("你", "ni3")],
            "中国": [entry("中国", "Zhong1 guo2")],
        ]

        func entries(for headword: String) throws -> [DictionaryEntry] {
            Self.words[headword] ?? []
        }

        func readings(forCharacter _: Character) throws -> [CharacterReading] {
            []
        }
    }

    /// Knows characters but no whole words, which is the shape that makes
    /// the reader compose a reading — and the shape 77% of BKRS entries
    /// have.
    struct CharacterOnlyDictionary: DictionaryLookup {
        func entries(for _: String) throws -> [DictionaryEntry] {
            []
        }

        func readings(forCharacter character: Character) throws -> [CharacterReading] {
            let numeric = ["北": "bei3", "京": "jing1"][String(character)]
            guard let numeric else { return [] }
            return [CharacterReading(
                character: character,
                numeric: numeric,
                display: Pinyin.display(Pinyin.parse(numeric: numeric)),
                rank: 0,
            )]
        }
    }

    /// Counts database reads, so "looked up once" can be asserted rather
    /// than assumed.
    final class CountingDictionary: DictionaryLookup, @unchecked Sendable {
        private let lock = NSLock()
        private var queries: [String: Int] = [:]

        func count(of word: String) -> Int {
            lock.lock(); defer { lock.unlock() }
            return queries[word] ?? 0
        }

        var total: Int {
            lock.lock(); defer { lock.unlock() }
            return queries.values.reduce(0, +)
        }

        func entries(for headword: String) throws -> [DictionaryEntry] {
            lock.lock()
            queries[headword, default: 0] += 1
            lock.unlock()
            return SmallDictionary.words[headword] ?? []
        }

        func readings(forCharacter _: Character) throws -> [CharacterReading] {
            []
        }
    }

    /// A model over an in-memory library holding one text. A struct rather
    /// than a tuple, which the linter caps at two members and which reads
    /// badly at three anyway.
    struct Fixture {
        let model: ReaderModel
        let services: AppServices
        let id: TextID
    }

    enum FixtureError: Error { case importFailed }

    /// Imports `source` into an in-memory library and opens a model over it.
    @MainActor
    static func makeFixture(
        source: String,
        lookup: some DictionaryLookup = SmallDictionary(),
        revealMode: RevealMode = .allOccurrences,
        dictionaryCapacity: Int = 4096,
    ) async throws
        -> Fixture
    {
        let services = try AppServices.inMemory(
            lookup: lookup,
            lexicon: Lexicon(words: ["中国"]),
            dictionaryCapacity: dictionaryCapacity,
        )
        let outcome = try await services.library.importText(title: "Sample", content: source)
        guard case let .imported(id) = outcome else {
            throw FixtureError.importFailed
        }
        let settings = Settings(store: InMemorySettingsStore())
        settings.revealMode = revealMode
        return Fixture(
            model: ReaderModel(textID: id, services: services, settings: settings),
            services: services,
            id: id,
        )
    }

    // 书 sits alone between full stops so that it is its own token whatever
    // the tokenizer does with its neighbours, and it is deliberately absent
    // from `SmallDictionary` — it is the "no entry" case.
}
