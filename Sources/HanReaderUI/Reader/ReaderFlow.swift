// HanReader — MIT licensed. See LICENSE.

import Foundation
import HanReaderCore

/// What the flow layout needs to know about one token, beyond its measured
/// size.
///
/// Attached to each token view as a `LayoutValue` rather than handed to the
/// layout as a parallel array. SwiftUI guarantees the association between a
/// subview and its layout values; it guarantees nothing about an array index
/// still lining up with `subviews` after a diff, and a one-off misalignment
/// would show as spacing applied to the wrong token — subtle enough to ship.
nonisolated struct TokenFlowValue: Hashable, Sendable {
    /// Space to insert before this token when it does not start a line.
    let leadingSpace: Double
    /// Whether this token must stay with the one before it: closing
    /// punctuation may not begin a line.
    let gluesToPrevious: Bool
    /// Whether a line may end with this token: an opening bracket may not.
    let canEndLine: Bool
}

/// The parts of reader layout that are pure arithmetic over tokens.
///
/// Kept out of the `Layout` conformance so that it can be tested directly.
/// Everything here is a function of `(tokens, style)` and nothing else — no
/// fonts, no views, no measurement — which means the spacing rules below are
/// assertable rather than something to be eyeballed in a screenshot.
nonisolated enum ReaderFlow {
    /// Computes the layout values for a paragraph's tokens.
    static func flowValues(for tokens: [Token], style: ReaderStyle) -> [TokenFlowValue] {
        tokens.indices.map { index in
            TokenFlowValue(
                leadingSpace: leadingSpace(beforeTokenAt: index, in: tokens, style: style),
                gluesToPrevious: LineBreakRules.glueToPrevious(tokens[index].text),
                canEndLine: LineBreakRules.canEndLine(tokens[index].text),
            )
        }
    }

    /// The gap drawn before a token.
    ///
    /// Word spacing exists to show the reader where one word ends and the next
    /// begins, so it appears only between two things that are *words*. Three
    /// consequences, each of which the prototype got wrong or could not
    /// express with its single `NoPrecedingSpaceKey` boolean:
    ///
    /// - **Nothing around punctuation.** A mark already separates what it
    ///   divides; adding a gap as well leaves `你好 ， 世界`.
    /// - **Nothing around real whitespace.** A space in the source is its own
    ///   token and carries a space glyph's advance. Adding word spacing on
    ///   both sides of it triples the gap, which is what makes a mixed
    ///   Chinese-and-English sentence look broken.
    /// - **Nothing at all in continuous mode**, because `style.wordSpacing` is
    ///   zero there. The mode is a property of the style, not a branch here.
    static func leadingSpace(
        beforeTokenAt index: Int,
        in tokens: [Token],
        style: ReaderStyle,
    )
        -> Double
    {
        // The first token of a paragraph has nothing to be separated from.
        // `layOutLines` also ignores the leading space of whichever token
        // starts a line, so this is belt and braces -- but a value that is
        // only correct because its consumer discards it is a trap for the next
        // consumer.
        guard index > 0, index < tokens.count else { return 0 }
        guard isWordLike(tokens[index]), isWordLike(tokens[index - 1]) else { return 0 }
        return style.wordSpacing
    }

    /// Whether a token is a word rather than a separator.
    ///
    /// Note that `.other` counts. A token the classifier could not place —
    /// an emoji, a Cyrillic word in a Russian gloss quoted inline — reads as
    /// a word to the person looking at it, and spacing it like one is the
    /// better failure mode.
    private static func isWordLike(_ token: Token) -> Bool {
        switch token.kind {
        case .han, .latin, .number, .other: true
        case .punctuation, .whitespace: false
        }
    }

    /// Height of one line: the glyphs, plus the ruby band held above them.
    ///
    /// Nominal rather than measured. The real height of a line comes from the
    /// tokens on it, and `TokenFlowLayout` uses that; this is for the places
    /// that need a line's worth of space without any text to measure — a
    /// loading placeholder, a blank line, the detail panel's own sizing.
    ///
    /// There is deliberately **no** paragraph-height estimator here. One was
    /// written and removed: a `minHeight` can only be applied to a paragraph
    /// that has materialised, and a materialised paragraph has already been
    /// measured exactly in the same layout pass, so the estimate changed
    /// nothing. `LazyVStack` offers no hook for the rows that have not
    /// materialised, which is the case the estimate was supposed to smooth.
    static func lineHeight(_ style: ReaderStyle) -> Double {
        style.rubyReservation + style.fontSize * ReaderStyle.Ratio.hanLineHeight
    }
}
