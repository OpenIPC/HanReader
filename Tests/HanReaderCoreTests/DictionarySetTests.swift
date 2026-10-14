// HanReader — MIT licensed. See LICENSE.

import Foundation
import Testing
@testable import HanReaderCore

// MARK: - Fixtures

/// A dictionary that answers from a table, so the merge can be tested without
/// a database.
private struct FakeDictionary: DictionaryLookup {
    var entries: [String: [DictionaryEntry]] = [:]
    var characters: [Character: [CharacterReading]] = [:]
    /// Set to make every lookup fail, as an unreadable container would.
    var broken = false

    func entries(for headword: String) throws -> [DictionaryEntry] {
        if broken {
            throw FakeFailure()
        }
        return entries[headword] ?? []
    }

    func readings(forCharacter character: Character) throws -> [CharacterReading] {
        if broken {
            throw FakeFailure()
        }
        return characters[character] ?? []
    }
}

private struct FakeFailure: Error {}

private func entry(
    _ simplified: String,
    reading: String,
    gloss: String,
)
    -> DictionaryEntry
{
    DictionaryEntry(
        headword: Headword(simplified: simplified, traditional: nil),
        reading: Pinyin.parse(numeric: reading),
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
    )
}

private func member(
    _ slug: String,
    _ entries: [String: [DictionaryEntry]],
    characters: [Character: [CharacterReading]] = [:],
    glosses: Bool = true,
    readings: Bool = true,
    broken: Bool = false,
)
    -> DictionarySet.Member
{
    DictionarySet.Member(
        slug: slug,
        lookup: FakeDictionary(entries: entries, characters: characters, broken: broken),
        providesGlosses: glosses,
        providesReadings: readings,
    )
}

@Suite("Dictionary set")
struct DictionarySetTests {
    // MARK: - Grouping by reading

    /// The crux of consulting two dictionaries at once. BKRS writes `liǎo`
    /// and CC-CEDICT `liao3`; both normalise to the same key, so a reader
    /// tapping 了 sees two readings with two answers each, not four entries
    /// with no indication which are the same word.
    @Test("Two dictionaries' entries group by reading, not by dictionary")
    func groupsByReading() {
        let set = DictionarySet(members: [
            member("cc-cedict", ["了": [
                entry("了", reading: "le5", gloss: "completed action marker"),
                entry("了", reading: "liao3", gloss: "to understand"),
            ]]),
            member("dabkrs", ["了": [
                entry("了", reading: "le5", gloss: "частица"),
                entry("了", reading: "liao3", gloss: "понимать"),
            ]]),
        ])

        let result = set.groups(for: "了")
        #expect(result.failures.isEmpty)
        #expect(result.groups.count == 2)
        #expect(result.groups.map(\.readingKey) == ["le5", "liao3"])
        #expect(result.groups[0].entries.map(\.dictionary) == ["cc-cedict", "dabkrs"])
        #expect(result.groups[0].entries.map(\.entry.senses[0].gloss.text)
            == ["completed action marker", "частица"])
    }

    /// Two dictionaries defining the same word are two answers. Merging them
    /// would mean choosing whose wording survives, which is a licensing
    /// problem as well as a usability one — the reason to install a second
    /// dictionary is to read what it says.
    @Test("Identical entries from two dictionaries are both kept")
    func neverDeduplicated() {
        let same = entry("爱", reading: "ai4", gloss: "to love")
        let set = DictionarySet(members: [
            member("one", ["爱": [same]]),
            member("two", ["爱": [same]]),
        ])
        let groups = set.groups(for: "爱").groups
        #expect(groups.count == 1)
        #expect(groups[0].entries.count == 2)
        #expect(groups[0].entries.map(\.dictionary) == ["one", "two"])
    }

    /// 77% of BKRS entries carry no reading at all, so they group together
    /// rather than each becoming a group of one.
    @Test("Entries with no reading form one group")
    func entriesWithoutReadings() {
        let set = DictionarySet(members: [
            member("dabkrs", ["碟仙": [
                DictionaryEntry(
                    headword: Headword(simplified: "碟仙", traditional: nil),
                    reading: [],
                    senses: entry("碟仙", reading: "", gloss: "спиритическая доска").senses,
                ),
                DictionaryEntry(
                    headword: Headword(simplified: "碟仙", traditional: nil),
                    reading: [],
                    senses: entry("碟仙", reading: "", gloss: "второе").senses,
                ),
            ]]),
        ])
        let groups = set.groups(for: "碟仙").groups
        #expect(groups.count == 1)
        #expect(groups[0].readingKey.isEmpty)
        #expect(groups[0].entries.count == 2)
        #expect(groups[0].readingDisplay.isEmpty)
    }

    /// The reader's order decides which answer a detail panel opens on, so a
    /// Russian-preferring reader who puts БКРС first sees Russian first.
    @Test("The reader's order decides which group comes first")
    func readerOrderDecides() {
        let entries = ["爱": [entry("爱", reading: "ai4", gloss: "to love")]]
        let russian = ["爱": [entry("爱", reading: "ai4", gloss: "любить")]]

        let englishFirst = DictionarySet(members: [
            member("cc-cedict", entries), member("dabkrs", russian),
        ])
        let russianFirst = DictionarySet(members: [
            member("dabkrs", russian), member("cc-cedict", entries),
        ])
        #expect(englishFirst.groups(for: "爱").groups[0].entries[0].dictionary == "cc-cedict")
        #expect(russianFirst.groups(for: "爱").groups[0].entries[0].dictionary == "dabkrs")
    }

    /// The display spelling comes from an entry, not from converting the key
    /// back — a round trip would lose the apostrophe the dictionary wrote.
    @Test("The displayed reading is the dictionary's own spelling")
    func readingDisplayKeepsItsSpelling() {
        let set = DictionarySet(members: [
            member("dabkrs", ["西安": [entry("西安", reading: "Xi1 an1", gloss: "Сиань")]]),
        ])
        #expect(set.groups(for: "西安").groups[0].readingDisplay == "Xī'ān")
    }

    @Test("A word nothing defines produces no groups")
    func noGroups() {
        let set = DictionarySet(members: [member("one", [:])])
        #expect(set.groups(for: "爱").groups.isEmpty)
    }

    // MARK: - One unreadable container

    /// One bad container should cost its own answers, not everyone else's.
    @Test("A dictionary that fails is skipped and reported")
    func brokenDictionaryIsSkipped() {
        let set = DictionarySet(members: [
            member("broken", ["爱": [entry("爱", reading: "ai4", gloss: "x")]], broken: true),
            member("good", ["爱": [entry("爱", reading: "ai4", gloss: "любить")]]),
        ])
        let result = set.groups(for: "爱")
        #expect(result.failures == ["broken"])
        #expect(result.groups.count == 1)
        #expect(result.groups[0].entries.map(\.dictionary) == ["good"])
    }

    // MARK: - Three permissions, not one switch

    /// A reader can turn off CC-CEDICT's English glosses and still need it:
    /// 77% of BKRS entries carry no reading, so its single-character
    /// headwords are what put pinyin on the page. One "enabled" switch would
    /// let them turn off the thing their ruby depends on.
    @Test("A dictionary disabled for glosses still supplies readings")
    func glossesOffReadingsOn() throws {
        let set = DictionarySet(members: [
            member("dabkrs", ["爱": [entry("爱", reading: "ai4", gloss: "любить")]]),
            member(
                "cc-cedict",
                ["爱": [entry("爱", reading: "ai4", gloss: "to love")]],
                characters: ["爱": [CharacterReading(
                    character: "爱",
                    numeric: "ai4",
                    display: "ài",
                    rank: 0,
                )]],
                glosses: false,
            ),
        ])

        // Not in the reader's definitions…
        let groups = set.groups(for: "爱").groups
        #expect(groups.count == 1)
        #expect(groups[0].entries.map(\.dictionary) == ["dabkrs"])

        // …but still above the word. One dictionary's entries, not both
        // concatenated: the first that has any, which here is БКРС.
        #expect(try set.readings(forCharacter: "爱").map(\.display) == ["ài"])
        #expect(try set.entries(for: "爱").count == 1)
    }

    @Test("A dictionary disabled for readings still supplies glosses")
    func readingsOffGlossesOn() throws {
        let set = DictionarySet(members: [
            member(
                "dabkrs",
                ["爱": [entry("爱", reading: "ai4", gloss: "любить")]],
                characters: ["爱": [CharacterReading(
                    character: "爱",
                    numeric: "ai4",
                    display: "ài",
                    rank: 0,
                )]],
                readings: false,
            ),
        ])
        #expect(set.groups(for: "爱").groups.count == 1)
        #expect(try set.readings(forCharacter: "爱").isEmpty)
        #expect(try set.entries(for: "爱").isEmpty)
    }

    /// Interleaving two containers' rankings produces an order neither
    /// dictionary would endorse, so the reader's ordering decides instead.
    @Test("Character readings come from the first dictionary that has any")
    func characterReadingsAreNotInterleaved() throws {
        let first = CharacterReading(character: "行", numeric: "xing2", display: "xíng", rank: 0)
        let second = CharacterReading(character: "行", numeric: "hang2", display: "háng", rank: 0)
        let set = DictionarySet(members: [
            member("empty", [:]),
            member("one", [:], characters: ["行": [first]]),
            member("two", [:], characters: ["行": [second]]),
        ])
        #expect(try set.readings(forCharacter: "行") == [first])
    }

    /// Ranking a reading partly by how many senses carry it is sound within
    /// one dictionary and meaningless across two. BKRS gives every reading of
    /// a card the same sense run by design, so all of 打's readings have 57
    /// senses and the tie falls to alphabetical order — which is how adding a
    /// second dictionary turned 遭打 from `zāo dǎ` into `zāo dá` on screen.
    @Test("A reading comes from one dictionary, not from both at once")
    func readingsComeFromOneDictionary() throws {
        let cedict = ["打": [
            entry("打", reading: "da2", gloss: "dozen"),
            entry("打", reading: "da3", gloss: "to beat"),
        ]]
        // Same two readings, equal sense counts — the shape that outvoted
        // CC-CEDICT's ranking when the two were concatenated.
        let bkrs = ["打": [
            entry("打", reading: "da2", gloss: "дюжина"),
            entry("打", reading: "da3", gloss: "бить"),
        ]]

        let cedictFirst = DictionarySet(members: [
            member("cc-cedict", cedict), member("dabkrs", bkrs),
        ])
        #expect(try cedictFirst.entries(for: "打").map(\.senses[0].gloss.text)
            == ["dozen", "to beat"])

        let bkrsFirst = DictionarySet(members: [
            member("dabkrs", bkrs), member("cc-cedict", cedict),
        ])
        #expect(try bkrsFirst.entries(for: "打").map(\.senses[0].gloss.text)
            == ["дюжина", "бить"])
    }

    /// A dictionary that does not have the word is skipped rather than
    /// ending the search, or the first dictionary would be the only one that
    /// ever supplied a reading.
    @Test("The first dictionary that has the word supplies its reading")
    func firstWithTheWord() throws {
        let set = DictionarySet(members: [
            member("sparse", [:]),
            member("full", ["爱": [entry("爱", reading: "ai4", gloss: "любить")]]),
        ])
        #expect(try set.entries(for: "爱").count == 1)
    }

    @Test("An empty set answers nothing rather than failing")
    func emptySet() throws {
        let set = DictionarySet(members: [])
        #expect(set.isEmpty)
        #expect(set.groups(for: "爱").groups.isEmpty)
        #expect(try set.entries(for: "爱").isEmpty)
        #expect(try set.readings(forCharacter: "爱").isEmpty)
    }
}
