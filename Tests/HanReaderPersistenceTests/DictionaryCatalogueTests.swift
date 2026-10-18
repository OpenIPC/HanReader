// HanReader — MIT licensed. See LICENSE.

import Foundation
import HanReaderCore
import Testing
@testable import HanReaderPersistence

// MARK: - Fixtures

/// A throwaway directory with real compiled containers in it.
private struct Workspace: ~Copyable {
    let root: URL
    let library: LibraryRepository

    init() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("hanreader-catalogue-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        library = try LibraryRepository.inMemory()
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    var directory: URL {
        root.appendingPathComponent("dictionaries", isDirectory: true)
    }

    /// Compiles a one-word dictionary, so the catalogue has something real to
    /// open and read metadata from.
    @discardableResult
    func install(
        slug: String,
        glossLanguage: String,
        word: String = "爱",
        gloss: String = "to love",
        in folder: URL? = nil,
    ) throws
        -> URL
    {
        let url = (folder ?? directory)
            .appendingPathComponent("\(slug).\(DictionaryCatalogue.fileExtension)")
        try DictionaryContainer.write(
            entries: [DictionaryEntry(
                headword: Headword(simplified: word, traditional: nil),
                reading: Pinyin.parse(numeric: "ai4"),
                senses: [Sense(
                    id: 0,
                    kind: .definition,
                    gloss: Gloss(text: gloss, references: [], styles: []),
                    level: 0,
                    parent: nil,
                    label: nil,
                    partOfSpeech: [],
                    registers: [],
                    examples: [],
                )],
            )],
            metadata: DictionaryMetadata(
                slug: slug,
                displayName: slug.uppercased(),
                format: "test",
                indexLanguage: "zh-Hans",
                glossLanguage: glossLanguage,
                licence: "none",
                attribution: "none",
                parserVersion: 1,
                entryCount: 1,
            ),
            to: url,
        )
        return url
    }

    func catalogue(preferredLanguages: [String] = ["en"]) async throws -> DictionaryCatalogue {
        try await AppDatabase.catalogue(
            in: directory,
            bundled: nil,
            library: library,
            preferredLanguages: preferredLanguages,
        )
    }
}

@Suite("Dictionary catalogue")
struct DictionaryCatalogueTests {
    // MARK: - Discovery

    /// Found by scanning, not by remembering where things were. There is no
    /// stored path, so there is no path to go stale — which on iOS it would,
    /// since the container directory's UUID changes across installs.
    @Test("Every container in the directory is installed")
    func discovery() async throws {
        let workspace = try Workspace()
        try workspace.install(slug: "cc-cedict", glossLanguage: "en")
        try workspace.install(slug: "dabkrs", glossLanguage: "ru")

        let catalogue = try await workspace.catalogue()
        #expect(catalogue.installed.map(\.slug).sorted() == ["cc-cedict", "dabkrs"])
        #expect(catalogue.unreadable.isEmpty)
    }

    /// A dictionary describes itself. Copying its name and licence into a
    /// registry would let the Acknowledgements screen show a licence the file
    /// contradicts, and attribution reaching the reader intact is a CC BY-SA
    /// obligation.
    @Test("A dictionary's own metadata is what the list shows")
    func metadataComesFromTheFile() async throws {
        let workspace = try Workspace()
        try workspace.install(slug: "dabkrs", glossLanguage: "ru")

        let entry = try #require(try await workspace.catalogue().installed.first)
        #expect(entry.metadata.displayName == "DABKRS")
        #expect(entry.metadata.glossLanguage == "ru")
        #expect(!entry.isBuiltIn)
    }

    @Test("A reader who has imported nothing gets an empty catalogue")
    func nothingInstalled() async throws {
        let workspace = try Workspace()
        let catalogue = try await workspace.catalogue()
        #expect(catalogue.isEmpty)
        #expect(catalogue.unreadable.isEmpty)
    }

    /// Listed rather than hidden: a reader whose dictionary stopped working
    /// should be told which one. Showing a shorter list is how "my Russian
    /// definitions disappeared" becomes unanswerable.
    @Test("A file that will not open is listed, not dropped")
    func unreadableIsListed() async throws {
        let workspace = try Workspace()
        try workspace.install(slug: "good", glossLanguage: "en")
        try FileManager.default.createDirectory(
            at: workspace.directory,
            withIntermediateDirectories: true,
        )
        try Data("not a database".utf8).write(
            to: workspace.directory
                .appendingPathComponent("broken.\(DictionaryCatalogue.fileExtension)"),
        )

        let catalogue = try await workspace.catalogue()
        #expect(catalogue.installed.map(\.slug) == ["good"])
        #expect(catalogue.unreadable.count == 1)
        #expect(catalogue.unreadable[0].file.lastPathComponent
            == "broken.\(DictionaryCatalogue.fileExtension)")
    }

    @Test("A file with another extension is not a dictionary")
    func otherFilesIgnored() async throws {
        let workspace = try Workspace()
        try workspace.install(slug: "good", glossLanguage: "en")
        try Data("notes".utf8).write(
            to: workspace.directory.appendingPathComponent("notes.txt"),
        )
        let catalogue = try await workspace.catalogue()
        #expect(catalogue.installed.count == 1)
        #expect(catalogue.unreadable.isEmpty)
    }

    // MARK: - Order without configuration

    /// A Russian-locale reader who imports БКРС should see Russian first
    /// without touching a setting, and an English-locale reader importing the
    /// same file should not.
    @Test("A dictionary nobody has ordered sorts by the reader's own languages")
    func defaultOrderFollowsLocale() async throws {
        let workspace = try Workspace()
        try workspace.install(slug: "cc-cedict", glossLanguage: "en")
        try workspace.install(slug: "dabkrs", glossLanguage: "ru")

        let forRussian = try await workspace.catalogue(preferredLanguages: ["ru-RU", "en-GB"])
        #expect(forRussian.installed.sorted { $0.sortOrder < $1.sortOrder }
            .map(\.slug) == ["dabkrs", "cc-cedict"])

        let forEnglish = try await workspace.catalogue(preferredLanguages: ["en-GB", "ru-RU"])
        #expect(forEnglish.installed.sorted { $0.sortOrder < $1.sortOrder }
            .map(\.slug) == ["cc-cedict", "dabkrs"])
    }

    @Test("A language tag matches either way round", arguments: [
        (["ru-RU"], "ru", 0),
        (["ru"], "ru-RU", 0),
        (["en-GB", "ru"], "ru", 1),
        (["en"], "ru", 2),
    ])
    func languageMatching(preferred: [String], gloss: String, expected: Int) {
        let metadata = DictionaryMetadata(
            slug: "x",
            displayName: "X",
            format: "test",
            indexLanguage: "zh-Hans",
            glossLanguage: gloss,
            licence: "",
            attribution: "",
            parserVersion: 1,
            entryCount: 0,
        )
        #expect(AppDatabase.defaultOrder(
            for: metadata,
            preferredLanguages: preferred,
        ) == expected)
    }

    /// Once the reader has dragged a list into place, that is the order.
    @Test("A stored order overrides the locale default")
    func storedOrderWins() async throws {
        let workspace = try Workspace()
        try workspace.install(slug: "cc-cedict", glossLanguage: "en")
        try workspace.install(slug: "dabkrs", glossLanguage: "ru")
        try await workspace.library.setDictionaryOrder(["dabkrs", "cc-cedict"])

        let catalogue = try await workspace.catalogue(preferredLanguages: ["en"])
        #expect(catalogue.installed.sorted { $0.sortOrder < $1.sortOrder }
            .map(\.slug) == ["dabkrs", "cc-cedict"])
    }

    // MARK: - The three permissions

    @Test("Permissions default to on for glosses and readings")
    func defaultPermissions() async throws {
        let workspace = try Workspace()
        try workspace.install(slug: "dabkrs", glossLanguage: "ru")
        let entry = try #require(try await workspace.catalogue().installed.first)
        #expect(entry.providesGlosses)
        #expect(entry.providesReadings)
        // A word list is opt-in, so an imported dictionary does not silently
        // cost a quarter of a gigabyte at launch.
        #expect(!entry.providesLexicon)
    }

    @Test("A stored permission is applied")
    func storedPermissions() async throws {
        let workspace = try Workspace()
        try workspace.install(slug: "cc-cedict", glossLanguage: "en")
        try await workspace.library.save(DictionaryPreference(
            slug: "cc-cedict",
            providesGlosses: false,
            providesReadings: true,
            providesLexicon: true,
            sortOrder: 0,
        ))

        let entry = try #require(try await workspace.catalogue().installed.first)
        #expect(!entry.providesGlosses)
        #expect(entry.providesReadings)
        #expect(entry.providesLexicon)
    }

    @Test("Forgetting a dictionary restores its defaults")
    func forgetting() async throws {
        let workspace = try Workspace()
        try workspace.install(slug: "cc-cedict", glossLanguage: "en")
        try await workspace.library.save(DictionaryPreference(
            slug: "cc-cedict",
            providesGlosses: false,
        ))
        try await workspace.library.forgetDictionary("cc-cedict")
        #expect(try await workspace.catalogue().installed.first?.providesGlosses == true)
    }

    /// Writing the whole row means writing the values the caller read
    /// *before* the change, so a reader who flicks two switches in quick
    /// succession has the second write restore what the first one changed.
    @Test("Two permissions changed at once do not overwrite each other")
    func concurrentPermissionChanges() async throws {
        let workspace = try Workspace()
        try workspace.install(slug: "dabkrs", glossLanguage: "ru")
        let entry = try #require(try await workspace.catalogue().installed.first)
        let before = DictionaryPreference(
            slug: entry.slug,
            providesGlosses: entry.providesGlosses,
            providesReadings: entry.providesReadings,
            providesLexicon: entry.providesLexicon,
            sortOrder: entry.sortOrder,
        )

        // Both started from the same snapshot, as two taps in a row are.
        try await workspace.library.setDictionaryPermission(
            .glosses,
            to: false,
            matching: before,
        )
        try await workspace.library.setDictionaryPermission(
            .readings,
            to: false,
            matching: before,
        )

        let after = try #require(try await workspace.catalogue().installed.first)
        #expect(!after.providesGlosses, "the second change restored the first")
        #expect(!after.providesReadings)
    }

    /// The first write has to carry the values the catalogue was showing,
    /// including a sort order that came from the reader's languages rather
    /// than from zero.
    @Test("The first change keeps the order the catalogue was showing")
    func firstChangeKeepsOrder() async throws {
        let workspace = try Workspace()
        try workspace.install(slug: "dabkrs", glossLanguage: "ru")
        let entry = try #require(
            try await workspace.catalogue(preferredLanguages: ["ru"]).installed.first,
        )
        try await workspace.library.setDictionaryPermission(
            .lexicon,
            to: true,
            matching: DictionaryPreference(
                slug: entry.slug,
                providesGlosses: entry.providesGlosses,
                providesReadings: entry.providesReadings,
                providesLexicon: entry.providesLexicon,
                sortOrder: entry.sortOrder,
            ),
        )
        let after = try #require(try await workspace.catalogue().installed.first)
        #expect(after.providesLexicon)
        #expect(after.sortOrder == entry.sortOrder)
    }

    /// Recognised by name, so an unfinished container needs no metadata, no
    /// job row and no read-only open.
    @Test("An in-progress container is listed as unfinished")
    func unfinishedByName() async throws {
        let workspace = try Workspace()
        try workspace.install(slug: "cc-cedict", glossLanguage: "en")
        try FileManager.default.createDirectory(
            at: workspace.directory,
            withIntermediateDirectories: true,
        )
        // Not even a database: the name alone is what says it is unfinished.
        try Data("half written".utf8).write(to: DictionaryCatalogue.partialFile(
            forSlug: "dabkrs",
            in: workspace.directory,
        ))

        let catalogue = try await workspace.catalogue()
        #expect(catalogue.installed.map(\.slug) == ["cc-cedict"])
        #expect(catalogue.unfinished.count == 1)
        #expect(catalogue.unreadable.isEmpty)
    }

    // MARK: - Opening the set

    @Test("The set is built in the reader's order")
    func setOrder() async throws {
        let workspace = try Workspace()
        try workspace.install(slug: "cc-cedict", glossLanguage: "en", gloss: "to love")
        try workspace.install(slug: "dabkrs", glossLanguage: "ru", gloss: "любить")
        try await workspace.library.setDictionaryOrder(["dabkrs", "cc-cedict"])

        let (set, unreadable) = try await workspace.catalogue().makeSet()
        #expect(unreadable.isEmpty)
        #expect(set.members.map(\.slug) == ["dabkrs", "cc-cedict"])

        let groups = set.groups(for: "爱").groups
        #expect(groups.count == 1)
        #expect(groups[0].entries.map(\.dictionary) == ["dabkrs", "cc-cedict"])
        #expect(groups[0].entries.map(\.entry.senses[0].gloss.text) == ["любить", "to love"])
    }

    /// A dictionary allowed to do nothing is not opened at all, so turning
    /// everything off for a 500 MB container costs nothing to have installed.
    @Test("A dictionary with no permissions is not opened")
    func fullyDisabledIsNotOpened() async throws {
        let workspace = try Workspace()
        try workspace.install(slug: "dabkrs", glossLanguage: "ru")
        try await workspace.library.save(DictionaryPreference(
            slug: "dabkrs",
            providesGlosses: false,
            providesReadings: false,
        ))
        let (set, _) = try await workspace.catalogue().makeSet()
        #expect(set.isEmpty)
    }

    /// Opt-in, and off by default for a dictionary whose headwords are not
    /// words: BKRS contributes 1,806,893 lexemes, which is both a quarter of
    /// a gigabyte and a word list in which almost every run of Han characters
    /// is a word.
    @Test("Only dictionaries allowed to supply a word list contribute to it")
    func lexiconIsOptIn() async throws {
        let workspace = try Workspace()
        try workspace.install(slug: "cc-cedict", glossLanguage: "en", word: "中国")
        try workspace.install(slug: "dabkrs", glossLanguage: "ru", word: "一家人")

        #expect(try await workspace.catalogue().lexicon().isEmpty)

        try await workspace.library.save(DictionaryPreference(
            slug: "cc-cedict",
            providesLexicon: true,
        ))
        let lexicon = try await workspace.catalogue().lexicon()
        #expect(lexicon.contains("中国"))
        #expect(!lexicon.contains("一家人"))
    }
}
