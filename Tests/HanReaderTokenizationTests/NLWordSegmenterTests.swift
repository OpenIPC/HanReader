// HanReader — MIT licensed. See LICENSE.

import HanReaderCore
import Testing
@testable import HanReaderTokenization

/// Tests for Apple's tokenizer.
///
/// These assert **invariants only**, never exact segmentation. `NLTokenizer`
/// is a closed model whose output for a given sentence can change with an OS
/// release, so an assertion like `tokenize("我喜欢学习中文") == [...]` would be
/// flaky by construction — green on one OS and red on the next, with nothing
/// in the project at fault. `MaxMatchSegmenter` is what the suite pins
/// exactly; this is what checks the wrapper around Apple's model behaves.
@Suite("Apple tokenizer")
struct NLWordSegmenterTests {
    private let segmenter = TextSegmenter.system()

    /// The invariant that matters most, and the one the prototype violated:
    /// it dropped whitespace-only gaps, so any text mixing Latin with Chinese
    /// lost its spaces and could not be reassembled.
    @Test("Segmentation is lossless", arguments: [
        "我爱你",
        "中国人民解放军在北京举行了阅兵式",
        "他不好意思地笑了笑，说这是什么意思",
        "中文 with English 和 123 numbers!",
        "第一段\n\n第二段",
        "他买了3个iPhone 15",
        "",
        "   ",
        "龘靐齉",
    ])
    func lossless(text: String) {
        let document = segmenter.segment(text)
        #expect(document.reassembled() == text, "did not round-trip \(text.debugDescription)")
        #expect(document.isWellFormed, "tiling broken for \(text.debugDescription)")
    }

    @Test("Han runs are split into more than one token")
    func actuallySegments() {
        let document = segmenter.segment("中国人民解放军在北京举行了阅兵式")
        let han = document.blocks.flatMap(\.tokens).filter { $0.kind == .han }
        // Exactly how it splits is Apple's business; that it splits at all is
        // ours.
        #expect(han.count > 3)
        #expect(han.allSatisfy { !$0.text.isEmpty })
    }

    /// Script handling is ours, not the tokenizer's, so this can be exact.
    @Test("Non-Han runs are handled by our own classifier")
    func scriptRuns() {
        let tokens = segmenter.segment("他买了3个iPhone 15").blocks.flatMap(\.tokens)
        #expect(tokens.contains { $0.text == "iPhone" && $0.kind == .latin })
        #expect(tokens.contains { $0.text == "15" && $0.kind == .number })
        #expect(tokens.contains { $0.text == "3" && $0.kind == .number })
    }

    @Test("Paragraph structure survives")
    func paragraphs() {
        let document = segmenter.segment("第一段\n第二段\n\n第四段")
        #expect(document.blocks.count == 4)
        #expect(document.blocks.map(\.kind) == [.paragraph, .paragraph, .blankLine, .paragraph])
    }

    /// The documented weakness: good but inconsistent. Rather than assert
    /// which way it goes — which could change — this checks that the repair
    /// pass produces a sane result either way.
    @Test("Repair leaves the output well formed whatever the tokenizer did")
    func repairIsSafe() {
        let lexicon = Lexicon(words: ["一个人", "三个", "这个", "苹果", "好吃"])
        let text = "这个苹果很好吃我一个人吃了三个"
        let repaired = DictionaryRepairPass(lexicon: lexicon).repair(segmenter.segment(text))

        #expect(repaired.isWellFormed)
        #expect(repaired.reassembled() == text)
        // Merging only, so the token count can never grow.
        #expect(repaired.tokenCount <= segmenter.segment(text).tokenCount)
    }
}
