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
/// The `launch` it is handed is owned by the `App`, so it is created once per
/// process rather than once per window — see `HanReaderLaunch`.
struct HanReaderRootScene: View {
    let launch: HanReaderLaunch

    var body: some View {
        HanReaderRootView(launch: launch)
    }
}
