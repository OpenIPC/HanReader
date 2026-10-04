// HanReader — MIT licensed. See LICENSE.

import HanReaderCore
import Testing

@testable import HanReaderTokenization

@Suite("Tokenization module")
struct TokenizationModuleTests {
    @Test("Links HanReaderCore")
    func linksCore() {
        #expect(HanReaderTokenization.coreVersion == HanReaderCore.version)
    }
}
