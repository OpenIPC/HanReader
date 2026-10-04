// HanReader — MIT licensed. See LICENSE.

import Foundation
import HanReaderCore
import HanReaderPersistence
import Testing
@testable import HanReaderUI

/// Split from `ReaderModelTests` so neither suite outgrows what is
/// comfortable to read. Tapping a word is where the prototype's worst
/// interaction bug lived, so it earns a suite of its own.
@MainActor
@Suite("Reader selection")
struct ReaderSelectionTests {
    private let source = "我爱你。\n\n中国。\n书。\n我爱你。\n"

    private func makeModel() async throws -> ModelTestSupport.Fixture {
        try await ModelTestSupport.makeFixture(source: source)
    }

    // MARK: - Selection and reveal

    @Test("Tapping a word selects it and reveals it")
    func tapSelects() async throws {
        let fixture = try await makeModel()
        let model = fixture.model
        await model.load()
        let token = try #require(firstToken("我", in: model))

        model.tap(token.id)
        #expect(model.selection == token.id)
        #expect(model.reveal.reveals(token))
    }

    @Test("Tapping the same word again clears it")
    func tapTwiceClears() async throws {
        let fixture = try await makeModel()
        let model = fixture.model
        await model.load()
        let token = try #require(firstToken("我", in: model))

        model.tap(token.id)
        model.tap(token.id)
        #expect(model.selection == nil)
        #expect(!model.reveal.reveals(token))
        #expect(model.detail == .empty)
    }

    /// The prototype's most jarring interaction bug. Its single
    /// `Set<String>` meant any instance's tap toggled every instance, so
    /// tapping a second 我 un-revealed the first and appeared to do nothing.
    @Test("Tapping another instance of a revealed word selects it")
    func tapSecondInstance() async throws {
        let fixture = try await makeModel()
        let model = fixture.model
        await model.load()
        let document = try #require(model.document)
        let instances = document.blocks.flatMap(\.tokens).filter { $0.text == "我" }
        #expect(instances.count == 2, "the fixture should contain 我 twice")

        model.tap(instances[0].id)
        model.tap(instances[1].id)

        #expect(model.selection == instances[1].id)
        #expect(model.reveal.reveals(instances[0]), "the first instance was un-revealed")
        #expect(model.reveal.reveals(instances[1]))
    }

    @Test("Punctuation is not selectable")
    func punctuationIsInert() async throws {
        let fixture = try await makeModel()
        let model = fixture.model
        await model.load()
        let token = try #require(firstToken("。", in: model))

        model.tap(token.id)
        #expect(model.selection == nil)
    }

    @Test("Reveal state survives reopening the text")
    func revealIsPersisted() async throws {
        let fixture = try await makeModel()
        let model = fixture.model
        let services = fixture.services
        let id = fixture.id
        await model.load()
        let token = try #require(firstToken("我", in: model))
        model.tap(token.id)

        // Give the detached write a chance to land before reading it back.
        try await Task.sleep(for: .milliseconds(100))
        #expect(try await services.library.revealedWords(in: id).contains("我"))
    }

    /// Per-instance reveals are session-only: `revealedWord` is keyed on
    /// `(text, word)`, so writing a lemma for a single-instance tap would
    /// light up every occurrence on reopening — the opposite of the mode.
    @Test("A single-instance reveal is not written as a whole-word reveal")
    func instanceRevealIsNotPersisted() async throws {
        let services = try AppServices.inMemory(
            lookup: ModelTestSupport.SmallDictionary(),
            lexicon: Lexicon(words: ["中国"]),
        )
        let outcome = try await services.library.importText(title: "S", content: source)
        guard case let .imported(id) = outcome else {
            Issue.record("import failed")
            return
        }
        let settings = Settings(store: InMemorySettingsStore())
        settings.revealMode = .thisInstance
        let model = ReaderModel(textID: id, services: services, settings: settings)
        await model.load()

        let token = try #require(firstToken("我", in: model))
        model.tap(token.id)
        await model.close()

        #expect(model.reveal.reveals(token), "the tap should still reveal it on screen")
        #expect(try await services.library.revealedWords(in: id).isEmpty)
    }

    /// Two taps on the same word are a reveal and a hide. Fired as
    /// independent tasks they can land in either order, leaving the store
    /// saying "revealed" after the tap that hid it.
    @Test("Reveal and hide are stored in the order they happened")
    func revealWritesAreOrdered() async throws {
        let fixture = try await makeModel()
        let model = fixture.model
        let services = fixture.services
        let id = fixture.id
        await model.load()
        let token = try #require(firstToken("我", in: model))

        model.tap(token.id)
        model.tap(token.id)
        await model.close()

        #expect(try await services.library.revealedWords(in: id).isEmpty)
    }

    // MARK: - Detail

    /// The prototype showed "Not found in dictionary" while the dictionary
    /// was still being read, which is not a slow answer but a wrong one.
    @Test("A tapped word reports loading before it reports an answer")
    func detailStartsLoading() async throws {
        let fixture = try await makeModel()
        let model = fixture.model
        await model.load()
        let token = try #require(firstToken("我", in: model))

        model.tap(token.id)
        #expect(model.detail == .loading("我"))
    }

    @Test("A known word loads its entries")
    func detailLoads() async throws {
        let fixture = try await makeModel()
        let model = fixture.model
        await model.load()
        let token = try #require(firstToken("中国", in: model))

        model.tap(token.id)
        try await waitForDetail(model)

        guard case let .loaded(detail) = model.detail else {
            Issue.record("expected a loaded detail, got \(model.detail)")
            return
        }
        #expect(detail.word == "中国")
        #expect(detail.reading?.display == "Zhōngguó")
        #expect(detail.entries.count == 1)
    }

    /// A word with no entry is still a loaded detail, not a state of its
    /// own. As a separate state it had nowhere to carry the reading, so
    /// tapping a word the dictionary does not define removed the pinyin
    /// that was already visible above it — which for a word composed from
    /// its characters is exactly the annotation worth keeping.
    @Test("A word the dictionary does not have is reported as undefined")
    func detailNotFound() async throws {
        let fixture = try await makeModel()
        let model = fixture.model
        await model.load()
        let token = try #require(firstToken("书", in: model))

        model.tap(token.id)
        try await waitForDetail(model)

        guard case let .loaded(detail) = model.detail else {
            Issue.record("expected a loaded detail, got \(model.detail)")
            return
        }
        #expect(detail.word == "书")
        #expect(!detail.isDefined)
        #expect(detail.entries.isEmpty)
    }

    /// The reading survives even though the entry does not.
    @Test("An undefined word keeps the reading composed for it")
    func undefinedWordKeepsItsReading() async throws {
        let fixture = try await ModelTestSupport.makeFixture(
            source: "北京。\n",
            lookup: ModelTestSupport.CharacterOnlyDictionary(),
        )
        let model = fixture.model
        await model.load()
        let token = try #require(firstToken("北京", in: model)
            ?? firstToken("北", in: model))

        model.tap(token.id)
        try await waitForDetail(model)

        guard case let .loaded(detail) = model.detail else {
            Issue.record("expected a loaded detail, got \(model.detail)")
            return
        }
        #expect(!detail.isDefined)
        #expect(detail.reading?.source == .composed)
        #expect(detail.reading?.display.isEmpty == false)
    }

    /// A lookup in flight when the selection is cleared must not land. It
    /// would pass its own cancellation check and write `.loaded`, leaving a
    /// definition on screen for a word that is no longer selected.
    @Test("Clearing the selection cancels the lookup behind it")
    func clearingCancelsTheLookup() async throws {
        let fixture = try await makeModel()
        let model = fixture.model
        await model.load()
        let token = try #require(firstToken("中国", in: model))

        model.tap(token.id)
        #expect(model.detail == .loading("中国"))
        model.clearSelection()
        #expect(model.detail == .empty)

        // Long enough for any in-flight lookup to have finished and written.
        try await Task.sleep(for: .milliseconds(100))
        #expect(model.detail == .empty)
        #expect(model.selection == nil)
    }

    @Test("Tapping the selected word again leaves nothing behind")
    func deselectLeavesNoDetail() async throws {
        let fixture = try await makeModel()
        let model = fixture.model
        await model.load()
        let token = try #require(firstToken("中国", in: model))

        model.tap(token.id)
        model.tap(token.id)
        try await Task.sleep(for: .milliseconds(100))
        #expect(model.detail == .empty)
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
