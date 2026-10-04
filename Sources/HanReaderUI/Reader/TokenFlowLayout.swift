// HanReader — MIT licensed. See LICENSE.

import HanReaderCore
import SwiftUI

/// Carries a token's spacing and line-breaking flags to the flow layout.
nonisolated struct TokenFlowKey: LayoutValueKey {
    static let defaultValue = TokenFlowValue(
        leadingSpace: 0,
        gluesToPrevious: false,
        canEndLine: true,
    )
}

/// Lays one paragraph's tokens out into lines.
///
/// An adapter, and nothing more. Measurement comes from the subviews, the line
/// breaking comes from `HanReaderCore.layOutLines`, and the kinsoku rules come
/// from `LineBreakRules`; what is left here is reading sizes, calling the core
/// function, and placing the results. That split is what makes CJK line
/// breaking testable at all — the alternative is pixel snapshots, which go red
/// on every OS release because PingFang's metrics shift.
///
/// ### The cache is the point
///
/// The prototype called its `computeRows` from both `sizeThatFits` and
/// `placeSubviews` with no cache, so every layout pass measured every `Text`
/// twice and ran line breaking twice. On a document in a single layout with no
/// virtualisation that was the dominant cost. Here the work happens once per
/// `(width, style, subview count)` and both methods read the result.
///
/// The cache key does not include the tokens' own measurements, which deserves
/// stating because it looks like an omission:
///
/// - A paragraph's text is immutable. `SegmentedDocument` is a value, and a
///   block's tokens never change once segmented.
/// - Revealing a reading cannot change a token's size. `RubyStack` reserves
///   the ruby's space unconditionally, and the ruby's *width* comes from the
///   reading, which is known whether or not it is currently visible. Reveal is
///   an opacity change and nothing more.
/// - If the content does change — a different paragraph, a re-segmentation —
///   SwiftUI calls `updateCache`, which drops everything.
///
/// So the only inputs that can move a token are the width and the style, and
/// both are in the key.
nonisolated struct TokenFlowLayout: Layout {
    let style: ReaderStyle

    struct Cache {
        var key: Key?
        var lines: [LineRun] = []
        var size: CGSize = .zero
        var sizes: [CGSize] = []
    }

    struct Key: Hashable {
        let width: Double
        let style: ReaderStyle
        let subviewCount: Int
    }

    func makeCache(subviews _: Subviews) -> Cache {
        Cache()
    }

    func updateCache(_ cache: inout Cache, subviews _: Subviews) {
        // Called when the subviews change, which is the one case the key
        // cannot see. Dropping the key rather than the whole value keeps the
        // allocated arrays around for the re-fill.
        cache.key = nil
    }

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Cache,
    )
        -> CGSize
    {
        resolve(proposal: proposal, subviews: subviews, cache: &cache)
        return cache.size
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Cache,
    ) {
        resolve(proposal: proposal, subviews: subviews, cache: &cache)

        for line in cache.lines {
            for (position, index) in line.range.enumerated() {
                guard index < subviews.count, position < line.xOffsets.count else { continue }
                subviews[index].place(
                    at: CGPoint(
                        x: bounds.minX + line.xOffsets[position],
                        y: bounds.minY + line.y,
                    ),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(cache.sizes[index]),
                )
            }
        }
    }

    // MARK: - Measurement

    private func resolve(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Cache,
    ) {
        let available = Self.availableWidth(proposal)
        let key = Key(width: available, style: style, subviewCount: subviews.count)
        guard cache.key != key else { return }

        // Measured against the available width, not `.unspecified`: a single
        // Latin token longer than the column has to wrap inside itself rather
        // than report a width that forces the paragraph to overflow.
        let sizes = subviews.map {
            $0.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        }
        let items = zip(subviews, sizes).map { subview, size in
            let flow = subview[TokenFlowKey.self]
            return LineItem(
                advance: size.width,
                height: size.height,
                leadingSpace: flow.leadingSpace,
                glueToPrevious: flow.gluesToPrevious,
                canEndLine: flow.canEndLine,
            )
        }
        let lines = layOutLines(items, width: available, lineSpacing: style.lineGap)

        cache.key = key
        cache.sizes = sizes
        cache.lines = lines
        cache.size = CGSize(
            // The proposed width when there is one, so paragraphs align as a
            // block rather than each ending wherever its longest line did.
            width: available.isFinite ? available : lines.map(\.width).max() ?? 0,
            height: lines.totalHeight,
        )
    }

    /// The width to break lines at.
    ///
    /// An unspecified proposal means "how big would you like to be", and the
    /// honest answer for a paragraph is one line — so it becomes an infinite
    /// width, which `layOutLines` never exceeds. A proposal of zero is
    /// SwiftUI probing the minimum size and is passed through unchanged: one
    /// token per line really is the narrowest this can be.
    static func availableWidth(_ proposal: ProposedViewSize) -> Double {
        guard let width = proposal.width, width.isFinite else { return .infinity }
        return width
    }
}
