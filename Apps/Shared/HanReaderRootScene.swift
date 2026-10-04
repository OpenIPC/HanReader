// HanReader — MIT licensed. See LICENSE.

import HanReaderUI
import SwiftUI

/// The scene body shared by both application targets.
///
/// Each platform's `@main` is a thin wrapper around this: it adds only the
/// scene modifiers that genuinely differ (window sizing and resizability on
/// macOS, scene-phase audio handling on iOS) and otherwise defers here. Keeping
/// the body in one place is what makes "two app targets" a packaging detail
/// rather than two codebases.
///
/// - Note: This is scaffolding. The reader arrives in milestone M5.
struct HanReaderRootScene: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "text.book.closed")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("HanReader")
                .font(.largeTitle.weight(.light))
            Text(verbatim: "汉语阅读器")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("The reader arrives in milestone M5.")
                .font(.footnote)
                .foregroundStyle(.tertiary)
            Text(verbatim: "HanReaderUI \(HanReaderUI.linkedVersions.count) modules linked")
                .font(.caption.monospaced())
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

#Preview {
    HanReaderRootScene()
}
