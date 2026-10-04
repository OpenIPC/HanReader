// HanReader — MIT licensed. See LICENSE.

import HanReaderCore
import Testing

@testable import HanReaderDictionaryImport

@Suite("Dictionary import module")
struct DictionaryImportModuleTests {
    @Test("Links Core and Persistence")
    func linksDependencies() {
        #expect(HanReaderDictionaryImport.linkedVersions.count == 2)
        #expect(HanReaderDictionaryImport.linkedVersions.allSatisfy { $0 == HanReaderCore.version })
    }
}
