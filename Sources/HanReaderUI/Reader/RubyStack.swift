// HanReader — MIT licensed. See LICENSE.

import SwiftUI

/// Stacks a ruby annotation above the glyphs it annotates.
///
/// A `Layout` rather than a `VStack` for one reason: a `VStack`'s width is
/// always the widest of its children, and in continuous mode the reading must
/// be allowed to overhang its neighbours instead of widening the word. Both
/// behaviours are needed, they differ only in whether the ruby contributes
/// width, and expressing that as a parameter keeps one view hierarchy instead
/// of an `if` that changes view identity every time the reader toggles
/// spacing.
///
/// Subviews are positional: the ruby first, the base text second. That is the
/// convention SwiftUI's own two-subview layouts use, and `RubyStack` is
/// constructed in exactly one place (`TokenView`), so the coupling is local
/// and visible.
///
/// ### Why the vertical reservation is unconditional
///
/// `sizeThatFits` adds `style.rubyReservation` whether or not a reading is
/// being shown, and takes it from the style rather than from the ruby
/// subview's measured height. Two bugs are avoided at once:
///
/// - Revealing a word cannot move the text, because the box it sits in never
///   changes size. This is fidelity invariant 1, and it holds by construction.
/// - Every line reserves the *same* height, so lines do not differ in height
///   according to which readings happen to fall on them — which is what
///   measuring the ruby would cause, for a reason invisible to the reader.
nonisolated struct RubyStack: Layout {
    let style: ReaderStyle

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache _: inout Void,
    )
        -> CGSize
    {
        let base = baseSize(of: subviews, proposal: proposal)
        let width = style.reservesRubyWidth
            ? max(base.width, rubySize(of: subviews).width)
            : base.width
        return CGSize(width: width, height: style.rubyReservation + base.height)
    }

    /// ### Why the glyphs sit at the leading edge, not the centre
    ///
    /// Centring a word inside a box widened by its reading looks right until
    /// the word starts a line: the box is flush with the margin, the glyphs
    /// are inset by half the overhang, and the page's left margin comes out
    /// ragged — by a few points on every line whose first word happens to
    /// have a wide reading. It is clearly visible in a rendered page and it
    /// is the kind of defect a reader notices without being able to name.
    ///
    /// Pinning the glyphs to the leading edge straightens the margin and
    /// moves the slack to where most of it was going anyway: the gap before
    /// the next word. The reading is still centred over its word — which is
    /// what makes a short reading over a long word look attached to it —
    /// clamped so that it never starts before the leading edge, because that
    /// clamp is what keeps the margin straight. In continuous mode nothing is
    /// clamped: there the reading is meant to overhang on both sides.
    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache _: inout Void,
    ) {
        guard let base = subviews.last else { return }
        let measured = baseSize(of: subviews, proposal: proposal)
        base.place(
            at: CGPoint(x: bounds.minX, y: bounds.maxY),
            anchor: .bottomLeading,
            proposal: ProposedViewSize(measured),
        )
        guard subviews.count > 1 else { return }

        let rubyWidth = rubySize(of: subviews).width
        let centred = bounds.minX + (measured.width - rubyWidth) / 2
        // Pinned to the top of the reserved band, so the gap between the
        // reading and the glyphs is whatever the reservation did not use.
        subviews[0].place(
            at: CGPoint(
                x: style.reservesRubyWidth ? max(bounds.minX, centred) : centred,
                y: bounds.minY,
            ),
            anchor: .topLeading,
            proposal: .unspecified,
        )
    }

    private func baseSize(of subviews: Subviews, proposal: ProposedViewSize) -> CGSize {
        // Measured against the incoming proposal rather than `.unspecified`:
        // a single long Latin token in a narrow column has to be allowed to
        // wrap internally instead of reporting a width wider than the page.
        subviews.last?.sizeThatFits(
            ProposedViewSize(width: proposal.width, height: nil),
        ) ?? .zero
    }

    private func rubySize(of subviews: Subviews) -> CGSize {
        // Deliberately unproposed. A reading is one short run of Latin and
        // must never wrap; if it does not fit, overhanging is correct and
        // breaking it across two lines above one word is not.
        subviews.count > 1 ? subviews[0].sizeThatFits(.unspecified) : .zero
    }
}
