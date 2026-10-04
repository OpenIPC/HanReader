// HanReader — MIT licensed. See LICENSE.

import HanReaderCore
import Testing

@testable import HanReaderDictionaryImport

@Suite("Dictionary import module graph")
struct DictionaryImportModuleTests {
    @Test("Depends on Core and Persistence")
    func dependencies() {
        #expect(HanReaderDictionaryImport.moduleDependencies == [
            "HanReaderCore",
            "HanReaderPersistence",
        ])
    }
}
