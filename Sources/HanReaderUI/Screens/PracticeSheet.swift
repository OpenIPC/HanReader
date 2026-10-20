// HanReader — MIT licensed. See LICENSE.

import HanReaderCore
import HanReaderPlayback
import SwiftUI

/// Holds a `PracticeModel` for as long as the sheet is open.
///
/// Document-scoped the same way `ReaderScreen` holds its own model: built by
/// `.task`, closed on the way out. Separate from the reader because practice
/// *hides* the text, which is the opposite of what the reader exists to do —
/// and because the transport is shared, so leaving has to hand it back.
struct PracticeSheet: View {
    let textID: TextID
    let title: String
    let services: AppServices
    let playback: PlaybackModel
    let style: ReaderStyle

    @State private var model: PracticeModel?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        NavigationStack {
            Group {
                if let model {
                    PracticeScreen(model: model, playback: playback, style: style)
                } else {
                    Color.clear
                }
            }
            .navigationTitle(Text(verbatim: title))
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        // A sheet sizes itself to its content, and the content here is a
        // short invitation before it is a practice screen — so without a
        // floor it opens narrow and then has to grow under the reader.
        //
        // Only where there is room for one. A phone is narrower than this
        // floor, and a sheet that will not fit its window clips its own
        // controls off the side.
        .frame(
            minWidth: sizeClass == .compact ? nil : 620,
            idealWidth: sizeClass == .compact ? nil : 760,
            minHeight: sizeClass == .compact ? nil : 520,
            idealHeight: sizeClass == .compact ? nil : 660,
        )
        .task {
            let next = PracticeModel(textID: textID, services: services, playback: playback)
            model = next
            await next.load()
        }
        .onDisappear {
            // The transport belongs to the window, not to this sheet, so it
            // is handed back rather than left stopped on a phrase the
            // reader can no longer see.
            let model = model
            Task {
                await model?.close()
                playback.clearSegment()
                playback.pause()
            }
        }
    }
}
