// HanReader — MIT licensed. See LICENSE.

import SwiftUI
import Testing
@testable import HanReaderUI

/// `Layout`'s own methods cannot be called from a test — `LayoutSubviews` is
/// not constructible — so what is asserted here is everything around them:
/// how a proposal becomes a breaking width, what the cache considers a change,
/// and what a token that receives no layout value falls back to.
///
/// The arithmetic of line breaking itself lives in `HanReaderCore.layOutLines`
/// and is tested there against a deterministic measurer; the geometry of a
/// rendered paragraph is tested in `ReaderLayoutRenderTests`.
@Suite("Token flow layout")
struct TokenFlowLayoutTests {
    // MARK: - Proposals

    @Test("An unspecified proposal means one line, not zero width")
    func unspecifiedProposalIsInfinite() {
        // "How big would you like to be" has an answer for a paragraph, and it
        // is a single line. Treating it as zero would report the tallest
        // possible shape -- one token per line -- as the ideal size.
        #expect(TokenFlowLayout.availableWidth(.unspecified) == .infinity)
        #expect(TokenFlowLayout.availableWidth(.init(width: nil, height: 100)) == .infinity)
        #expect(TokenFlowLayout.availableWidth(.infinity) == .infinity)
    }

    @Test("A finite proposal is the breaking width")
    func finiteProposalPassesThrough() {
        #expect(TokenFlowLayout.availableWidth(.init(width: 300, height: nil)) == 300)
        #expect(TokenFlowLayout.availableWidth(.init(width: 42.5, height: 99)) == 42.5)
    }

    @Test("A zero proposal is passed through as the narrowest shape")
    func zeroProposalIsNarrowest() {
        // SwiftUI probes the minimum size this way, and one token per line is
        // the honest answer.
        #expect(TokenFlowLayout.availableWidth(.zero) == 0)
    }

    // MARK: - Cache invalidation

    @Test("The cache distinguishes width, style and token count")
    func cacheKeyCoversItsInputs() {
        let style = ReaderStyle(fontSize: 22, spacing: .separated)
        let base = TokenFlowLayout.Key(width: 300, style: style, subviewCount: 10)

        #expect(base == TokenFlowLayout.Key(width: 300, style: style, subviewCount: 10))
        #expect(base != TokenFlowLayout.Key(width: 301, style: style, subviewCount: 10))
        #expect(base != TokenFlowLayout.Key(width: 300, style: style, subviewCount: 11))
        #expect(base != TokenFlowLayout.Key(
            width: 300,
            style: ReaderStyle(fontSize: 23, spacing: .separated),
            subviewCount: 10,
        ))
        // Word spacing is part of the style, so toggling it must invalidate.
        #expect(base != TokenFlowLayout.Key(
            width: 300,
            style: style.withSpacing(.continuous),
            subviewCount: 10,
        ))
    }

    /// Changing the subview count has to invalidate, because that is the only
    /// signal in the key that the *content* changed. `updateCache` covers the
    /// case where the count stayed the same, by dropping the key outright.
    @Test("A fresh cache is invalid until it is filled")
    func freshCacheIsInvalid() {
        let cache = TokenFlowLayout.Cache()
        #expect(cache.key == nil)
        #expect(cache.lines.isEmpty)
        #expect(cache.sizes.isEmpty)
    }

    // MARK: - Failure mode

    /// A token that somehow arrives without a layout value must be
    /// unconstrained rather than glued. The two failure modes are not
    /// symmetric: an unconstrained token lays out slightly wrong, while a
    /// token wrongly glued to its predecessor can force an unbreakable run and
    /// overflow the column.
    @Test("A token with no layout value is unconstrained")
    func defaultFlowValueIsPermissive() {
        let fallback = TokenFlowKey.defaultValue
        #expect(fallback.leadingSpace == 0)
        #expect(!fallback.gluesToPrevious)
        #expect(fallback.canEndLine)
    }
}
