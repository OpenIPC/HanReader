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
    /// Every dictionary the reader has, in their order, with what each is
    /// allowed to do and whether it opened.
    ///
    /// Empty is not fatal: the reader still segments and still displays text,
    /// just with no annotations.
    let catalogue: DictionaryCatalogue

    /// The first gloss-providing dictionary, for the places that show one
    /// dictionary's name — which is a stopgap until the acknowledgements
    /// screen lists them all.
    var dictionaryMetadata: DictionaryMetadata? {
        catalogue.installed
            .sorted { $0.sortOrder < $1.sortOrder }
            .first { $0.providesGlosses }?
            .metadata
    }

    /// Slug to display name, for labelling which dictionary an answer came
    /// from. Attribution is a licence obligation for CC BY-SA data, so the
    /// name has to be available wherever a gloss is shown.
    var dictionaryNames: [String: String] {
        catalogue.installed.reduce(into: [:]) { names, entry in
            names[entry.slug] = entry.metadata.displayName
        }
    }

    private init(
        library: LibraryRepository,
        dictionary: DictionaryService,
        segmenter: DocumentSegmenter,
        locations: AppDatabase.Locations,
        catalogue: DictionaryCatalogue,
    ) {
        self.library = library
        self.dictionary = dictionary
        self.segmenter = segmenter
        self.locations = locations
        self.catalogue = catalogue
    }

    /// Opens the real library and every dictionary the reader has.
    ///
    /// The bundled one is compiled at build time and shipped in the app, so
    /// that one is a file open rather than an import — around a millisecond
    /// against the 2.6 seconds parsing its source would take, which is the
    /// whole reason `hanreader-dictgen` exists. Anything else was imported by
    /// the reader and is found by scanning, so there is no stored path to go
    /// stale.
    static func launch(bundle: Bundle = .main) async throws -> AppServices {
        let locations = try AppDatabase.Locations.standard()
        let library = try LibraryRepository(locations: locations)
        let catalogue = try await AppDatabase.catalogue(
            in: locations.dictionaryDirectory,
            bundled: bundle.url(
                forResource: bundledDictionaryName,
                withExtension: DictionaryCatalogue.fileExtension,
            ),
            library: library,
        )
        for failure in catalogue.unreadable {
            Log.error("services", "\(failure.file.lastPathComponent): \(failure.reason)")
        }

        let (set, unopened) = catalogue.makeSet()
        for failure in unopened {
            Log.error("services", "\(failure.file.lastPathComponent): \(failure.reason)")
        }
        if set.isEmpty {
            // Not fatal. Without a dictionary the reader still opens texts,
            // segments them and displays them; it just cannot annotate or
            // define anything. Refusing to launch would turn a degraded
            // reader into no reader.
            Log.error("services", "no dictionary could be opened")
        }

        return AppServices(
            library: library,
            dictionary: DictionaryService(lookup: set),
            // The dictionary's own word list, so a word the segmenter finds
            // is a word the reader can look up. That removes the prototype's
            // silent mismatch, where the tokenizer produced a token no
            // dictionary defined and the panel reported "not found" for what
            // was really a segmentation error.
            segmenter: DocumentSegmenter(
                tokenizer: TextSegmenter.system(),
                lexicon: catalogue.lexicon(),
            ),
            locations: locations,
            catalogue: catalogue,
        )
    }

    /// Everything in memory, for tests and previews.
    /// - Parameter dictionaryCapacity: pass 0 to turn the lookup cache off,
    ///   so that a test counting database queries sees every one of them
    ///   rather than only the first.
    static func inMemory(
        lookup: some DictionaryLookup = EmptyDictionary(),
        lexicon: Lexicon = Lexicon(words: []),
        dictionaryCapacity: Int = 4096,
    ) throws
        -> AppServices
    {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return try AppServices(
            library: LibraryRepository.inMemory(audioDirectory: root),
            dictionary: DictionaryService(
                lookup: lookup,
                capacity: dictionaryCapacity,
                entryCapacity: dictionaryCapacity,
            ),
            segmenter: DocumentSegmenter(tokenizer: TextSegmenter.system(), lexicon: lexicon),
            locations: AppDatabase.Locations(
                library: root.appendingPathComponent("library.sqlite"),
                dictionaries: root.appendingPathComponent("dictionaries.sqlite"),
                audio: root,
            ),
            catalogue: DictionaryCatalogue(installed: []),
        )
    }

    // MARK: - Construction

    static let bundledDictionaryName = "cedict"
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
