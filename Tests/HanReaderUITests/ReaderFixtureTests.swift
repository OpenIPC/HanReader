// HanReader — MIT licensed. See LICENSE.

import HanReaderCore
import Testing
@testable import HanReaderUI

/// The fixtures are what the reading surface is built and reviewed against, so
/// they get the same invariants as a real document. A fixture that silently
/// stopped covering a case — the blank line, the Latin run, the word with no
/// reading — would leave the previews looking fine and the case untested.
@Suite("Reader fixtures")
struct ReaderFixtureTests {
    private let document = ReaderFixtures.prose

    @Test("Tokens tile their blocks and blocks tile the source")
    func wellFormed() {
        #expect(document.isWellFormed)
        #expect(ReaderFixtures.phrase.isWellFormed)
    }

    @Test("Reassembles to the source exactly")
    func reassembles() {
        #expect(document.reassembled() == ReaderFixtures.proseSource)
    }

    @Test("Keeps the deliberate blank line")
    func keepsTheBlankLine() {
        #expect(document.blocks.contains { $0.kind == .blankLine })
    }

    @Test("Covers Latin, digits and full-width punctuation")
    func coversMixedScripts() {
        let kinds = Set(document.blocks.flatMap(\.tokens).map(\.kind))
        #expect(kinds.contains(.latin))
        #expect(kinds.contains(.number))
        #expect(kinds.contains(.punctuation))
        #expect(kinds.contains(.whitespace))
    }

    /// The case `RubyStack`'s unconditional reservation exists for: a word the
    /// dictionary does not cover must still occupy a full line's height, or
    /// lines would differ in height according to dictionary coverage.
    @Test("Contains at least one word with no reading")
    func coversAWordWithNoReading() {
        let readings = ReaderFixtures.readings(for: document)
        let words = document.blocks.flatMap(\.tokens).filter(\.isLookupCandidate)
        #expect(words.contains { readings[$0.id] == nil })
    }

    @Test("Every fixture reading is actually used")
    func noDeadReadings() {
        let present = Set(document.blocks.flatMap(\.tokens).map(\.text))
        let unused = ReaderFixtures.readingsByWord.keys.filter { !present.contains($0) }
        #expect(unused.isEmpty, "unused fixture readings: \(unused.sorted())")
    }

    /// Pins the repair pass's contribution. The deterministic segmenter can
    /// split 三个 across two tokens; the repair pass is what puts it back
    /// together, and a fixture that did not exercise it would hide a
    /// regression there.
    @Test("Multi-character words survive segmentation as single tokens")
    func wordsStayWhole() {
        let texts = Set(document.blocks.flatMap(\.tokens).map(\.text))
        for word in ["我们", "一家人", "中国", "人民", "解放军", "三个", "照片"] {
            #expect(texts.contains(word), "\(word) was split")
        }
    }

    @Test("Selecting a lemma matches every occurrence of it")
    func lemmaMatchesEveryOccurrence() {
        let matched = ReaderFixtures.tokens(matching: ["了"], in: document)
        // 了 appears three times, once in each of the three prose paragraphs:
        // 举行了阅兵式 · 笑了笑 · 我拍了三个照片.
        #expect(matched.count == 3)
        for id in matched {
            #expect(document[id]?.text == "了")
        }
    }

    @Test("An unknown lemma matches nothing")
    func unknownLemmaMatchesNothing() {
        #expect(ReaderFixtures.tokens(matching: ["龘"], in: document).isEmpty)
    }
}
