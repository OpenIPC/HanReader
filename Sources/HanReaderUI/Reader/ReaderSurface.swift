// HanReader — MIT licensed. See LICENSE.

import HanReaderCore
import SwiftUI

/// The scrolling reading surface.
///
/// Everything it needs arrives as a plain value, and nothing it does requires
/// a model — which is why it is built and previewed against fixtures before
/// any state exists. Getting the hardest part of the app working with no
/// mutable state at all is what forces the layout to take values, rather than
/// discovering later that it reads an observable and relayouts unpredictably.
///
/// Virtualisation is `LazyVStack` over blocks. Three to eight paragraphs
/// materialise at a time — roughly 150 to 400 token views — against the
/// prototype's "every token in the document, in one `Layout`, with no cache".
struct ReaderSurface: View {
    let document: SegmentedDocument
    let style: ReaderStyle
    let readings: [String: TokenReading]
    let selection: TokenID?
    let reveal: RevealSet
    let onTap: (TokenID) -> Void

    /// The block at the top of the viewport.
    ///
    /// A block index, never a pixel offset. The prototype stored a scroll
    /// offset, which is meaningless after a font-size change, a window resize
    /// or a move between a Mac and a phone — and it never restored it anyway.
    @Binding var topBlock: Int?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: style.paragraphGap) {
                ForEach(document.blocks) { block in
                    ParagraphView(
                        block: block,
                        style: style,
                        readings: readings,
                        selection: selection,
                        reveal: reveal,
                        onTap: onTap,
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .id(block.id)
                }
            }
            .scrollTargetLayout()
            .frame(maxWidth: style.maximumColumnWidth, alignment: .leading)
            .padding(.horizontal, ReaderMetrics.readingColumnPadding)
            // Room above the first line for a revealed reading on it.
            //
            // Nothing is reserved below for the detail panel: whoever
            // presents it does so with `.safeAreaInset`, which already insets
            // this scroll view by the panel's real height. Adding the panel's
            // nominal height here as well reserved it twice, and the literal
            // did not scale with Dynamic Type the way the panel itself does.
            .padding(.top, style.rubyReservation)
            .padding(.bottom, style.paragraphGap)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .scrollPosition(id: $topBlock, anchor: .top)
    }
}
