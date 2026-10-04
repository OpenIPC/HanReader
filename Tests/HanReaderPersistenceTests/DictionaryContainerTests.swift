// HanReader — MIT licensed. See LICENSE.

import Foundation
import HanReaderCore
import Testing
@testable import HanReaderPersistence

/// Entries built in code rather than parsed, so these tests exercise the
/// container and not the CC-CEDICT parser, which has its own suite.
private enum Sample {
    static func entry(
        _ simplified: String,
        traditional: String? = nil,
        reading: String,
        glosses: [String],
        kind: SenseKind = .definition,
    )
        -> DictionaryEntry
    {
        DictionaryEntry(
            headword: Headword(simplified: simplified, traditional: traditional),
            reading: Pinyin.parse(numeric: reading),
            senses: glosses.enumerated().map { index, text in
                Sense(id: index, kind: kind, gloss: Gloss(text: text))
            },
        )
    }

    /// Deliberately includes both readings of 了 and three of 和, because the
    /// defect this container exists to fix is keeping only one.
    static let entries: [DictionaryEntry] = [
        entry("你好", reading: "ni3 hao3", glosses: ["Hello!", "Hi!"]),
        entry("中国", traditional: "中國", reading: "Zhong1 guo2", glosses: ["China"]),
        entry("了", reading: "le5", glosses: ["(modal particle)"]),
        entry("了", reading: "liao3", glosses: ["to finish", "to understand"]),
        entry("和", reading: "he2", glosses: ["and", "with"]),
        entry("和", reading: "he4", glosses: ["to compose a poem in reply"]),
        entry("和", reading: "huo2", glosses: ["to mix together"]),
        entry("略", reading: "lu:e4", glosses: ["plan", "slightly"]),
        entry("学", reading: "xue2", glosses: ["to learn", "science"]),
        entry("习", reading: "xi2", glosses: ["to practise"]),
        entry("北京", reading: "Bei3 jing1", glosses: ["Beijing"]),
        entry("妳", reading: "ni3", glosses: ["variant of 你"], kind: .reference),
    ]

    static let metadata = DictionaryMetadata(
        slug: "sample",
        displayName: "Sample Dictionary",
        format: "cc-cedict",
        indexLanguage: "zh-Hans",
        glossLanguage: "en",
        licence: "CC BY-SA 4.0",
        attribution: "Sample data for tests.",
        parserVersion: 1,
        entryCount: entries.count,
    )

    /// Writes a container to a temporary location and hands back its URL
    /// along with a cleanup closure.
    struct Opened {
        let container: DictionaryContainer
        let url: URL
        let cleanup: () -> Void
    }

    static func makeContainer() throws -> Opened {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("sample.hanreaderdict")
        try DictionaryContainer.write(entries: entries, metadata: metadata, to: url)
        return try Opened(
            container: DictionaryContainer(contentsOf: url),
            url: url,
            cleanup: { try? FileManager.default.removeItem(at: directory) },
        )
    }
}

@Suite("Dictionary container")
struct DictionaryContainerTests {
    @Test("Entries round-trip through the container")
    func roundTrip() throws {
        let opened = try Sample.makeContainer()
        defer { opened.cleanup() }
        let container = opened.container

        #expect(try container.entryCount() == Sample.entries.count)

        let found = try container.entries(for: "你好")
        #expect(found.count == 1)
        #expect(found[0].readingDisplay == "nǐhǎo")
        #expect(found[0].senses.map(\.gloss.text) == ["Hello!", "Hi!"])
    }

    /// The defect this whole design exists to prevent. Lookup returns a list,
    /// not an optional, so there is no `LIMIT 1` to get wrong.
    @Test("Every entry for a homograph is returned", arguments: [
        ("和", 3), ("了", 2), ("你好", 1),
    ])
    func homographs(word: String, expected: Int) throws {
        let opened = try Sample.makeContainer()
        defer { opened.cleanup() }
        let container = opened.container
        #expect(try container.entries(for: word).count == expected)
    }

    @Test("Both readings of 了 survive with distinct keys")
    func distinctReadings() throws {
        let opened = try Sample.makeContainer()
        defer { opened.cleanup() }
        let container = opened.container
        let keys = try Set(container.entries(for: "了").map(\.readingKey))
        #expect(keys == ["le5", "liao3"])
    }

    @Test("Traditional forms survive, and identical ones stay nil")
    func traditional() throws {
        let opened = try Sample.makeContainer()
        defer { opened.cleanup() }
        let container = opened.container
        #expect(try container.entries(for: "中国")[0].headword.traditional == "中國")
        #expect(try container.entries(for: "你好")[0].headword.traditional == nil)
    }

    @Test("An unknown headword returns an empty list rather than failing")
    func unknownHeadword() throws {
        let opened = try Sample.makeContainer()
        defer { opened.cleanup() }
        let container = opened.container
        #expect(try container.entries(for: "不存在的词").isEmpty)
    }

    /// Attribution has to travel inside the file, or it is not reliably
    /// available for a dictionary the user imported themselves — which is
    /// what CC BY-SA actually requires.
    @Test("Metadata round-trips, including the attribution text")
    func metadata() throws {
        let opened = try Sample.makeContainer()
        defer { opened.cleanup() }
        let container = opened.container

        let metadata = try #require(try container.metadata())
        #expect(metadata.slug == "sample")
        #expect(metadata.licence == "CC BY-SA 4.0")
        #expect(metadata.attribution == "Sample data for tests.")
        #expect(metadata.entryCount == Sample.entries.count)
        #expect(metadata.parserVersion == 1)
    }

    /// The bundled dictionary's attribution carries the statement of
    /// modifications that CC BY-SA requires for adaptations, and which is the
    /// part most often omitted.
    @Test("CC-CEDICT attribution states the changes made")
    func ccCEDICTAttribution() {
        let metadata = DictionaryMetadata.ccCEDICT(
            entryCount: 1,
            sourceVersion: nil,
            licenceURL: "https://creativecommons.org/licenses/by-sa/4.0/",
            parserVersion: 1,
        )
        #expect(metadata.licence == "CC BY-SA 4.0")
        #expect(metadata.attribution.contains("Changes made:"))
        #expect(metadata.attribution.contains("No entry content was altered"))
        #expect(metadata.sourceURL?.contains("mdbg.net") == true)
    }
}

@Suite("Derived lexicon")
struct LexiconTests {
    @Test("The lexicon holds the word-like headwords")
    func lexicon() throws {
        let opened = try Sample.makeContainer()
        defer { opened.cleanup() }
        let container = opened.container
        let words = try Set(container.lexicon().map(\.word))
        #expect(words.contains("你好"))
        #expect(words.contains("中国"))
        #expect(words.contains("学"))
    }

    /// A bare cross-reference is a spelling note, not a word to segment
    /// towards; treating it as one produces confident nonsense.
    @Test("A reference-only entry is excluded")
    func referenceOnlyExcluded() throws {
        let opened = try Sample.makeContainer()
        defer { opened.cleanup() }
        let container = opened.container
        #expect(try !Set(container.lexicon().map(\.word)).contains("妳"))
    }

    /// Measured against BKRS: 532,881 headwords are seven characters or
    /// longer. Maximum-matching over those swallows whole clauses.
    @Test("Nothing longer than the cap gets in")
    func lengthCap() {
        let long = Sample.entry(String(repeating: "字", count: 9), reading: "zi4", glosses: ["long"])
        let lexicon = LexiconBuilder.lexicon(from: Sample.entries + [long])
        #expect(lexicon.allSatisfy { $0.characterLength <= LexiconBuilder.maximumWordLength })
        #expect(!lexicon.contains { $0.word.count == 9 })
    }

    /// Latin and digits are handled by the tokenizer's own script runs;
    /// admitting them here would let a Han-run scan cross a script boundary.
    @Test("Mixed-script headwords are excluded")
    func mixedScriptExcluded() {
        let mixed = [
            Sample.entry("卡拉OK", reading: "ka3 la1 OK", glosses: ["karaoke"]),
            Sample.entry("3C产品", reading: "san1 C chan3 pin3", glosses: ["3C products"]),
        ]
        let words = Set(LexiconBuilder.lexicon(from: Sample.entries + mixed).map(\.word))
        #expect(!words.contains("卡拉OK"))
        #expect(!words.contains("3C产品"))
    }

    /// Greedy matching already prefers long matches structurally. Without a
    /// counterweight it reaches for a rare six-character idiom over two
    /// common words, which is how maximum-matching segmenters characteristically
    /// fail.
    @Test("Length is penalised, so a short word is not always outranked")
    func lengthIsPenalised() {
        let short = LexiconBuilder.weight(length: 2, senseCount: 8)
        let long = LexiconBuilder.weight(length: 6, senseCount: 1)
        #expect(short > long)
    }
}

@Suite("Character readings")
struct CharacterReadingTests {
    /// Not optional: 77% of BKRS entries carry no reading, so without this a
    /// reader using a Russian dictionary sees pinyin on almost nothing.
    @Test("Single characters get readings")
    func readings() throws {
        let opened = try Sample.makeContainer()
        defer { opened.cleanup() }
        let container = opened.container
        #expect(try container.readings(forCharacter: "学").first?.display == "xué")
        #expect(try container.readings(forCharacter: "习").first?.display == "xí")
    }

    @Test("A character with no entry has no readings rather than failing")
    func unknownCharacter() throws {
        let opened = try Sample.makeContainer()
        defer { opened.cleanup() }
        let container = opened.container
        #expect(try container.readings(forCharacter: "𠀋").isEmpty)
    }

    /// Capitals mark surnames and proper nouns, which are rarely the reading
    /// wanted for a character appearing in prose.
    @Test("A lowercase reading outranks a capitalised one")
    func lowercasePreferred() {
        let entries = [
            Sample.entry("宿", reading: "Su4", glosses: ["surname Su"], kind: .label),
            Sample.entry("宿", reading: "su4", glosses: ["to stay overnight", "lodging"]),
        ]
        let readings = LexiconBuilder.characterReadings(from: entries)
            .filter { $0.character == "宿" }
        #expect(readings.first?.numeric == "su4")
        #expect(readings.map(\.rank) == Array(0 ..< readings.count))
    }

    @Test("Multi-character headwords contribute no character readings")
    func onlySingleCharacters() {
        let readings = LexiconBuilder.characterReadings(from: [
            Sample.entry("你好", reading: "ni3 hao3", glosses: ["hello"]),
        ])
        #expect(readings.isEmpty)
    }
}

@Suite("Syllable inventory")
struct SyllableInventoryTests {
    /// Observed from the data rather than written out by hand, so it cannot
    /// disagree with the readings it will be used against.
    @Test("Bases are collected, lowercased and deduplicated")
    func bases() throws {
        let opened = try Sample.makeContainer()
        defer { opened.cleanup() }
        let container = opened.container
        let bases = try container.syllableBases()
        #expect(bases.contains("ni"))
        #expect(bases.contains("hao"))
        #expect(bases.contains("lüe")) // from lu:e4, normalised
        #expect(bases.contains("bei")) // from Bei3, lowercased
        #expect(!bases.contains("Bei"))
    }

    /// The inventory feeds the syllabifier, which is how a run-together BKRS
    /// reading is matched against a CC-CEDICT one.
    @Test("The inventory can segment a run-together reading")
    func feedsSyllabifier() throws {
        let opened = try Sample.makeContainer()
        defer { opened.cleanup() }
        let container = opened.container
        let bases = try container.syllableBases()
        let syllables = PinyinSyllabifier.syllables(fromDiacritic: "nǐhǎo", bases: bases)
        #expect(syllables?.map(\.numeric).joined(separator: " ") == "ni3 hao3")
    }
}
