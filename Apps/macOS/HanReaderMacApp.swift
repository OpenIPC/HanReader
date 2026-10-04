// HanReader — MIT licensed. See LICENSE.

import HanReaderUI
import SwiftUI

@main
struct HanReaderMacApp: App {
    /// Owned by the `App`, so the databases, caches and synthesizer are
    /// created once per process. Held in a view instead, a `WindowGroup`
    /// would build one set per window — which is exactly the prototype bug
    /// this project exists to avoid.
    @State private var launch = HanReaderLaunch()

    var body: some Scene {
        WindowGroup {
            HanReaderRootScene(launch: launch)
        }
        // A reduced minimum relative to the prototype's 1100x700: the reader
        // has to survive a half-screen window on a laptop, and the detail panel
        // plus sidebar fit comfortably at this size.
        .defaultSize(width: 1100, height: 720)
        .windowResizability(.contentMinSize)
    }
}
