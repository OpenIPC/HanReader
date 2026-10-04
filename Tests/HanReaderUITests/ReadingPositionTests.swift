// HanReader — MIT licensed. See LICENSE.

import Foundation
import HanReaderCore
import HanReaderPersistence
import Testing
@testable import HanReaderUI

/// Split from `ReaderModelTests` to keep each suite readable — restoring
/// where a reader left off has enough edge cases of its own.
@MainActor
@Suite("Reading position")
struct ReadingPositionTests {
    private let source = "我爱你。\n\n中国。\n书。\n我爱你。\n"

    private func makeModel() async throws -> ReaderModelTests.Fixture {
        let services = try AppServices.inMemory(
            lookup: ReaderModelTests.SmallDictionary(),
            lexicon: Lexicon(words: ["中国"]),
        )
        let outcome = try await services.library.importText(title: "Sample", content: source)
        guard case let .imported(id) = outcome else {
            throw PositionTestError.importFailed
        }
        return ReaderModelTests.Fixture(
            model: ReaderModel(
                textID: id,
                services: services,
                settings: Settings(store: InMemorySettingsStore()),
            ),
            services: services,
            id: id,
        )
    }

    // MARK: - Position

    @Test("The reading position is written and restored")
    func positionRoundTrips() async throws {
        let fixture = try await makeModel()
        let model = fixture.model
        let services = fixture.services
        let id = fixture.id
        await model.load()

        model.topBlock = 3
        await model.flushPosition()

        let stored = try #require(try await services.library.position(of: id))
        #expect(stored.blockIndex == 3)

        let document = try #require(model.document)
        #expect(ReaderModel.restoredBlock(from: stored, in: document) == 3)
    }

    /// The stored character offset is the durable anchor. Block indices are a
    /// property of however the text was segmented last time, so an OS update
    /// changing `NLTokenizer`'s output would silently move every position; a
    /// character offset survives it.
    @Test("A position with a stale block index is recovered from its offset")
    func recoversFromOffset() async throws {
        let fixture = try await makeModel()
        let model = fixture.model
        let id = fixture.id
        await model.load()
        let document = try #require(model.document)
        let target = try #require(document.blocks.indices.last)

        let stale = ReadingPosition(
            textID: id,
            blockIndex: 9999,
            tokenIndex: 0,
            characterOffset: document.blocks[target].range.lowerBound,
        )
        #expect(ReaderModel.restoredBlock(from: stale, in: document) == target)
    }

    @Test("A position past the end of a shortened text clamps rather than failing")
    func clampsPastTheEnd() async throws {
        let fixture = try await makeModel()
        let model = fixture.model
        let id = fixture.id
        await model.load()
        let document = try #require(model.document)

        let beyond = ReadingPosition(
            textID: id,
            blockIndex: 9999,
            tokenIndex: 0,
            characterOffset: document.sourceLength + 10000,
        )
        let restored = ReaderModel.restoredBlock(from: beyond, in: document)
        #expect(restored != nil)
        #expect(document.blocks.indices.contains(restored ?? -1))
    }

    @Test("No stored position means no restore")
    func noStoredPosition() {
        #expect(ReaderModel.restoredBlock(from: nil, in: ReaderFixtures.prose) == nil)
    }

    /// Saving the position must not clear a playhead the audio player stored:
    /// the reader scrolls constantly and has no playhead to supply.
    @Test("Saving the position preserves a stored playhead")
    func positionDoesNotClearAudioTime() async throws {
        let fixture = try await makeModel()
        let model = fixture.model
        let services = fixture.services
        let id = fixture.id
        await model.load()

        try await services.library.save(ReadingPosition(
            textID: id,
            blockIndex: 0,
            tokenIndex: 0,
            characterOffset: 0,
            audioTime: 42,
        ))
        model.topBlock = 2
        await model.flushPosition()

        #expect(try await services.library.position(of: id)?.audioTime == 42)
    }
}

private enum PositionTestError: Error { case importFailed }
