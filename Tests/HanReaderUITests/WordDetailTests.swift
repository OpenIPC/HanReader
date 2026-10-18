// HanReader — MIT licensed. See LICENSE.

import HanReaderCore
import Testing
@testable import HanReaderUI

@MainActor
@Suite("Word detail")
struct WordDetailTests {
    private func entry(
        _ word: String,
        _ numeric: String,
        _ glosses: [(SenseKind, String)],
    )
        -> DictionaryEntry
    {
        DictionaryEntry(
            headword: Headword(simplified: word, traditional: nil),
            reading: Pinyin.parse(numeric: numeric),
            senses: glosses.enumerated().map { index, pair in
                Sense(id: index, kind: pair.0, gloss: Gloss(text: pair.1))
            },
        )
    }

    /// 重 as the reader meets it: `chóng` "to repeat" first, because that is
    /// CC-CEDICT's row order, and `zhòng` "heavy" second.
    private var heavyOrRepeat: [ReadingGroup] {
        [
            ReadingGroup(readingKey: "chong2", entries: [
                AttributedEntry(
                    dictionary: "cc-cedict",
                    entry: entry("重", "chong2", [(.definition, "to repeat")]),
                ),
            ]),
            ReadingGroup(readingKey: "zhong4", entries: [
                AttributedEntry(
                    dictionary: "cc-cedict",
                    entry: entry("重", "zhong4", [(.definition, "heavy")]),
                ),
            ]),
        ]
    }

    /// The panel contradicting the word above it. With the reading chosen by
    /// context the headword read `zhòng` while the summary beside it, taken
    /// from whichever group came first, said "to repeat".
    @Test("The summary comes from the reading that is shown")
    func summaryFollowsTheReading() {
        let detail = WordDetail(
            word: "重",
            reading: TokenReading(display: "zhòng", source: .ambiguous),
            groups: heavyOrRepeat,
        )
        #expect(WordDetailPanel.summary(of: detail.entriesForDisplayedReading) == "heavy")
        #expect(detail.orderedGroups.first?.readingKey == "zhong4")
        // Every reading is still reachable; only the order changed.
        #expect(detail.orderedGroups.count == 2)
        #expect(Set(detail.orderedGroups.map(\.readingKey)) == ["chong2", "zhong4"])
    }

    @Test("A reading with no group of its own still shows the word's senses")
    func composedReadingFallsBackToEverything() {
        let detail = WordDetail(
            word: "重",
            reading: TokenReading(display: "chóngfù", source: .composed),
            groups: heavyOrRepeat,
        )
        #expect(detail.entriesForDisplayedReading.count == 2)
        #expect(detail.orderedGroups.map(\.readingKey) == ["chong2", "zhong4"])
    }

    @Test("With no reading at all nothing is reordered")
    func noReadingKeepsDictionaryOrder() {
        let detail = WordDetail(word: "重", reading: nil, groups: heavyOrRepeat)
        #expect(detail.orderedGroups.map(\.readingKey) == ["chong2", "zhong4"])
        #expect(detail.entriesForDisplayedReading.count == 2)
    }

    /// A sense that only says "variant of 妳" is a poor one-line summary,
    /// which is why `SenseKind` exists at all.
    @Test("The one-line summary prefers an entry that defines something")
    func prefersADefinition() {
        let entries = [
            entry("妳", "ni3", [(.reference, "variant of 你")]),
            entry("妳", "ni3", [(.definition, "you (female)")]),
        ]
        #expect(WordDetailPanel.summary(of: entries) == "you (female)")
    }

    @Test("A cross-reference is still shown when there is nothing better")
    func fallsBackToAReference() {
        let entries = [entry("妳", "ni3", [(.reference, "variant of 你")])]
        #expect(WordDetailPanel.summary(of: entries) == "variant of 你")
    }

    @Test("No entries means no summary")
    func noEntries() {
        #expect(WordDetailPanel.summary(of: []).isEmpty)
    }

    /// A reader deciding whether to trust an annotation should not have to
    /// infer it from a shade of grey, so the expanded surface says it.
    @Test("An approximate reading carries an explanation", arguments: [
        ReadingSource.ambiguous, .composed,
    ])
    func approximateReadingsAreExplained(source: ReadingSource) {
        #expect(source.isApproximate)
        #expect(WordDetailContent.caveat(for: source) != nil)
    }

    @Test("A certain reading needs no explanation")
    func certainReadingsAreNotExplained() {
        #expect(!ReadingSource.dictionary.isApproximate)
        #expect(WordDetailContent.caveat(for: .dictionary) == nil)
    }
}
