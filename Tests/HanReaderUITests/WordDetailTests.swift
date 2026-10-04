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
