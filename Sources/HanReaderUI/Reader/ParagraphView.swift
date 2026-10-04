// HanReader — MIT licensed. See LICENSE.

import HanReaderCore
import SwiftUI

/// One paragraph of the reading surface.
///
/// The paragraph, not the document, is the unit of laziness. The prototype put
/// every token in the whole text into a single `Layout` and detected paragraph
/// breaks by sniffing for "a zero-height subview wider than 90% of the
/// container" — which misfires on any single token that happens to be wider
/// than 90% of the container, and which meant a book-length text laid out
/// thousands of subviews on every pass. Paragraph structure is modelled here
/// instead, and `ReaderSurface` materialises only the handful on screen.
///
/// Every input is a plain value. No model reference reaches this view, which
/// is the rule that keeps `@Observable` reads out of `Layout.sizeThatFits`,
/// where they would register an observation dependency in a scope nobody
/// controls.
struct ParagraphView: View {
    let block: TextBlock
    let style: ReaderStyle
    /// Readings keyed by word, not by token: bounded by the reader's
    /// vocabulary rather than by the length of the book.
    let readings: [String: TokenReading]
    let selection: TokenID?
    /// Which words are revealed, and in which of the two senses.
    ///
    /// Asked per token rather than handed a prepared set of token ids. For a
    /// book-length text that set would be recomputed over every token in the
    /// document on each tap, and it would grow with the document rather than
    /// with the reader's vocabulary.
    let reveal: RevealSet
    let onTap: (TokenID) -> Void

    /// Tokens paired with their precomputed spacing and break flags.
    private let flow: [FlowToken]

    init(
        block: TextBlock,
        style: ReaderStyle,
        readings: [String: TokenReading],
        selection: TokenID?,
        reveal: RevealSet,
        onTap: @escaping (TokenID) -> Void,
    ) {
        self.block = block
        self.style = style
        self.readings = readings
        self.selection = selection
        self.reveal = reveal
        self.onTap = onTap
        flow = zip(block.tokens, ReaderFlow.flowValues(for: block.tokens, style: style))
            .map(FlowToken.init)
    }

    var body: some View {
        switch block.kind {
        case .blankLine:
            // A deliberate gap in the source, preserved so the reader's layout
            // matches the text as written.
            Color.clear
                .frame(height: style.blankLineHeight)
                .accessibilityHidden(true)
        case .paragraph:
            TokenFlowLayout(style: style) {
                ForEach(flow) { entry in
                    TokenView(
                        token: entry.token,
                        reading: readings[entry.token.text],
                        emphasis: emphasis(of: entry.token),
                        style: style,
                        onTap: onTap,
                    )
                    .layoutValue(key: TokenFlowKey.self, value: entry.flow)
                }
            }
            // One accessibility element per paragraph for *reading*, with the
            // word tokens still reachable inside it for *drilling in*. Neither
            // extreme works: an element per token means swiping four thousand
            // times to read a chapter, and an element per paragraph alone
            // makes individual words unreachable, which is the entire point of
            // the app.
            .accessibilityElement(children: .contain)
            .accessibilityLabel(paragraphLabel)
        }
    }

    private func emphasis(of token: Token) -> TokenEmphasis {
        if token.id == selection {
            return .selected
        }
        return reveal.reveals(token) ? .revealed : .plain
    }

    /// The paragraph as continuous text, annotated with its language.
    private var paragraphLabel: Text {
        var annotated = AttributedString(block.tokens.map(\.text).joined())
        annotated.languageIdentifier = "zh-Hans"
        return Text(annotated)
    }
}

/// A token and the layout values derived from its neighbours.
private struct FlowToken: Identifiable {
    let token: Token
    let flow: TokenFlowValue

    var id: TokenID {
        token.id
    }
}
