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
/// The view itself lives in `HanReaderUI` so that both targets, the previews
/// and the test suite see exactly the same code. This file holds no reader
/// logic and is not expected to grow any.
struct HanReaderRootScene: View {
    var body: some View {
        HanReaderRootView()
    }
}

#Preview {
    HanReaderRootScene()
}
