// HanReader — MIT licensed. See LICENSE.

import SwiftUI

@main
struct HanReaderMacApp: App {
    var body: some Scene {
        WindowGroup {
            HanReaderRootScene()
        }
        // A reduced minimum relative to the prototype's 1100x700: the reader
        // has to survive a half-screen window on a laptop, and the detail panel
        // plus sidebar fit comfortably at this size.
        .defaultSize(width: 1100, height: 720)
        .windowResizability(.contentMinSize)
    }
}
