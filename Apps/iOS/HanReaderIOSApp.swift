// HanReader — MIT licensed. See LICENSE.

import HanReaderUI
import SwiftUI

@main
struct HanReaderIOSApp: App {
    /// Owned by the `App`, so the databases, caches and synthesizer are
    /// created once per process. Held in a view instead, a `WindowGroup`
    /// would build one set per window — which is exactly the prototype bug
    /// this project exists to avoid.
    @State private var launch = HanReaderLaunch()

    var body: some Scene {
        WindowGroup {
            HanReaderRootScene(launch: launch)
        }
    }
}
