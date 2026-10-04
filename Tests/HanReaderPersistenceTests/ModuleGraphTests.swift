// HanReader — MIT licensed. See LICENSE.

import HanReaderCore
import Testing

@testable import HanReaderPersistence

@Suite("Persistence module graph")
struct PersistenceModuleTests {
    @Test("Depends on Core only")
    func dependencies() {
        #expect(HanReaderPersistence.moduleDependencies == ["HanReaderCore"])
    }
}
