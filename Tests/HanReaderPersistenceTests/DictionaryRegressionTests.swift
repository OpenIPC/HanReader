// HanReader — MIT licensed. See LICENSE.

import Foundation
import HanReaderCore
import Testing
@testable import HanReaderPersistence

/// Regressions for things that were wrong in the first version of the
/// dictionary pipeline. Most concern traditional script, which was stored but
/// never actually used.
@Suite("Dictionary regressions")
struct DictionaryRegressionTests {
    private static func entry(
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

    private static func container(_ entries: [DictionaryEntry]) throws
        -> (DictionaryContainer, () -> Void)
    {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("t.hanreaderdict")
        try DictionaryContainer.write(
            entries: entries,
            metadata: DictionaryMetadata(
                slug: "t",
                displayName: "T",
                format: "cc-cedict",
                indexLanguage: "zh-Hans",
                glossLanguage: "en",
                licence: "CC BY-SA 4.0",
                attribution: "test",
                parserVersion: 1,
                entryCount: entries.count,
            ),
            to: url,
        )
        return try (
            DictionaryContainer(contentsOf: url),
            { try? FileManager.default.removeItem(at: directory) },
        )
    }

    /// Storing the traditional form and then only ever querying the
    /// simplified one means a reader of traditional text finds nothing.
    @Test("A traditional headword is found", arguments: ["中国", "中國"])
    func traditionalLookup(query: String) throws {
        let (container, cleanup) = try Self.container([
            Self.entry("中国", traditional: "中國", reading: "Zhong1 guo2", glosses: ["China"]),
        ])
        defer { cleanup() }
        #expect(try container.entries(for: query).count == 1)
        #expect(try container.entries(for: query).first?.senses.first?.gloss.text == "China")
    }

    /// Without traditional lexemes, traditional text is segmented character
    /// by character.
    @Test("Both spellings reach the segmentation lexicon")
    func traditionalLexeme() throws {
        let (container, cleanup) = try Self.container([
            Self.entry("中国", traditional: "中國", reading: "Zhong1 guo2", glosses: ["China"]),
        ])
        defer { cleanup() }
        let words = try Set(container.lexicon().map(\.word))
        #expect(words.contains("中国"))
        #expect(words.contains("中國"))
    }

    /// 對 对 [dui4] gave a reading for 对 and none for 對.
    @Test("Both characters get a fallback reading", arguments: ["对", "對"])
    func traditionalCharacterReading(character: Character) throws {
        let (container, cleanup) = try Self.container([
            Self.entry("对", traditional: "對", reading: "dui4", glosses: ["correct"]),
        ])
        defer { cleanup() }
        #expect(try container.readings(forCharacter: character).first?.display == "duì")
    }

    /// Folding `Su4` and `su4` under one key discarded a candidate before the
    /// lowercase-first ordering ever ran, so a surname with more senses
    /// silently replaced the reading wanted in prose.
    @Test("A capitalised surname does not displace the prose reading")
    func surnameDoesNotDisplace() {
        let readings = LexiconBuilder.characterReadings(from: [
            // The surname deliberately has MORE senses, which is what made
            // the old dedup pick it.
            Self.entry(
                "宿",
                reading: "Su4",
                glosses: ["surname Su", "a place", "another"],
                kind: .label,
            ),
            Self.entry("宿", reading: "su4", glosses: ["to stay overnight"]),
        ]).filter { $0.character == "宿" }

        #expect(readings.count == 2, "both readings should survive deduplication")
        #expect(readings.first?.numeric == "su4", "the lowercase reading should rank first")
    }

    /// A reference-only entry with more senses used to replace a real
    /// definition for the same reading.
    @Test("A cross-reference does not displace a definition")
    func referenceDoesNotDisplace() {
        let readings = LexiconBuilder.characterReadings(from: [
            Self.entry(
                "妳",
                reading: "ni3",
                glosses: ["variant of 你", "also", "see"],
                kind: .reference,
            ),
            Self.entry("妳", reading: "ni3", glosses: ["you (feminine)"]),
        ]).filter { $0.character == "妳" }

        #expect(readings.count == 1)
        #expect(readings.first?.numeric == "ni3")
    }

    /// The licence is read from the source rather than assumed. This
    /// repository's own fixture declares BY-SA 3.0 while current upstream is
    /// BY-SA 4.0, so a hardcoded value would be a false licensing statement.
    @Test("The licence comes from the source", arguments: [
        ("http://creativecommons.org/licenses/by-sa/3.0/", "CC BY-SA 3.0"),
        ("https://creativecommons.org/licenses/by-sa/4.0/", "CC BY-SA 4.0"),
        ("https://example.invalid/custom-terms", "https://example.invalid/custom-terms"),
    ])
    func licenceFromSource(url: String, expected: String) {
        #expect(DictionaryMetadata.licenceName(from: url) == expected)

        let metadata = DictionaryMetadata.ccCEDICT(
            entryCount: 1, sourceVersion: nil, licenceURL: url, parserVersion: 1,
        )
        #expect(metadata.licence == expected)
        // The attribution must name the same terms, not a different version.
        #expect(metadata.attribution.contains(expected))
    }
}
