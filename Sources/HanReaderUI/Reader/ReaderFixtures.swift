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
        "我": TokenReading(display: "wǒ", source: .dictionary),
        "爱": TokenReading(display: "ài", source: .dictionary),
        "你": TokenReading(display: "nǐ", source: .dictionary),
        "我们": TokenReading(display: "wǒmen", source: .dictionary),
        "是": TokenReading(display: "shì", source: .dictionary),
        "一家人": TokenReading(display: "yījiārén", source: .dictionary),
        "中国": TokenReading(display: "Zhōngguó", source: .dictionary),
        "人民": TokenReading(display: "rénmín", source: .dictionary),
        "解放军": TokenReading(display: "jiěfàngjūn", source: .dictionary),
        "在": TokenReading(display: "zài", source: .dictionary),
        "北京": TokenReading(display: "Běijīng", source: .dictionary),
        "举行": TokenReading(display: "jǔxíng", source: .dictionary),
        "了": TokenReading(display: "le", source: .dictionary),
        "阅兵式": TokenReading(display: "yuèbīngshì", source: .composed),
        "他": TokenReading(display: "tā", source: .dictionary),
        "不好意思": TokenReading(display: "bùhǎoyìsi", source: .dictionary),
        "地": TokenReading(display: "de", source: .dictionary),
        "笑": TokenReading(display: "xiào", source: .dictionary),
        "说": TokenReading(display: "shuō", source: .dictionary),
        "这": TokenReading(display: "zhè", source: .dictionary),
        "什么": TokenReading(display: "shénme", source: .dictionary),
        "意思": TokenReading(display: "yìsi", source: .dictionary),
        "年": TokenReading(display: "nián", source: .dictionary),
        "发布": TokenReading(display: "fābù", source: .dictionary),
        "三个": TokenReading(display: "sān gè", source: .dictionary),
        "照片": TokenReading(display: "zhàopiàn", source: .dictionary),
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

    /// Every token whose text appears in `lemmas`, as a reveal set.
    static func reveal(of lemmas: Set<String>) -> RevealSet {
        RevealSet(mode: .allOccurrences, lemmas: lemmas)
    }
}

// MARK: - Fixture host

/// The reading surface over the built-in fixtures.
///
/// Scaffolding, and deliberately shaped like what replaces it: the selection
/// and reveal state live here rather than in the views, the style is resolved
/// once and passed down as a value, and every input the surface takes is
/// already the input the real model will supply.
struct FixtureReader: View {
    @State private var fontSize = 22.0
    @State private var spacing = WordSpacing.separated
    @State private var selection: TokenID?
    @State private var topBlock: Int?

    /// Dynamic Type as a number.
    ///
    /// `@ScaledMetric` is the only way to read the user's text-size setting as
    /// a ratio — `DynamicTypeSize` is an ordered enum with no numeric value,
    /// and hard-coding a table of multipliers would drift from whatever the
    /// system actually does. Scaling a round number and dividing gives the
    /// real factor.
    @ScaledMetric(relativeTo: .body) private var textScaleProbe = 100.0

    /// Present and `.regular` on macOS, so this needs no platform branch.
    @Environment(\.horizontalSizeClass) private var sizeClass

    private var style: ReaderStyle {
        ReaderStyle(
            fontSize: fontSize,
            spacing: spacing,
            textScale: textScaleProbe / 100,
            // Without this the 18pt compact floor exists only in its own
            // tests. On an iPhone, 14pt scaled down by Dynamic Type's 0.9
            // gives a 12.6pt glyph, and a tap target to match -- which is the
            // one place the 44pt guarantee can be bought back, since a word's
            // target is its text and cannot be padded without overlapping the
            // word beside it.
            minimumFontSize: sizeClass == .compact
                ? ReaderStyle.compactFontSizeFloor
                : ReaderStyle.fontSizeRange.lowerBound,
        )
    }

    private var document: SegmentedDocument {
        ReaderFixtures.prose
    }

    /// Which words show their reading.
    ///
    /// Every occurrence of a revealed word, which is the prototype's default
    /// behaviour and so what fidelity requires — but held as a set of *words*
    /// with selection tracked separately. That separation is what makes
    /// tapping a second instance of an already-revealed word select it
    /// instead of appearing to do nothing.
    @State private var reveal = RevealSet(mode: .allOccurrences)

    var body: some View {
        ReaderSurface(
            document: document,
            style: style,
            readings: ReaderFixtures.readingsByWord,
            selection: selection,
            reveal: reveal,
            onTap: select,
            topBlock: $topBlock,
        )
        .safeAreaInset(edge: .bottom, spacing: 0) {
            FixtureDetailPanel(token: selection.flatMap { document[$0] }, style: style)
        }
        .toolbar { controls }
        .navigationTitle(Text(verbatim: "HanReader"))
    }

    @ToolbarContentBuilder
    private var controls: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Picker(selection: $spacing) {
                Text("Separated words").tag(WordSpacing.separated)
                Text("Continuous text").tag(WordSpacing.continuous)
            } label: {
                Text("Word spacing")
            }
            .pickerStyle(.segmented)
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                fontSize = min(fontSize + 2, ReaderStyle.fontSizeRange.upperBound)
            } label: {
                Label("Larger text", systemImage: "textformat.size.larger")
            }
            // The "=" key, not "+". On most layouts `+` is the shifted `=`,
            // so binding it means the advertised ⌘+ fires only as ⌘⇧+ while
            // ⌘= -- which is what people actually press, and what every other
            // Mac app accepts -- does nothing at all.
            .keyboardShortcut("=", modifiers: .command)
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                fontSize = max(fontSize - 2, ReaderStyle.fontSizeRange.lowerBound)
            } label: {
                Label("Smaller text", systemImage: "textformat.size.smaller")
            }
            .keyboardShortcut("-", modifiers: .command)
        }
    }

    /// Selects a token, and reveals every occurrence of its word.
    ///
    /// Tapping the *same* token again clears the selection and hides the word
    /// again. Tapping a *different* instance of a word that is already
    /// revealed moves the selection and leaves the reveal in place — the fix
    /// for the prototype's single `Set<String>`, where any instance's tap
    /// toggled every instance.
    private func select(_ id: TokenID) {
        guard let token = document[id] else { return }
        if selection == id {
            selection = nil
            reveal.hide(token)
        } else {
            selection = id
            reveal.reveal(token)
        }
    }
}

/// A placeholder for the word-detail panel.
///
/// Fixed height from the first version, because that is the property that
/// matters and the one most easily lost later: a panel that grows to fit its
/// content pushes the body text down every time a word with a longer
/// definition is tapped. Definitions arrive once the dictionary is wired up;
/// the geometry is settled now.
struct FixtureDetailPanel: View {
    let token: Token?
    let style: ReaderStyle

    @ScaledMetric private var height = ReaderMetrics.detailPanelHeight
    @ScaledMetric private var headwordWidth = ReaderMetrics.detailHeadwordWidth

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            if let token {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: token.text)
                        .font(ReaderFont.base(style))
                    if let reading = ReaderFixtures.readingsByWord[token.text] {
                        Text(verbatim: reading.display)
                            .font(ReaderFont.ruby(style))
                            .foregroundStyle(ReaderColor.ruby)
                    }
                }
                .frame(width: headwordWidth, alignment: .leading)

                Text("Definitions arrive with the dictionary in the next pull request.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Text("Tap a word to see its reading.")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, ReaderMetrics.readingColumnPadding)
        .padding(.vertical, 12)
        .frame(height: height, alignment: .top)
        .frame(maxWidth: .infinity)
        .background(.bar)
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
            readings: ReaderFixtures.readingsByWord,
            selection: selection,
            reveal: ReaderFixtures.reveal(of: revealed),
            onTap: { selection = selection == $0 ? nil : $0 },
            topBlock: $topBlock,
        )
        .frame(width: 560, height: 420)
    }
}
