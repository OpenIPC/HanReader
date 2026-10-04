// HanReader — MIT licensed. See LICENSE.

import Foundation
import HanReaderCore
import HanReaderPersistence
import HanReaderTokenization

/// Everything the app needs that outlives a window.
///
/// Created once, in `@main`, and handed down. The prototype created one
/// `AppModel` per `ContentView`, which means **per macOS window** — so two
/// windows meant two dictionary stores, two database handles and two caches,
/// each warming independently.
///
/// Not `@Observable`. Nothing here changes after construction, and making it
/// observable would invite views to depend on it and re-render when something
/// unrelated moved.
final class AppServices: Sendable {
    let library: LibraryRepository
    let dictionary: DictionaryService
    let segmenter: DocumentSegmenter
    let locations: AppDatabase.Locations
    /// Nil when no dictionary could be opened, which is not fatal: the reader
    /// still segments and still displays text, just with no annotations.
    let dictionaryMetadata: DictionaryMetadata?

    private init(
        library: LibraryRepository,
        dictionary: DictionaryService,
        segmenter: DocumentSegmenter,
        locations: AppDatabase.Locations,
        dictionaryMetadata: DictionaryMetadata?,
    ) {
        self.library = library
        self.dictionary = dictionary
        self.segmenter = segmenter
        self.locations = locations
        self.dictionaryMetadata = dictionaryMetadata
    }

    /// Opens the real library and the bundled dictionary.
    ///
    /// The dictionary is compiled at build time and shipped in the bundle, so
    /// this is a file open rather than an import — around a millisecond
    /// against the 2.6 seconds parsing the source text would take. That is
    /// the whole reason `hanreader-dictgen` exists.
    static func launch(bundle: Bundle = .main) throws -> AppServices {
        let locations = try AppDatabase.Locations.standard()
        let library = try LibraryRepository(locations: locations)
        let container = Self.openBundledDictionary(in: bundle)
        let lookup: any DictionaryLookup = container ?? EmptyDictionary()

        return AppServices(
            library: library,
            dictionary: DictionaryService(lookup: lookup),
            segmenter: Self.makeSegmenter(container: container),
            locations: locations,
            dictionaryMetadata: container.flatMap { try? $0.metadata() },
        )
    }

    /// Everything in memory, for tests and previews.
    static func inMemory(
        lookup: some DictionaryLookup = EmptyDictionary(),
        lexicon: Lexicon = Lexicon(words: []),
    ) throws
        -> AppServices
    {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return try AppServices(
            library: LibraryRepository.inMemory(audioDirectory: root),
            dictionary: DictionaryService(lookup: lookup),
            segmenter: DocumentSegmenter(tokenizer: TextSegmenter.system(), lexicon: lexicon),
            locations: AppDatabase.Locations(
                library: root.appendingPathComponent("library.sqlite"),
                dictionaries: root.appendingPathComponent("dictionaries.sqlite"),
                audio: root,
            ),
            dictionaryMetadata: nil,
        )
    }

    // MARK: - Construction

    private static func openBundledDictionary(in bundle: Bundle) -> DictionaryContainer? {
        guard let url = bundle.url(
            forResource: bundledDictionaryName,
            withExtension: bundledDictionaryExtension,
        ) else {
            Log.error("services", "the bundled dictionary is missing from the app bundle")
            return nil
        }
        do {
            return try DictionaryContainer(contentsOf: url)
        } catch {
            // Not fatal. Without a dictionary the reader still opens texts,
            // segments them character by character and displays them; it just
            // cannot annotate or define anything. Refusing to launch would
            // turn a degraded reader into no reader.
            Log.error("services", "could not open the bundled dictionary: \(error)")
            return nil
        }
    }

    private static func makeSegmenter(container: DictionaryContainer?) -> DocumentSegmenter {
        // The segmentation lexicon is the dictionary's own, so a word the
        // segmenter finds is a word the reader can look up. That removes the
        // prototype's silent mismatch, where the tokenizer produced a token
        // no dictionary defined and the panel reported "not found" for what
        // was really a segmentation error.
        var lexemes: [Lexeme] = []
        if let container {
            lexemes = (try? container.lexicon()) ?? []
        }
        return DocumentSegmenter(
            tokenizer: TextSegmenter.system(),
            lexicon: Lexicon(lexemes),
        )
    }

    static let bundledDictionaryName = "cedict"
    static let bundledDictionaryExtension = "hanreaderdict"
}

/// A dictionary that knows nothing.
///
/// Used when the bundled container cannot be opened, so that every caller
/// sees the same shape rather than an optional service threaded through the
/// whole UI. Looking a word up returns nothing, which is exactly what the
/// reader shows for a word the dictionary does not contain.
nonisolated struct EmptyDictionary: DictionaryLookup {
    func entries(for _: String) throws -> [DictionaryEntry] {
        []
    }

    func readings(forCharacter _: Character) throws -> [CharacterReading] {
        []
    }
}
