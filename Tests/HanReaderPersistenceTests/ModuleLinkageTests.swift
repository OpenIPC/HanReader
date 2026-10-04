// HanReader — MIT licensed. See LICENSE.

import HanReaderCore
import Testing
@testable import HanReaderPersistence

@Suite("Persistence module")
struct PersistenceModuleTests {
    @Test("Links HanReaderCore")
    func linksCore() {
        #expect(HanReaderPersistence.coreVersion == HanReaderCore.version)
    }
}
