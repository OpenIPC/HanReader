// HanReader — MIT licensed. See LICENSE.

import HanReaderCore
import Testing

@testable import HanReaderUI

@Suite("UI module graph")
struct UIModuleTests {
    @Test("Links every engine module")
    func dependencies() {
        #expect(HanReaderUI.moduleDependencies == [
            "HanReaderCore",
            "HanReaderTokenization",
            "HanReaderPersistence",
            "HanReaderDictionaryImport",
            "HanReaderPlayback",
            "HanReaderPlatform",
        ])
    }
}
