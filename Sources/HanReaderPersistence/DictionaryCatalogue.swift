// HanReader — MIT licensed. See LICENSE.

public import Foundation
import GRDB
public import HanReaderCore

/// What the reader has decided about one dictionary.
///
/// Three permissions rather than one switch, because the three uses are
/// genuinely separate: a reader can turn off CC-CEDICT's English definitions
/// and still need its readings, since 77% of BKRS entries carry none.
public struct DictionaryPreference: Hashable, Sendable {
    public let slug: String
    public let providesGlosses: Bool
    public let providesReadings: Bool
    public let providesLexicon: Bool
    public let sortOrder: Int

    public init(
        slug: String,
        providesGlosses: Bool = true,
        providesReadings: Bool = true,
        providesLexicon: Bool = false,
        sortOrder: Int = 0,
    ) {
        self.slug = slug
        self.providesGlosses = providesGlosses
        self.providesReadings = providesReadings
        self.providesLexicon = providesLexicon
        self.sortOrder = sortOrder
    }
}

extension DictionaryPreference {
    /// A copy with one permission changed.
    public func with(glosses: Bool? = nil, readings: Bool? = nil, lexicon: Bool? = nil) -> Self {
        Self(
            slug: slug,
            providesGlosses: glosses ?? providesGlosses,
            providesReadings: readings ?? providesReadings,
            providesLexicon: lexicon ?? providesLexicon,
            sortOrder: sortOrder,
        )
    }
}

/// An installed dictionary, as the reader's list shows it.
public struct InstalledDictionary: Hashable, Sendable {
    /// From the container's own `meta`, never from a copy.
    public let metadata: DictionaryMetadata
    public let file: URL
    /// Shipped with the app, so it cannot be removed.
    public let isBuiltIn: Bool

    public let providesGlosses: Bool
    public let providesReadings: Bool
    public let providesLexicon: Bool
    public let sortOrder: Int

    public var slug: String {
        metadata.slug
    }
}

/// A container that is present but cannot be read.
///
/// Listed rather than hidden: a reader whose dictionary stopped working
/// should be told which one, and offered the chance to remove or re-import
/// it. Silently showing a shorter list is how "my Russian definitions
/// disappeared" becomes unanswerable.
public struct UnreadableDictionary: Hashable, Sendable {
    public let file: URL
    public let reason: String
}

/// What is installed, in the order the reader wants it.
///
/// ### Found by scanning, not by remembering where things were
///
/// Every `.hanreaderdict` in the dictionaries directory is installed, plus
/// the one in the app bundle. There is no stored path, so there is no path to
/// go stale — which on iOS it would, since the container directory's UUID
/// changes across installs and restores. The predecessor stored absolute
/// audio paths and broke exactly this way.
///
/// ### A dictionary describes itself
///
/// Name, languages, licence and attribution come from the container's own
/// `meta` table every time it is listed. Copying them into a registry would
/// let the Acknowledgements screen show a licence the file contradicts, and
/// attribution reaching the reader intact is a CC BY-SA obligation rather
/// than a nicety.
public struct DictionaryCatalogue: Sendable {
    public let installed: [InstalledDictionary]
    public let unreadable: [UnreadableDictionary]
    /// Imports that stopped part way, which the file says of itself by still
    /// carrying its job row. Not failures: importing the same source again
    /// carries on from where it stopped.
    public let unfinished: [URL]

    public init(
        installed: [InstalledDictionary],
        unreadable: [UnreadableDictionary] = [],
        unfinished: [URL] = [],
    ) {
        self.installed = installed
        self.unreadable = unreadable
        self.unfinished = unfinished
    }

    /// The extension a compiled dictionary has.
    public static let fileExtension = "hanreaderdict"

    /// What an import writes to until it finishes.
    ///
    /// A separate name, not the final one, and that settles three things at
    /// once. A reader re-importing a dictionary they already have does not
    /// lose it the moment the new import opens its destination and clears it.
    /// A container that stopped part way is recognised as unfinished by its
    /// name, so it needs no metadata, no job row and — crucially — no
    /// read-only open, which a half-written database in write-ahead mode
    /// cannot survive once its sidecar files are gone. And the name is still
    /// derived from the dictionary's own slug, so importing the same source
    /// again lands on the same file and carries on.
    public static let partialExtension = "hanreaderdict-import"

    /// Where an import of this dictionary should write.
    public static func partialFile(forSlug slug: String, in directory: URL) -> URL {
        directory.appendingPathComponent("\(slug).\(partialExtension)")
    }

    /// Where it belongs once it is finished.
    public static func finishedFile(forSlug slug: String, in directory: URL) -> URL {
        directory.appendingPathComponent("\(slug).\(fileExtension)")
    }

    public var isEmpty: Bool {
        installed.isEmpty
    }
}

// MARK: - Building the set to look words up in

extension DictionaryCatalogue {
    /// Opens every installed dictionary that is allowed to answer something.
    ///
    /// A container that will not open is reported rather than dropped, for
    /// the same reason the catalogue lists an unreadable file.
    public func makeSet() -> (set: DictionarySet, unreadable: [UnreadableDictionary]) {
        var members: [DictionarySet.Member] = []
        var failures: [UnreadableDictionary] = []

        for entry in installed.sorted(by: { $0.sortOrder < $1.sortOrder }) {
            guard entry.providesGlosses || entry.providesReadings else { continue }
            do {
                try members.append(DictionarySet.Member(
                    slug: entry.slug,
                    lookup: DictionaryContainer(contentsOf: entry.file),
                    providesGlosses: entry.providesGlosses,
                    providesReadings: entry.providesReadings,
                ))
            } catch {
                failures.append(UnreadableDictionary(
                    file: entry.file,
                    reason: String(describing: error),
                ))
            }
        }
        return (DictionarySet(members: members), failures)
    }

    /// The toneless syllables the installed dictionaries use.
    ///
    /// Needed when importing a new one: a DSL dictionary writes its readings
    /// as diacritics, and splitting `tǔ'ěrqísītǎn` into syllables is what
    /// makes it comparable with CC-CEDICT's numeric form. Without them a
    /// reading still displays exactly as written and only the
    /// cross-dictionary merge key is lost, so this degrades rather than
    /// fails.
    public func syllableBases() -> Set<String> {
        var bases: Set<String> = []
        for entry in installed where entry.providesReadings {
            bases.formUnion(
                (try? DictionaryContainer(contentsOf: entry.file).syllableBases()) ?? [],
            )
        }
        return bases
    }

    /// The segmentation word list, from the dictionaries allowed to supply
    /// one.
    ///
    /// Opt-in per dictionary, and off by default for one whose headwords are
    /// not words. BKRS contributes **1,806,893** lexemes: a quarter of a
    /// gigabyte held for the life of the process, and a word list in which
    /// almost every run of Han characters is a word — which is the condition
    /// under which maximum-matching produces confident nonsense. CC-CEDICT's
    /// 163,746 are genuinely word-level and cost a few megabytes.
    public func lexicon() -> Lexicon {
        var lexemes: [Lexeme] = []
        for entry in installed.sorted(by: { $0.sortOrder < $1.sortOrder })
            where entry.providesLexicon
        {
            lexemes += (try? DictionaryContainer(contentsOf: entry.file).lexicon()) ?? []
        }
        return Lexicon(lexemes)
    }
}

// MARK: - Reading the catalogue

extension AppDatabase {
    /// Lists what is installed, applying the reader's preferences.
    ///
    /// - Parameters:
    ///   - directory: where imported dictionaries live. Scanned; absent is
    ///     not an error, it is a reader who has imported nothing.
    ///   - bundled: the container shipped with the app, if there is one.
    ///   - preferredLanguages: the reader's own languages, used to order a
    ///     dictionary they have never had an opinion about — so a
    ///     Russian-locale reader sees a Russian dictionary first with no
    ///     configuration at all.
    public static func catalogue(
        in directory: URL,
        bundled: URL?,
        library: LibraryRepository,
        preferredLanguages: [String] = Locale.preferredLanguages,
        fileManager: FileManager = .default,
    ) async throws
        -> DictionaryCatalogue
    {
        var files: [(url: URL, isBuiltIn: Bool)] = bundled.map { [($0, true)] } ?? []
        let contents = (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
        )) ?? []
        files += contents
            .filter { $0.pathExtension == DictionaryCatalogue.fileExtension }
            // Sorted so the list is the same on every launch, whatever order
            // the file system happens to answer in.
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { ($0, false) }
        // Recognised by name rather than by opening it. A container an
        // import did not finish has no metadata to read, and may not open
        // read-only at all.
        let partial = contents
            .filter { $0.pathExtension == DictionaryCatalogue.partialExtension }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        let preferences = try await library.dictionaryPreferences()
        var catalogue = Accumulator()
        for (url, isBuiltIn) in files {
            catalogue.add(
                url,
                isBuiltIn: isBuiltIn,
                preferences: preferences,
                preferredLanguages: preferredLanguages,
            )
        }
        return catalogue.result(unfinished: partial)
    }

    /// Builds a catalogue one file at a time.
    ///
    /// Three outcomes per file, and keeping them apart is the point: a
    /// dictionary, an import that stopped part way, and a file that is not
    /// either. Only the last is a failure.
    private struct Accumulator {
        var installed: [InstalledDictionary] = []
        var unreadable: [UnreadableDictionary] = []

        func result(unfinished: [URL]) -> DictionaryCatalogue {
            DictionaryCatalogue(
                installed: installed,
                unreadable: unreadable,
                unfinished: unfinished,
            )
        }

        mutating func add(
            _ url: URL,
            isBuiltIn: Bool,
            preferences: [String: DictionaryPreference],
            preferredLanguages: [String],
        ) {
            do {
                guard let metadata = try DictionaryContainer(contentsOf: url).metadata() else {
                    unreadable.append(UnreadableDictionary(
                        file: url,
                        reason: "the file has no dictionary metadata",
                    ))
                    return
                }
                let stored = preferences[metadata.slug]
                installed.append(InstalledDictionary(
                    metadata: metadata,
                    file: url,
                    isBuiltIn: isBuiltIn,
                    providesGlosses: stored?.providesGlosses ?? true,
                    providesReadings: stored?.providesReadings ?? true,
                    // A word list is opt-in, so a dictionary nobody has had
                    // an opinion about does not silently cost a quarter of a
                    // gigabyte. The bundled one is the exception: it is
                    // word-level, and it is the lexicon the reader has until
                    // they say otherwise.
                    providesLexicon: stored?.providesLexicon ?? isBuiltIn,
                    sortOrder: stored?.sortOrder ?? AppDatabase.defaultOrder(
                        for: metadata,
                        preferredLanguages: preferredLanguages,
                    ),
                ))
            } catch {
                unreadable.append(UnreadableDictionary(
                    file: url,
                    reason: String(describing: error),
                ))
            }
        }
    }

    /// Where a dictionary the reader has not ordered should sit.
    ///
    /// By how well its gloss language matches theirs, most-preferred first.
    /// A Russian-locale reader who imports БКРС should see Russian first
    /// without touching a setting — and an English-locale reader importing
    /// the same file should not.
    ///
    /// Ties keep their discovery order, which puts the bundled dictionary
    /// first among equals because it is scanned first.
    static func defaultOrder(
        for metadata: DictionaryMetadata,
        preferredLanguages: [String],
    )
        -> Int
    {
        let gloss = metadata.glossLanguage.lowercased()
        for (rank, language) in preferredLanguages.enumerated() {
            let code = language.lowercased()
            // `ru` matches `ru-RU`, and `zh-Hans` matches `zh-Hans-CN`,
            // either way round — a reader whose system language is `ru-RU`
            // wants a dictionary that says `ru`.
            if code == gloss || code.hasPrefix(gloss + "-") || gloss.hasPrefix(code + "-") {
                return rank
            }
        }
        // Below everything the reader reads, but in a stable place.
        return preferredLanguages.count + 1
    }
}
