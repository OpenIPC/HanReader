// HanReader — MIT licensed. See LICENSE.

import Foundation
import HanReaderCore
import Testing
@testable import HanReaderUI

@MainActor
@Suite("Library model")
struct LibraryModelTests {
    private func makeModel() throws -> LibraryModel {
        try LibraryModel(services: AppServices.inMemory())
    }

    @Test("An empty library loads as empty")
    func emptyLibrary() async throws {
        let model = try makeModel()
        await model.load()
        #expect(model.items.isEmpty)
        #expect(!model.isLoading)
        #expect(model.error == nil)
    }

    @Test("An imported text appears in the list")
    func importAppears() async throws {
        let model = try makeModel()
        let result = await model.importText(title: "First", content: "我爱你。")

        guard case .imported = result else {
            Issue.record("expected an import, got \(String(describing: result))")
            return
        }
        #expect(model.items.count == 1)
        #expect(model.items.first?.title == "First")
    }

    /// Deduplicated on content, never on title. The prototype matched on
    /// title and then silently did nothing, so a second chapter saved as
    /// `chapter.txt` looked like the app had ignored the file.
    @Test("The same content twice is reported, not imported twice")
    func duplicateContent() async throws {
        let model = try makeModel()
        let first = await model.importText(title: "One name", content: "我爱你。")
        let second = await model.importText(title: "A different name", content: "我爱你。")

        guard case let .imported(firstID) = first,
              case let .alreadyPresent(secondID) = second
        else {
            Issue.record("expected imported then alreadyPresent")
            return
        }
        #expect(firstID == secondID)
        #expect(model.items.count == 1)
    }

    @Test("Two texts with the same title are both kept")
    func duplicateTitles() async throws {
        let model = try makeModel()
        _ = await model.importText(title: "chapter", content: "第一章")
        _ = await model.importText(title: "chapter", content: "第二章")
        #expect(model.items.count == 2)
    }

    @Test("Deleting removes a text")
    func delete() async throws {
        let model = try makeModel()
        guard case let .imported(id) = await model.importText(title: "X", content: "我") else {
            Issue.record("import failed")
            return
        }
        await model.delete(id)
        #expect(model.items.isEmpty)
    }

    @Test("The list shows the most recent first")
    func ordering() async throws {
        let model = try makeModel()
        _ = await model.importText(title: "First", content: "一")
        _ = await model.importText(title: "Second", content: "二")
        #expect(model.items.first?.title == "Second")
    }

    /// The preview is stored at import. The prototype selected the full
    /// `content` column for every row to render a 60-character preview, so
    /// opening the sidebar loaded every document in the library.
    @Test("A list item carries a preview without its content")
    func previewIsStored() async throws {
        let model = try makeModel()
        _ = await model.importText(
            title: "Long",
            content: String(repeating: "我爱你。", count: 1000),
        )
        let item = try #require(model.items.first)
        #expect(!item.preview.isEmpty)
        #expect(item.preview.count <= 120)
        #expect(item.characterCount == 4000)
    }

    // MARK: - Reopening

    /// The library recorded which text was open and nothing read it back, so
    /// every launch asked the reader to choose a text with one text in the
    /// list.
    @Test("The text last read is the one to reopen")
    func restoresTheLastRead() async throws {
        let services = try AppServices.inMemory()
        let model = LibraryModel(services: services)
        guard case let .imported(first) = await model.importText(title: "A", content: "一"),
              case let .imported(second) = await model.importText(title: "B", content: "二")
        else {
            Issue.record("import failed")
            return
        }

        // Opened out of import order, so this cannot pass by accident: the
        // newer import is the older read.
        try await services.library.markOpened(second, at: .now.addingTimeInterval(-60))
        try await services.library.markOpened(first)
        await model.load()

        #expect(model.mostRecentlyOpened?.id == first)
    }

    /// A fresh library opens nothing. Falling back to the newest *import*
    /// would open a document the reader has never seen, which is a guess
    /// rather than a restore.
    @Test("A library nothing has been read from reopens nothing")
    func nothingToRestore() async throws {
        let model = try makeModel()
        _ = await model.importText(title: "A", content: "一")
        #expect(model.mostRecentlyOpened == nil)
    }

    @Test("An empty library reopens nothing")
    func emptyRestoresNothing() async throws {
        let model = try makeModel()
        await model.load()
        #expect(model.mostRecentlyOpened == nil)
    }

    // MARK: - Titles

    @Test("A title comes from the file name", arguments: [
        ("chapter-one.txt", "chapter-one"),
        ("红楼梦.TXT", "红楼梦"),
        ("no-extension", "no-extension"),
    ])
    func titleFromFileName(name: String, expected: String) {
        #expect(LibraryModel.title(forFileNamed: name, content: "我爱你。") == expected)
    }

    @Test("A nameless file falls back to its first line")
    func titleFromContent() {
        #expect(LibraryModel.title(forFileNamed: ".txt", content: "第一章\n正文") == "第一章")
        #expect(LibraryModel.title(forFileNamed: "", content: "  第一章  \n") == "第一章")
    }

    @Test("A file with neither a name nor content is still titled")
    func titleFallback() {
        #expect(LibraryModel.title(forFileNamed: "", content: "") == "Untitled")
        #expect(LibraryModel.title(forFileNamed: "", content: "\n\n") == "Untitled")
    }

    @Test("A very long first line is trimmed")
    func titleIsTrimmed() {
        let long = String(repeating: "字", count: 500)
        #expect(LibraryModel.title(forFileNamed: "", content: long).count == 60)
    }
}
