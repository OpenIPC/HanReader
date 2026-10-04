// HanReader — MIT licensed. See LICENSE.

import HanReaderCore
import Testing

@testable import HanReaderTokenization

@Suite("Tokenization module graph")
struct TokenizationModuleTests {
    @Test("Depends on Core only")
    func dependencies() {
        #expect(HanReaderTokenization.moduleDependencies == ["HanReaderCore"])
    }
}
