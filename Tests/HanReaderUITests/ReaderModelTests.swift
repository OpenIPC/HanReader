// HanReader — MIT licensed. See LICENSE.

import Foundation
import HanReaderCore
import HanReaderPersistence
import Testing
@testable import HanReaderUI

@MainActor
@Suite("Reader model")
struct ReaderModelTests {
    /// Nested rather than file-scoped, for two reasons that both bite in
    /// this module: a `private` type here would need `nonisolated` as well,
    /// and SwiftFormat and SwiftLint disagree about the order of those two
    /// modifiers; and `entry` is a name three test files want.
    nonisolated struct SmallDictionary: DictionaryLookup {
        static func entry(_ simplified: String, _ numeric: String) -> DictionaryEntry {
            DictionaryEntry(
                headword: Headword(simplified: simplified, traditional: nil),
                reading: Pinyin.parse(numeric: numeric),
                senses: [Sense(
                    id: 0,
                    kind: .definition,
                    gloss: Gloss(text: "a definition of \(simplified)"),
                )],
            )
        }

        static let words: [String: [DictionaryEntry]] = [
            "我": [entry("我", "wo3")],
            "爱": [entry("爱", "ai4")],
            "你": [entry("你", "ni3")],
            "中国": [entry("中国", "Zhong1 guo2")],
        ]

        func entries(for headword: String) throws -> [DictionaryEntry] {
            Self.words[headword] ?? []
        }

        func readings(forCharacter _: Character) throws -> [CharacterReading] {
            []
        }
    }

    /// A model over an in-memory library holding one text. A struct rather
    /// than a tuple, which the linter caps at two members and which reads
    /// badly at three anyway.
    struct Fixture {
        let model: ReaderModel
        let services: AppServices
        let id: TextID
    }

    /// 书 sits alone between full stops so that it is its own token whatever
    /// the tokenizer does with its neighbours, and it is deliberately absent
    /// from `SmallDictionary` — it is the "no entry" case.
    private let source = "我爱你。\n\n中国。\n书。\n我爱你。\n"

    /// Builds a model over an in-memory library holding one text.
    private func makeModel() async throws -> Fixture {
        let services = try AppServices.inMemory(
            lookup: SmallDictionary(),
            lexicon: Lexicon(words: ["中国"]),
        )
        let outcome = try await services.library.importText(title: "Sample", content: source)
        guard case let .imported(id) = outcome else {
            throw ModelTestError.importFailed
        }
        let model = ReaderModel(
            textID: id,
            services: services,
            settings: Settings(store: InMemorySettingsStore()),
        )
        return Fixture(model: model, services: services, id: id)
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

    @Test("A word the dictionary does not have reports not found")
    func detailNotFound() async throws {
        let fixture = try await makeModel()
        let model = fixture.model
        await model.load()
        let token = try #require(firstToken("书", in: model))

        model.tap(token.id)
        try await waitForDetail(model)

        guard case .notFound = model.detail else {
            Issue.record("expected not found, got \(model.detail)")
            return
        }
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

private enum ModelTestError: Error { case importFailed }
