// HanReader — MIT licensed. See LICENSE.

import HanReaderCore
import SwiftUI
import Testing
@testable import HanReaderUI

/// Renders the reading surface and asserts the shape of the result.
///
/// Deliberately **not** a pixel snapshot. CJK glyph metrics in PingFang shift
/// across OS releases, so a committed reference image goes red for a reason
/// nobody caused, and a suite that cries wolf gets skipped within a month.
///
/// What is compared instead is two renders *from the same build*: reveal a
/// reading and check that the box it sits in is the same size as before. That
/// is fidelity invariant 1 — "revealing a word never reflows or vertically
/// shifts the body text" — tested through the real `Layout`, the real
/// `RubyStack` and the real font, with nothing committed that an OS update can
/// invalidate.
///
/// The tests are at the **token** level first and the paragraph level second,
/// and that order was learned the hard way. A paragraph-level test alone is
/// close to useless here: its width is pinned by the column, so only its
/// height can move, and its height only moves if the line *count* changes.
/// Reintroducing the prototype's bug — rendering the ruby only when revealed —
/// left the fixture paragraph wrapping into the same number of lines, so the
/// test passed on code that was visibly broken. The token-level tests see the
/// width directly, and the paragraph-level one sweeps widths so that a change
/// in token width has to show up as a different line count at *some* width.
@Suite("Reader layout, rendered")
struct ReaderLayoutRenderTests {
    private let document = ReaderFixtures.prose

    // MARK: - Helpers

    private func token(_ text: String) -> Token {
        Token(
            id: TokenID(block: 0, index: 0),
            text: text,
            range: 0 ..< text.utf16.count,
            kind: .han,
        )
    }

    private func size(
        of token: Token,
        reading: TokenReading?,
        emphasis: TokenEmphasis,
        style: ReaderStyle,
    )
        -> CGSize?
    {
        let view = TokenView(
            token: token,
            reading: reading,
            emphasis: emphasis,
            style: style,
            onTap: { _ in },
        )
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        guard let image = renderer.cgImage else { return nil }
        return CGSize(width: image.width, height: image.height)
    }

    private func paragraphHeight(
        _ block: TextBlock,
        style: ReaderStyle,
        width: Double,
        reveal: RevealSet,
    )
        -> Double?
    {
        let view = ParagraphView(
            block: block,
            style: style,
            readings: ReaderFixtures.readingsByWord,
            selection: nil,
            reveal: reveal,
            onTap: { _ in },
        )
        let renderer = ImageRenderer(content: view.frame(width: width))
        renderer.scale = 1
        guard let image = renderer.cgImage else { return nil }
        return Double(image.height)
    }

    /// The longest paragraph in the fixture, so that it wraps at every width
    /// swept below. A short paragraph fits on one line at the wider end of
    /// the sweep, where a reflow then has nowhere to show.
    private var paragraph: TextBlock {
        document.blocks
            .filter { $0.kind == .paragraph }
            .max { $0.tokens.count < $1.tokens.count } ?? document.blocks[0]
    }

    private func allWords(of block: TextBlock) -> RevealSet {
        RevealSet(
            mode: .allOccurrences,
            lemmas: Set(block.tokens.filter(\.isLookupCandidate).map(\.text)),
        )
    }

    /// A reading far wider than the single glyph it annotates, so that
    /// reserving its width is visible in the token's own size. Without a case
    /// like this every assertion about reservation is vacuous: most readings
    /// are narrower than the characters they sit above.
    private let overwideReading = TokenReading(display: "zhōngguórénmín", source: .dictionary)

    // MARK: - The token's box never changes size

    @Test(
        "A token is the same size whether or not its reading is shown",
        arguments: [WordSpacing.separated, .continuous],
    )
    func revealDoesNotResizeAToken(spacing: WordSpacing) throws {
        let style = ReaderStyle(fontSize: 22, spacing: spacing)
        let subject = token("我")
        let plain = try #require(
            size(of: subject, reading: overwideReading, emphasis: .plain, style: style),
        )
        let revealed = try #require(
            size(of: subject, reading: overwideReading, emphasis: .revealed, style: style),
        )
        let selected = try #require(
            size(of: subject, reading: overwideReading, emphasis: .selected, style: style),
        )
        #expect(plain == revealed)
        #expect(plain == selected)
    }

    /// Separated mode grows the word to fit its reading; continuous mode does
    /// not, and lets the reading overhang instead. Both behaviours are
    /// required, and this is the only test that can tell them apart.
    @Test("Only separated spacing widens a word to fit its reading")
    func reservationDependsOnSpacing() throws {
        let subject = token("我")

        let separated = ReaderStyle(fontSize: 22, spacing: .separated)
        let bare = try #require(
            size(of: subject, reading: nil, emphasis: .plain, style: separated),
        )
        let wide = try #require(
            size(of: subject, reading: overwideReading, emphasis: .plain, style: separated),
        )
        #expect(wide.width > bare.width)

        let continuous = ReaderStyle(fontSize: 22, spacing: .continuous)
        let bareContinuous = try #require(
            size(of: subject, reading: nil, emphasis: .plain, style: continuous),
        )
        let wideContinuous = try #require(
            size(of: subject, reading: overwideReading, emphasis: .plain, style: continuous),
        )
        #expect(wideContinuous.width == bareContinuous.width)
    }

    /// A word with no reading still occupies a full line's height, so lines do
    /// not differ in height according to dictionary coverage — which matters
    /// because 77% of BKRS entries carry no reading at all.
    @Test("A token with no reading is as tall as one with a reading")
    func heightIsIndependentOfCoverage() throws {
        let style = ReaderStyle(fontSize: 22, spacing: .separated)
        let subject = token("我")
        let bare = try #require(
            size(of: subject, reading: nil, emphasis: .plain, style: style),
        )
        let annotated = try #require(
            size(of: subject, reading: overwideReading, emphasis: .revealed, style: style),
        )
        #expect(bare.height == annotated.height)
        #expect(bare.height > style.fontSize)
    }

    // MARK: - The paragraph never reflows

    /// Swept across widths rather than checked at one. A token whose width
    /// changed on reveal would wrap differently at *some* width even if it
    /// happened to wrap identically at the one width a single-width test
    /// picked — which is exactly how an earlier version of this test passed
    /// while the prototype's bug was reintroduced.
    @Test(
        "Revealing every reading changes no line break at any width",
        arguments: [14.0, 22.0, 36.0],
    )
    func revealDoesNotReflowAParagraph(fontSize: Double) throws {
        let style = ReaderStyle(fontSize: fontSize, spacing: .separated)
        let block = paragraph
        let revealed = allWords(of: block)

        for width in stride(from: 180.0, through: 620.0, by: 11) {
            let bare = try #require(
                paragraphHeight(
                    block,
                    style: style,
                    width: width,
                    reveal: RevealSet(mode: .allOccurrences),
                ),
            )
            let shown = try #require(
                paragraphHeight(block, style: style, width: width, reveal: revealed),
            )
            #expect(bare == shown, "reflowed at width \(width), size \(fontSize)")
        }
    }

    /// Continuous mode exists to look like written Chinese. If it were not
    /// denser than separated mode, it would not be doing anything — which is
    /// what the prototype's misnamed `SegmentationMode` suggested to anyone
    /// reading the call site.
    @Test("Continuous spacing fits more text in the same width")
    func continuousIsDenser() throws {
        let block = paragraph
        let separated = ReaderStyle(fontSize: 22, spacing: .separated)
        let continuous = separated.withSpacing(.continuous)
        var sawSaving = false

        // Swept, because dropping the word gaps does not always save a whole
        // line: at some widths both modes wrap identically. The property is
        // that continuous is never taller and is sometimes shorter -- which is
        // what "denser" actually means, and is stronger than picking the one
        // width where it happens to differ.
        for width in stride(from: 180.0, through: 620.0, by: 11) {
            let tall = try #require(
                paragraphHeight(
                    block,
                    style: separated,
                    width: width,
                    reveal: RevealSet(mode: .allOccurrences),
                ),
            )
            let short = try #require(
                paragraphHeight(
                    block,
                    style: continuous,
                    width: width,
                    reveal: RevealSet(mode: .allOccurrences),
                ),
            )
            #expect(short <= tall, "continuous was taller at width \(width)")
            sawSaving = sawSaving || short < tall
        }
        #expect(sawSaving, "continuous spacing never saved a line at any width")
    }

    @Test("A paragraph that wraps is taller than one line")
    func wrappedParagraphIsMultipleLines() throws {
        let style = ReaderStyle(fontSize: 22, spacing: .separated)
        let height = try #require(
            paragraphHeight(
                paragraph,
                style: style,
                width: 200,
                reveal: RevealSet(mode: .allOccurrences),
            ),
        )
        #expect(height > ReaderFlow.lineHeight(style) + style.lineGap)
    }

    @Test("A blank line occupies the height the style gives it")
    func blankLineHeight() throws {
        let style = ReaderStyle(fontSize: 22)
        let blank = try #require(document.blocks.first { $0.kind == .blankLine })
        let height = try #require(
            paragraphHeight(
                blank,
                style: style,
                width: 300,
                reveal: RevealSet(mode: .allOccurrences),
            ),
        )
        #expect(abs(height - style.blankLineHeight.rounded()) <= 1)
    }
}
