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

    public init(installed: [InstalledDictionary], unreadable: [UnreadableDictionary] = []) {
        self.installed = installed
        self.unreadable = unreadable
    }

    /// The extension a compiled dictionary has.
    public static let fileExtension = "hanreaderdict"

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

        let preferences = try await library.dictionaryPreferences()
        var installed: [InstalledDictionary] = []
        var unreadable: [UnreadableDictionary] = []

        for (url, isBuiltIn) in files {
            do {
                guard let metadata = try DictionaryContainer(contentsOf: url).metadata() else {
                    unreadable.append(UnreadableDictionary(
                        file: url,
                        reason: "the file has no dictionary metadata",
                    ))
                    continue
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
                    sortOrder: stored?.sortOrder ?? defaultOrder(
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
        return DictionaryCatalogue(installed: installed, unreadable: unreadable)
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
