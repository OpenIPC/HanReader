// HanReader — MIT licensed. See LICENSE.

import HanReaderCore
import Testing

@testable import HanReaderUI

@Suite("UI module")
struct UIModuleTests {
    @Test("Links all six engine modules")
    func linksEveryEngineModule() {
        let linked = HanReaderUI.linkedVersions
        #expect(linked.count == 6)
        #expect(linked.allSatisfy { $0 == HanReaderCore.version })
    }
}
