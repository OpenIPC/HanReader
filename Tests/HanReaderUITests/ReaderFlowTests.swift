// HanReader — MIT licensed. See LICENSE.

import HanReaderCore
import Testing
@testable import HanReaderUI

@Suite("Reader flow")
struct ReaderFlowTests {
    private let separated = ReaderStyle(fontSize: 22, spacing: .separated)
    private let continuous = ReaderStyle(fontSize: 22, spacing: .continuous)

    /// Segments with an empty lexicon, so every Han character is its own
    /// token. Spacing is a question about token adjacency, and one character
    /// per token is the densest arrangement of the cases that matter.
    private func tokens(_ text: String) -> [Token] {
        TextSegmenter(words: CharacterSegmenter()).segment(text).blocks.first?.tokens ?? []
    }

    private func spaces(_ text: String, style: ReaderStyle) -> [Double] {
        ReaderFlow.flowValues(for: tokens(text), style: style).map(\.leadingSpace)
    }

    @Test("Separates adjacent words and nothing else")
    func separatesWords() {
        let gap = separated.wordSpacing
        #expect(spaces("我爱你", style: separated) == [0, gap, gap])
    }

    @Test("Continuous spacing inserts no gaps at all")
    func continuousInsertsNothing() {
        #expect(spaces("我爱你", style: continuous) == [0, 0, 0])
    }

    /// `你好 ， 世界` is what word spacing around punctuation looks like, and
    /// it is wrong on both sides: a mark already separates what it divides.
    @Test("No gap on either side of punctuation")
    func punctuationIsNotSpaced() {
        let gap = separated.wordSpacing
        // 你 好 ， 世 界
        #expect(spaces("你好，世界", style: separated) == [0, gap, 0, 0, gap])
    }

    /// A space in the source is its own token carrying a space glyph's
    /// advance. Adding word spacing on both sides of it triples the gap, which
    /// is what makes a sentence mixing Chinese and English look broken.
    @Test("No gap on either side of real whitespace")
    func whitespaceIsNotSpaced() {
        let gap = separated.wordSpacing
        let text = "我爱 iPhone 15。"
        let kinds = tokens(text).map(\.kind)
        #expect(kinds == [.han, .han, .whitespace, .latin, .whitespace, .number, .punctuation])
        // Exactly one gap in the whole line: between the two Han characters.
        #expect(spaces(text, style: separated) == [0, gap, 0, 0, 0, 0, 0])
    }

    @Test("The first token of a paragraph has no leading space")
    func firstTokenHasNoLeadingSpace() {
        #expect(spaces("我", style: separated) == [0])
        #expect(spaces("。我", style: separated).first == 0)
    }

    @Test("Spacing is zero for an out-of-range index")
    func outOfRangeIndexIsZero() {
        let list = tokens("我爱")
        #expect(ReaderFlow.leadingSpace(beforeTokenAt: 99, in: list, style: separated) == 0)
        #expect(ReaderFlow.leadingSpace(beforeTokenAt: -1, in: list, style: separated) == 0)
    }

    // MARK: - Line-breaking flags

    /// The flags come from `LineBreakRules`, and the point of checking them
    /// here is that they reach the layout at all. A correct kinsoku table that
    /// nothing consults produces the same output as no table.
    @Test("Closing punctuation glues to the token before it")
    func closersGlue() {
        let values = ReaderFlow.flowValues(for: tokens("好。"), style: separated)
        #expect(!values[0].gluesToPrevious)
        #expect(values[1].gluesToPrevious)
    }

    @Test("A line may not end on an opening mark")
    func openersCannotEndALine() {
        let values = ReaderFlow.flowValues(for: tokens("（好"), style: separated)
        #expect(!values[0].canEndLine)
        #expect(values[1].canEndLine)
    }

    @Test("A word is neither glued nor barred from ending a line")
    func wordsAreUnconstrained() {
        for value in ReaderFlow.flowValues(for: tokens("中国人民"), style: separated) {
            #expect(!value.gluesToPrevious)
            #expect(value.canEndLine)
        }
    }

    /// A wrap that lands just before a source space would otherwise indent
    /// the next line by a space. The geometry of that is `layOutLines`' job
    /// and is tested there; what this checks is that the reader marks the
    /// right tokens — and only those.
    @Test("Only source whitespace collapses at a line start")
    func onlyWhitespaceCollapses() {
        let list = tokens("我爱 iPhone 15。")
        let values = ReaderFlow.flowValues(for: list, style: separated)
        for (token, value) in zip(list, values) {
            #expect(
                value.collapsesAtLineStart == (token.kind == .whitespace),
                "\(token.text) (\(token.kind))",
            )
        }
        #expect(values.contains { $0.collapsesAtLineStart })
    }

    @Test("Flow values are produced one per token")
    func oneValuePerToken() {
        let list = tokens(ReaderFixtures.proseSource)
        #expect(!list.isEmpty)
        #expect(ReaderFlow.flowValues(for: list, style: separated).count == list.count)
        #expect(ReaderFlow.flowValues(for: [], style: separated).isEmpty)
    }
}
