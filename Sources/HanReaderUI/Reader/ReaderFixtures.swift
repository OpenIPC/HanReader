// HanReader — MIT licensed. See LICENSE.

import HanReaderCore
import SwiftUI

/// Sample documents for previews, tests and the UI-test launch argument.
///
/// Real Chinese prose rather than lorem ipsum, and chosen to exercise the
/// cases that break reading surfaces: mixed Latin and digits inside Chinese
/// text, full-width punctuation that may not begin a line, nested quotation
/// marks that may not end one, a deliberate blank line, and a word with no
/// reading at all.
///
/// The readings are a hand-written subset, not a dictionary. These fixtures
/// exist so the reading surface can be built and reviewed before any
/// dictionary, database or model is wired to it — which is also what keeps
/// them cheap enough to live in the shipping target for UI tests to seed.
enum ReaderFixtures {
    /// The words the sample segmenter knows.
    ///
    /// Includes 一家人 and 三个 deliberately: Apple's tokenizer splits both
    /// into single characters even though each is a headword, and they are
    /// what the repair pass exists to merge back together.
    static let words = [
        "我们", "一家人", "中国", "人民", "解放军", "北京", "举行", "阅兵式",
        "不好意思", "什么", "意思", "发布", "三个", "照片",
    ]

    static let lexicon = Lexicon(words: words)

    /// Readings for the sample vocabulary.
    ///
    /// 阅兵式 is marked composed on purpose, so a preview shows both the
    /// looked-up and the character-by-character rendering side by side. That
    /// distinction is invisible in a screenshot otherwise, and it is the one
    /// the reader most needs to be able to see — a composed reading is an
    /// approximation that will be wrong for heteronyms.
    static let readingsByWord: [String: TokenReading] = [
        "我": TokenReading(display: "wǒ", isComposed: false),
        "爱": TokenReading(display: "ài", isComposed: false),
        "你": TokenReading(display: "nǐ", isComposed: false),
        "我们": TokenReading(display: "wǒmen", isComposed: false),
        "是": TokenReading(display: "shì", isComposed: false),
        "一家人": TokenReading(display: "yījiārén", isComposed: false),
        "中国": TokenReading(display: "Zhōngguó", isComposed: false),
        "人民": TokenReading(display: "rénmín", isComposed: false),
        "解放军": TokenReading(display: "jiěfàngjūn", isComposed: false),
        "在": TokenReading(display: "zài", isComposed: false),
        "北京": TokenReading(display: "Běijīng", isComposed: false),
        "举行": TokenReading(display: "jǔxíng", isComposed: false),
        "了": TokenReading(display: "le", isComposed: false),
        "阅兵式": TokenReading(display: "yuèbīngshì", isComposed: true),
        "他": TokenReading(display: "tā", isComposed: false),
        "不好意思": TokenReading(display: "bùhǎoyìsi", isComposed: false),
        "地": TokenReading(display: "de", isComposed: false),
        "笑": TokenReading(display: "xiào", isComposed: false),
        "说": TokenReading(display: "shuō", isComposed: false),
        "这": TokenReading(display: "zhè", isComposed: false),
        "什么": TokenReading(display: "shénme", isComposed: false),
        "意思": TokenReading(display: "yìsi", isComposed: false),
        "年": TokenReading(display: "nián", isComposed: false),
        "发布": TokenReading(display: "fābù", isComposed: false),
        "三个": TokenReading(display: "sān gè", isComposed: false),
        "照片": TokenReading(display: "zhàopiàn", isComposed: false),
    ]

    /// Four paragraphs and a blank line.
    ///
    /// 拍 has no entry in `readingsByWord`, so one token in the last paragraph
    /// renders with no annotation — the case that must still reserve its ruby
    /// band, or lines would differ in height according to dictionary coverage.
    static let proseSource = """
    我爱你。我们是一家人。

    中国人民解放军在北京举行了阅兵式。
    他不好意思地笑了笑，说：“这是什么意思？”
    iPhone 15 在 2026 年发布，我拍了三个照片。
    """

    static let prose = document(proseSource)

    /// A short line, for previews that need to fit in a small canvas.
    static let phrase = document("我爱你。")

    /// Segments text with the deterministic segmenter and the repair pass.
    ///
    /// Deterministic on purpose: a fixture segmented by `NLTokenizer` would
    /// change shape with an OS release, and a preview or UI test that drifts
    /// under the developer is worse than no fixture at all.
    static func document(_ text: String) -> SegmentedDocument {
        let segmented = TextSegmenter(words: MaxMatchSegmenter(lexicon: lexicon)).segment(text)
        return DictionaryRepairPass(lexicon: lexicon).repair(segmented)
    }

    /// Readings keyed by token, as the reader's model would supply them.
    static func readings(for document: SegmentedDocument) -> [TokenID: TokenReading] {
        var result: [TokenID: TokenReading] = [:]
        for block in document.blocks {
            for token in block.tokens {
                if let reading = readingsByWord[token.text] {
                    result[token.id] = reading
                }
            }
        }
        return result
    }

    /// Every token whose text appears in `words`, as a stand-in for a reveal
    /// set covering all occurrences of a lemma.
    static func tokens(matching lemmas: Set<String>, in document: SegmentedDocument)
        -> Set<TokenID>
    {
        var result: Set<TokenID> = []
        for block in document.blocks {
            for token in block.tokens where lemmas.contains(token.text) {
                result.insert(token.id)
            }
        }
        return result
    }
}

// MARK: - Previews

#Preview("Separated, nothing revealed") {
    FixturePreview(style: ReaderStyle(fontSize: 22, spacing: .separated), revealed: [])
}

#Preview("Separated, readings shown") {
    FixturePreview(
        style: ReaderStyle(fontSize: 22, spacing: .separated),
        revealed: ["中国", "人民", "解放军", "阅兵式", "我"],
    )
}

#Preview("Continuous, readings overhang") {
    FixturePreview(
        style: ReaderStyle(fontSize: 22, spacing: .continuous),
        revealed: ["中国", "人民", "解放军", "阅兵式"],
    )
}

#Preview("48pt, the largest reading size") {
    FixturePreview(
        style: ReaderStyle(fontSize: 48, spacing: .separated),
        revealed: ["我们", "一家人"],
    )
}

/// Hosts a fixture document with a selection, for the previews above.
private struct FixturePreview: View {
    let style: ReaderStyle
    let revealed: Set<String>

    @State private var selection: TokenID?
    @State private var topBlock: Int?

    private var document: SegmentedDocument {
        ReaderFixtures.prose
    }

    var body: some View {
        ReaderSurface(
            document: document,
            style: style,
            readings: ReaderFixtures.readings(for: document),
            selection: selection,
            revealed: ReaderFixtures.tokens(matching: revealed, in: document)
                .union(selection.map { [$0] } ?? []),
            onTap: { selection = selection == $0 ? nil : $0 },
            topBlock: $topBlock,
        )
        .frame(width: 560, height: 420)
    }
}
