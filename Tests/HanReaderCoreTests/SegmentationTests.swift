// HanReader — MIT licensed. See LICENSE.

import Foundation
import Testing
@testable import HanReaderCore

/// A small, fixed lexicon. Hermetic on purpose: the real one comes from a
/// dictionary, and a test that depended on it would change meaning whenever
/// the dictionary did.
private let testLexicon = Lexicon(words: [
    "中国", "人民", "解放军", "北京", "举行", "阅兵式",
    "不好意思", "什么", "意思", "一家人", "一个人", "三个", "这个",
    "苹果", "好吃", "学习", "朋友", "电脑", "咖啡", "谢谢",
    "我们", "你好", "中文", "有趣", "高铁", "出差", "上海", "昨天",
])

private func segmenter() -> TextSegmenter<MaxMatchSegmenter> {
    TextSegmenter(words: MaxMatchSegmenter(lexicon: testLexicon))
}

private func tokens(_ text: String) -> [String] {
    segmenter().segment(text).blocks.flatMap(\.tokens).map(\.text)
}

@Suite("Character classification")
struct ScalarClassTests {
    /// The prototype's hand-rolled block ranges were incomplete *and*
    /// over-broad. Both directions are pinned here.
    @Test("Han is recognised across all the planes", arguments: [
        "中", "文", "一", // common
        "〇", // the ideographic zero, which block ranges miss
        "\u{20000}", // Extension B, supplementary plane
        "\u{F900}", // compatibility ideograph
    ])
    func han(character: Character) {
        #expect(character.tokenKind == .han, "\(character) should be Han")
    }

    /// The over-broad half: U+FF00–U+FFEF contains fullwidth Latin and
    /// halfwidth katakana, which the prototype swept in as punctuation.
    @Test("Fullwidth Latin and digits are not punctuation")
    func fullwidth() {
        #expect(Character("Ａ").tokenKind == .latin)
        #expect(Character("ｚ").tokenKind == .latin)
        #expect(Character("１").tokenKind == .number)
        // But fullwidth punctuation genuinely is punctuation.
        #expect(Character("，").tokenKind == .punctuation)
        #expect(Character("。").tokenKind == .punctuation)
    }

    @Test("Everything else lands somewhere sensible")
    func others() {
        #expect(Character("a").tokenKind == .latin)
        #expect(Character("7").tokenKind == .number)
        #expect(Character(" ").tokenKind == .whitespace)
        #expect(Character(",").tokenKind == .punctuation)
        #expect(Character("、").tokenKind == .punctuation)
        #expect(Character("😀").tokenKind == .other)
        #expect(Character("я").tokenKind == .other) // Cyrillic is not Latin
    }
}

@Suite("Document structure")
struct DocumentStructureTests {
    /// The property that makes reading-position restore and audio alignment
    /// sound. Checked exhaustively below, but stated plainly here.
    @Test("Tokens tile their block and blocks tile the source", arguments: [
        "我爱你",
        "第一行\n第二行",
        "开头\n\n\n结尾",
        "中文 with English 和 123 numbers!",
        "  leading and trailing  ",
        "",
        "\n",
        "只有标点。！？",
    ])
    func wellFormed(text: String) {
        let document = segmenter().segment(text)
        #expect(document.isWellFormed, "tiling broken for \(text.debugDescription)")
        #expect(document.reassembled() == text, "did not round-trip \(text.debugDescription)")
        #expect(document.sourceLength == text.utf16.count)
    }

    /// Random input, because the inputs that break a tokenizer are the ones
    /// nobody thinks to write down.
    @Test("Tiling holds for arbitrary input")
    func wellFormedProperty() {
        let alphabet = Array("中文汉字abcXYZ0123 \n\t，。！?-—…😀я\u{20000}")
        var generator = SystemRandomNumberGenerator()
        for _ in 0 ..< 400 {
            let length = Int.random(in: 0 ... 60, using: &generator)
            let text = String((0 ..< length).compactMap { _ in
                alphabet.randomElement(using: &generator)
            })
            let document = segmenter().segment(text)
            #expect(document.isWellFormed, "tiling broken for \(text.debugDescription)")
            #expect(
                document.reassembled() == text,
                "round-trip failed for \(text.debugDescription)",
            )
        }
    }

    /// Paragraphs are modelled, not signalled by a sentinel token. The
    /// prototype's synthetic newline forced its layout to detect line breaks
    /// by measuring subview widths.
    @Test("Paragraphs become blocks")
    func paragraphs() {
        let document = segmenter().segment("第一段\n第二段\n\n第四段")
        #expect(document.blocks.count == 4)
        #expect(document.blocks.map(\.kind) == [.paragraph, .paragraph, .blankLine, .paragraph])
    }

    @Test("Empty input produces an empty document")
    func empty() {
        let document = segmenter().segment("")
        #expect(document.blocks.isEmpty)
        #expect(document.tokenCount == 0)
        #expect(document.isWellFormed)
    }

    /// A stored reading position is a UTF-16 offset, so it has to map back to
    /// a token even after the text is re-segmented by a different engine.
    @Test("An offset maps back to its token")
    func offsetLookup() {
        let text = "我爱中国人民"
        let document = segmenter().segment(text)
        let found = document.token(atOffset: 2)
        #expect(found != nil)
        #expect(found?.range.contains(2) == true)
        // Past the end clamps to the last token rather than returning nil.
        #expect(document.token(atOffset: 999) != nil)
    }

    /// Supplementary-plane characters are two UTF-16 units, so a naive
    /// character-count offset would drift.
    @Test("Ranges are UTF-16, not character counts")
    func utf16Ranges() {
        let text = "\u{20000}中" // one Ext-B char (2 units) + one BMP char (1)
        let document = segmenter().segment(text)
        #expect(document.sourceLength == 3)
        let all = document.blocks.flatMap(\.tokens)
        #expect(all.first?.range == 0 ..< 2)
        #expect(all.last?.range == 2 ..< 3)
    }
}

@Suite("Script runs")
struct ScriptRunTests {
    /// The prototype classified every non-word gap character as punctuation,
    /// so `iPhone 15` inside Chinese became punctuation tokens.
    @Test("Latin and digit runs stay whole")
    func latinAndDigits() {
        #expect(tokens("他买了3个iPhone 15") == ["他", "买", "了", "3", "个", "iPhone", " ", "15"])
    }

    @Test("Punctuation is one token per mark")
    func punctuation() {
        #expect(tokens("你好，世界！") == ["你好", "，", "世", "界", "！"])
    }

    /// Kept as a single token so the text reassembles exactly; the prototype
    /// discarded whitespace-only gaps.
    @Test("Runs of whitespace survive as one token")
    func whitespace() {
        let result = tokens("a   b")
        #expect(result == ["a", "   ", "b"])
    }
}

@Suite("Maximum matching")
struct MaxMatchTests {
    @Test("Known words are found", arguments: [
        ("中国人民", ["中国", "人民"]),
        ("北京举行阅兵式", ["北京", "举行", "阅兵式"]),
        // 我们 is in the lexicon, so it stays whole -- my first expectation
        // here split it, which the segmenter was right to reject.
        ("我们学习中文", ["我们", "学习", "中文"]),
    ])
    func knownWords(text: String, expected: [String]) {
        #expect(tokens(text) == expected)
    }

    /// Characters absent from the lexicon fall back to one token each, which
    /// is wrong but never misleading — the right failure mode.
    @Test("Unknown characters fall back to one token each")
    func unknown() {
        #expect(tokens("龘靐齉") == ["龘", "靐", "齉"])
    }

    /// Backward matching is more accurate for Chinese because modifiers
    /// precede heads. `这个苹果` is the standard illustration: forward
    /// matching from the left is tempted by a different split.
    @Test("Backward matching segments a modifier-head phrase")
    func backward() {
        #expect(tokens("这个苹果") == ["这个", "苹果"])
    }

    @Test("An empty lexicon degrades to characters rather than failing")
    func emptyLexicon() {
        let plain = TextSegmenter(words: MaxMatchSegmenter(lexicon: Lexicon(words: [])))
        let result = plain.segment("中国人民").blocks.flatMap(\.tokens).map(\.text)
        #expect(result == ["中", "国", "人", "民"])
    }

    /// Whatever it does, the pieces must concatenate back to the input.
    @Test("Splitting is lossless")
    func lossless() {
        let segmenter = MaxMatchSegmenter(lexicon: testLexicon)
        for run in ["中国人民解放军", "龘靐齉", "中国龘人民", ""] {
            #expect(segmenter.split(run).joined() == run)
        }
    }
}

@Suite("Dictionary repair")
struct DictionaryRepairTests {
    /// The measured inconsistency: NLTokenizer keeps `这个` but splits
    /// `一 | 个 | 人`, even though `一个人` is a headword.
    @Test("Over-split compounds are rejoined")
    func rejoins() {
        let split = TextSegmenter(words: CharacterSegmenter()).segment("我一个人吃了三个")
        let repaired = DictionaryRepairPass(lexicon: testLexicon).repair(split)
        #expect(repaired.blocks.flatMap(\.tokens).map(\.text)
            == ["我", "一个人", "吃", "了", "三个"])
    }

    /// Only ever merging is what makes it safe to run unconditionally: it
    /// cannot turn a correct segmentation into a wrong one.
    @Test("Correct segmentation is left alone")
    func neverSplits() {
        let document = segmenter().segment("中国人民")
        let repaired = DictionaryRepairPass(lexicon: testLexicon).repair(document)
        #expect(repaired.blocks.flatMap(\.tokens).map(\.text) == ["中国", "人民"])
    }

    /// Punctuation and spaces are real boundaries. Merging across one would
    /// produce a token whose text does not match its own source range.
    @Test("Merging never crosses punctuation or whitespace", arguments: [
        "一，个人", "一 个人",
    ])
    func respectsBoundaries(text: String) {
        let split = TextSegmenter(words: CharacterSegmenter()).segment(text)
        let repaired = DictionaryRepairPass(lexicon: testLexicon).repair(split)
        #expect(!repaired.blocks.flatMap(\.tokens).contains { $0.text == "一个人" })
        #expect(repaired.isWellFormed)
        #expect(repaired.reassembled() == text)
    }

    /// Repair reassigns ids and spans, so the invariant has to survive it.
    @Test("Repair preserves the tiling invariant")
    func preservesInvariant() {
        let texts = ["我一个人吃了三个", "中国人民解放军在北京举行了阅兵式", "a一个人b"]
        let pass = DictionaryRepairPass(lexicon: testLexicon)
        for text in texts {
            let repaired = pass.repair(TextSegmenter(words: CharacterSegmenter()).segment(text))
            #expect(repaired.isWellFormed, "tiling broken for \(text)")
            #expect(repaired.reassembled() == text)
        }
    }

    @Test("An empty lexicon changes nothing")
    func emptyLexicon() {
        let document = segmenter().segment("我一个人")
        let repaired = DictionaryRepairPass(lexicon: Lexicon(words: [])).repair(document)
        #expect(repaired == document)
    }
}

@Suite("Segmentation regressions")
struct SegmentationRegressionTests {
    /// The lexicon carries a weight that penalises length, and the first
    /// version of the segmenter ignored it entirely — greedy longest-match
    /// takes the long headword whatever its weight, so the documented
    /// rationale was false and the weights were dead code.
    ///
    /// `日本人` is a real headword, but `日本` + `人` is the better reading
    /// here when the shorter words carry more weight between them.
    @Test("A long headword does not automatically beat two short ones")
    func weightsAreConsulted() {
        // Deliberately weighted so the pair outscores the single long word.
        let lexicon = Lexicon([
            Lexeme(word: "日本人", characterLength: 3, weight: 0.4),
            Lexeme(word: "日本", characterLength: 2, weight: 0.9),
            Lexeme(word: "人", characterLength: 1, weight: 0.9),
        ])
        let result = MaxMatchSegmenter(lexicon: lexicon).split("日本人")
        #expect(result == ["日本", "人"], "greedy longest-match would give [日本人]")
    }

    /// ...and the converse, so the fix did not simply invert the bias.
    @Test("A long headword still wins when it is the better reading")
    func longWordStillWins() {
        let lexicon = Lexicon([
            Lexeme(word: "日本人", characterLength: 3, weight: 2.0),
            Lexeme(word: "日本", characterLength: 2, weight: 0.5),
            Lexeme(word: "人", characterLength: 1, weight: 0.5),
        ])
        #expect(MaxMatchSegmenter(lexicon: lexicon).split("日本人") == ["日本人"])
    }

    /// The repair pass had the same bug: it took the longest merge rather
    /// than the best-weighted one.
    @Test("Repair prefers the best-weighted merge, not the longest")
    func repairConsultsWeights() {
        let lexicon = Lexicon([
            Lexeme(word: "日本人", characterLength: 3, weight: 0.2),
            Lexeme(word: "日本", characterLength: 2, weight: 1.5),
        ])
        let split = TextSegmenter(words: CharacterSegmenter()).segment("日本人")
        let repaired = DictionaryRepairPass(lexicon: lexicon).repair(split)
        #expect(repaired.blocks.flatMap(\.tokens).map(\.text) == ["日本", "人"])
    }

    /// `trailingSpace` is public and documented, and was always false.
    @Test("Tokens report whether whitespace follows them")
    func trailingSpaceIsSet() {
        let document = segmenterForRegressions().segment("中国 人民")
        let tokens = document.blocks.flatMap(\.tokens)

        guard let first = tokens.first(where: { $0.text == "中国" }),
              let last = tokens.first(where: { $0.text == "人民" })
        else { Issue.record("expected both words"); return }

        #expect(first.trailingSpace, "中国 is followed by a space")
        #expect(!last.trailingSpace, "人民 ends the text")
        // The whitespace token itself is not followed by more whitespace.
        #expect(tokens.first { $0.kind == .whitespace }?.trailingSpace == false)
    }

    /// Lookup was two linear scans, which on a book queried once per frame
    /// during audio alignment is needless work.
    @Test("Offset lookup is correct across a long document", .timeLimit(.minutes(1)))
    func offsetLookupIsCorrect() {
        let text = (0 ..< 400).map { _ in "中国人民学习。\n" }.joined()
        let document = segmenterForRegressions().segment(text)

        // Every offset must land in a token that actually contains it.
        for offset in stride(from: 0, to: text.utf16.count, by: 7) {
            guard let token = document.token(atOffset: offset) else {
                Issue.record("no token at \(offset)"); return
            }
            #expect(token.range.contains(offset), "offset \(offset) outside its token")
        }
        // Past the end clamps rather than losing the position.
        #expect(document.token(atOffset: text.utf16.count + 99) != nil)
        #expect(document.token(atOffset: -1) == nil)
    }
}

private func segmenterForRegressions() -> TextSegmenter<MaxMatchSegmenter> {
    TextSegmenter(words: MaxMatchSegmenter(lexicon: Lexicon(words: [
        "中国", "人民", "学习",
    ])))
}
