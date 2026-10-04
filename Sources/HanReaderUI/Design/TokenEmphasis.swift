// HanReader — MIT licensed. See LICENSE.

import Foundation

/// How prominent a token is on the reading surface.
///
/// Three states, not two, and the distinction is the fix for the prototype's
/// most jarring interaction bug. The prototype held a single
/// `revealedWords: Set<String>`, so tapping 的 once put pinyin over all 467
/// instances in the document and tapping *any* of them removed it from all of
/// them. Selection and reveal are genuinely different things: exactly one
/// token is selected and drives the detail panel, while reveal is a property
/// of a word and may apply to many tokens at once.
nonisolated enum TokenEmphasis: Sendable, Hashable, CaseIterable {
    /// Not revealed and not selected.
    case plain
    /// Revealed — its reading is shown — but not the token being inspected.
    case revealed
    /// The one token driving the detail panel.
    case selected
}

/// The resolved appearance of a token's highlight.
///
/// A value rather than a view modifier so that the accessibility rules below
/// can be unit-tested. "Reveal state is still distinguishable with
/// `differentiateWithoutColor` on" is a claim about a computation, and it
/// should fail in a test rather than be rediscovered by a reader who cannot
/// see which words they have already looked up.
nonisolated struct TokenHighlight: Hashable, Sendable {
    /// Opacity of the accent-coloured fill behind the token, 0 for none.
    let fillOpacity: Double
    /// Width of the border around the fill, 0 for none.
    let borderWidth: Double
    /// Whether to draw a dotted underline under the base glyphs.
    ///
    /// The shape channel that carries reveal state when colour cannot.
    let underlined: Bool

    /// Resolves a token's highlight from its emphasis and the reader's
    /// accessibility settings.
    ///
    /// The two visual channels are deliberately independent:
    ///
    /// - **Fill opacity** separates the selected token from the merely
    ///   revealed ones. Both use the accent colour; what differs is weight,
    ///   plus a border on the selected one. The prototype drew every revealed
    ///   word identically, which is precisely why tapping a second instance of
    ///   an already-revealed word felt like a bug — nothing on screen changed.
    /// - **A dotted underline** carries reveal state when
    ///   `differentiateWithoutColor` is on. A tinted fill was the *only*
    ///   signal the prototype had, and a tint is invisible to a reader who
    ///   has asked the system not to rely on colour.
    ///
    /// ### The numbers, and why they are not theme-dependent
    ///
    /// Measured as WCAG contrast ratios between the composited fill and the
    /// background, for the system accent over white and over the macOS dark
    /// window background:
    ///
    /// | fill | on light | on dark |
    /// |---|---|---|
    /// | 0.08 — what shipped | 1.11 | 1.08 |
    /// | 0.14 — revealed | 1.20 | 1.16 |
    /// | 0.30 — selected | 1.49 | 1.43 |
    ///
    /// The shipped 0.08 was too faint to read as a marker at all, which is
    /// the defect. It is *not* a dark-mode defect: the two columns differ by
    /// about 0.03, so one pair of values serves both themes and a
    /// `colorScheme` parameter would be ceremony around a rounding error.
    ///
    /// Revealed stays deliberately quiet. The reading printed above the word
    /// is the primary signal that it is revealed; the fill only has to make
    /// the set scannable, and a page where a reader has revealed two hundred
    /// words should not turn into a wall of colour. Selection is the state
    /// that must be unmistakable, and it also carries a border.
    static func resolve(
        _ emphasis: TokenEmphasis,
        increasedContrast: Bool = false,
        differentiateWithoutColor: Bool = false,
    )
        -> Self
    {
        let fill: Double = switch emphasis {
        case .plain: 0
        case .revealed: increasedContrast ? 0.24 : 0.14
        case .selected: increasedContrast ? 0.44 : 0.30
        }
        return Self(
            fillOpacity: fill,
            borderWidth: emphasis == .selected ? 1 : 0,
            underlined: differentiateWithoutColor && emphasis != .plain,
        )
    }
}
