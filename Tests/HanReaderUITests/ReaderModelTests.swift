// HanReader — MIT licensed. See LICENSE.

import Foundation
import HanReaderCore
import HanReaderPersistence
import Testing
@testable import HanReaderUI

@MainActor
@Suite("Reader model")
struct ReaderModelTests {
    private let source = "我爱你。\n\n中国。\n书。\n我爱你。\n"

    private func makeModel() async throws -> ModelTestSupport.Fixture {
        try await ModelTestSupport.makeFixture(source: source)
    }

    // MARK: - Loading

    @Test("Opening a text segments it and reports ready")
    func loads() async throws {
        let fixture = try await makeModel()
        let model = fixture.model
        await model.load()

        #expect(model.phase == .ready)
        let document = try #require(model.document)
        #expect(document.isWellFormed)
        #expect(document.reassembled() == source)
    }

    @Test("A text that is no longer there fails rather than hanging")
    func missingText() async throws {
        let services = try AppServices.inMemory()
        let model = ReaderModel(
            textID: TextID(rawValue: 999),
            services: services,
            settings: Settings(store: InMemorySettingsStore()),
        )
        await model.load()

        guard case .failed = model.phase else {
            Issue.record("expected a failure, got \(model.phase)")
            return
        }
    }

    @Test("Opening a text records that it was opened")
    func marksOpened() async throws {
        let fixture = try await makeModel()
        let model = fixture.model
        let services = fixture.services
        await model.load()

        let items = try await services.library.items()
        #expect(items.first?.lastOpenedAt != nil)
    }

    // MARK: - Readings

    @Test("Readings are fetched for the words on screen")
    func readings() async throws {
        let fixture = try await makeModel()
        let model = fixture.model
        await model.load()

        #expect(model.readings["我"]?.display == "wǒ")
        #expect(model.readings["中国"]?.display == "Zhōngguó")
        // A word the dictionary does not have is simply absent.
        #expect(model.readings["。"] == nil)
    }

    /// The window is asymmetric because reading goes downwards, and bounded
    /// because the prototype fetched an entry for every distinct token in the
    /// document before showing anything.
    @Test("The reading window is bounded and looks further ahead than behind")
    func windowShape() {
        let document = ReaderFixtures.prose
        let window = ReaderModel.window(around: 10, in: document)
        #expect(window.count <= ReaderModel.readingWindowBefore
            + ReaderModel.readingWindowAfter + 1)

        let atStart = ReaderModel.window(around: 0, in: document)
        #expect(atStart.lowerBound == 0)
    }

    @Test("The window never runs off either end")
    func windowIsClamped() {
        let document = ReaderFixtures.prose
        for block in [-5, 0, 1, document.blocks.count - 1, document.blocks.count + 50] {
            let window = ReaderModel.window(around: block, in: document)
            #expect(window.lowerBound >= 0)
            #expect(window.upperBound <= document.blocks.count)
            #expect(window.lowerBound <= window.upperBound)
        }
    }

    @Test("An empty document has an empty window")
    func emptyDocumentWindow() {
        let empty = SegmentedDocument(blocks: [], sourceLength: 0)
        #expect(ReaderModel.window(around: 0, in: empty).isEmpty)
    }

    /// Assigning `topBlock` while restoring a saved position used to fire its
    /// `didSet`, which schedules a reading refresh — and `load` then awaited
    /// one directly as well. Both saw an empty map, so the whole window was
    /// looked up twice every time a position was restored.
    ///
    /// Counted with the service cache off, which is what makes the duplicate
    /// visible: with it on, the second pass is served from memory and the
    /// waste is invisible from here.
    @Test("Restoring a position does not fetch the window twice")
    func windowIsFetchedOnce() async throws {
        let counter = ModelTestSupport.CountingDictionary()
        let services = try AppServices.inMemory(
            lookup: counter,
            lexicon: Lexicon(words: ["中国"]),
            dictionaryCapacity: 0,
        )
        let outcome = try await services.library.importText(title: "S", content: source)
        guard case let .imported(id) = outcome else {
            Issue.record("import failed")
            return
        }
        // A stored position, which is what made `topBlock` change during load.
        try await services.library.save(ReadingPosition(
            textID: id,
            blockIndex: 2,
            tokenIndex: 0,
            characterOffset: 8,
        ))

        let model = ReaderModel(
            textID: id,
            services: services,
            settings: Settings(store: InMemorySettingsStore()),
        )
        await model.load()
        // Let any stray scheduled refresh run before counting.
        try await Task.sleep(for: .milliseconds(50))

        #expect(counter.count(of: "我") <= 1, "我 was looked up \(counter.count(of: "我")) times")
        #expect(counter.count(of: "中国") <= 1)
        await model.close()
    }

    // MARK: - Helpers

    private func firstToken(_ text: String, in model: ReaderModel) -> Token? {
        model.document?.blocks.flatMap(\.tokens).first { $0.text == text }
    }

    /// Waits for the detail task to settle.
    ///
    /// Polls rather than sleeping a fixed time, so the test is neither flaky
    /// on a loaded machine nor slow on an idle one.
    private func waitForDetail(_ model: ReaderModel) async throws {
        for _ in 0 ..< 100 {
            if case .loading = model.detail {
                try await Task.sleep(for: .milliseconds(10))
                continue
            }
            return
        }
        Issue.record("the detail never settled")
    }
}
