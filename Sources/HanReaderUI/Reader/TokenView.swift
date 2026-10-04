// HanReader — MIT licensed. See LICENSE.

import HanReaderCore
import SwiftUI

/// One token on the reading surface.
///
/// A separate view per token, which is a deliberate trade and worth naming.
/// What it buys: hit testing, animation and an accessibility element per word,
/// all for free and all correct. What it costs: text cannot be drag-selected
/// across separate `Text` views, so in-text selection is replaced by
/// paragraph- and sentence-level copy commands. That cost is the documented
/// trigger for moving the renderer to TextKit 2, and it is the only one —
/// see Docs/ARCHITECTURE.md.
struct TokenView: View {
    let token: Token
    let reading: TokenReading?
    let emphasis: TokenEmphasis
    let style: ReaderStyle
    let onTap: (TokenID) -> Void

    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled

    private var highlight: TokenHighlight {
        TokenHighlight.resolve(
            emphasis,
            increasedContrast: contrast == .increased,
            differentiateWithoutColor: differentiateWithoutColor,
        )
    }

    var body: some View {
        RubyStack(style: style) {
            rubyLayer
            baseLayer
        }
        // Only words are tappable. Making punctuation and whitespace inert is
        // not a cosmetic choice: the prototype routed every token through the
        // same tap handler, so tapping a comma selected it and then reported
        // "not found in dictionary".
        .contentShape(.rect)
        .onTapGesture {
            if token.isLookupCandidate {
                onTap(token.id)
            }
        }
        .allowsHitTesting(token.isLookupCandidate)
        .accessibilityElement()
        .accessibilityLabel(accessibleLabel)
        .accessibilityValue(reading?.display ?? "")
        .accessibilityAddTraits(token.isLookupCandidate ? .isButton : [])
        .accessibilityHidden(!token.isLookupCandidate)
        // Not optional, and not a refinement of the trait above.
        //
        // `onTapGesture` is a gesture, and a gesture is invisible to the
        // accessibility system — it publishes no press action. Adding
        // `.isButton` without this announces a control that cannot be
        // operated: the element says "button", VoiceOver offers to activate
        // it, and nothing happens. Verified on the running app, where a
        // token's only action was `AXScrollToVisible`.
        //
        // Tapping a word is this app's entire interaction, so without a
        // press action a VoiceOver reader can hear the text and never look
        // anything up.
        .accessibilityAction {
            if token.isLookupCandidate {
                onTap(token.id)
            }
        }
    }

    // MARK: - Layers

    private var baseLayer: some View {
        Text(verbatim: token.text)
            .font(ReaderFont.base(style))
            .foregroundStyle(token.isLookupCandidate ? ReaderColor.text : ReaderColor.inertText)
            .background {
                RoundedRectangle(cornerRadius: ReaderMetrics.tokenCornerRadius, style: .continuous)
                    .fill(ReaderColor.highlightFill(highlight))
            }
            .background {
                RoundedRectangle(cornerRadius: ReaderMetrics.tokenCornerRadius, style: .continuous)
                    .strokeBorder(ReaderColor.highlight, lineWidth: highlight.borderWidth)
            }
            .overlay(alignment: .bottom) {
                DottedBaseline()
                    .stroke(
                        ReaderColor.highlight,
                        style: StrokeStyle(lineWidth: 1, dash: [2, 2]),
                    )
                    .frame(height: 1)
                    .opacity(highlight.underlined ? 1 : 0)
            }
            .animation(ReaderAnimation.reveal(reduceMotion: reduceMotion), value: emphasis)
    }

    /// The ruby annotation.
    ///
    /// Always in the hierarchy, with its visibility carried by opacity. That
    /// is what makes the width reservation in `RubyStack` honest: the view
    /// being measured is the one that will be drawn, at the size it will be
    /// drawn, whether or not it is currently visible. Rendering it
    /// conditionally and padding by a guess is how the prototype arrived at
    /// `Text(" ").opacity(0)`, which reserved the width of a space and
    /// therefore moved the text anyway.
    @ViewBuilder
    private var rubyLayer: some View {
        if let reading {
            Text(verbatim: reading.display)
                .font(ReaderFont.ruby(style))
                .foregroundStyle(
                    reading.source.isApproximate
                        ? ReaderColor.approximateRuby
                        : ReaderColor.ruby,
                )
                .lineLimit(1)
                .fixedSize()
                .opacity(emphasis == .plain ? 0 : 1)
                .animation(ReaderAnimation.reveal(reduceMotion: reduceMotion), value: emphasis)
        } else {
            // No reading to show, but the band above the glyphs is still
            // reserved by RubyStack, so the line height does not depend on
            // which words happen to be in the dictionary.
            Color.clear.frame(width: 0, height: 0)
        }
    }

    // MARK: - Accessibility

    /// The token's text, annotated with its language.
    ///
    /// Mandatory, not a refinement. Without the language identifier VoiceOver
    /// reads Chinese with whatever voice the interface language selected, so
    /// an English-locale reader hears 中国 spelled out as two unknown
    /// characters, and a Russian-locale reader hears it transliterated.
    private var accessibleLabel: Text {
        guard token.kind == .han else { return Text(verbatim: token.text) }
        var annotated = AttributedString(token.text)
        annotated.languageIdentifier = "zh-Hans"
        return Text(annotated)
    }

    /// Whether the reader should hear this word spoken on tap.
    ///
    /// False under VoiceOver, which announces the token itself the moment it
    /// takes focus. Speaking as well means the word is said twice, over
    /// itself, in two different voices.
    var speaksOnTap: Bool {
        !voiceOverEnabled
    }
}

/// A single horizontal line, for a dashed underline.
///
/// `Rectangle().stroke(dash:)` would dash all four edges, which at a
/// one-point height draws a dotted box rather than a dotted underline.
nonisolated struct DottedBaseline: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        return path
    }
}
