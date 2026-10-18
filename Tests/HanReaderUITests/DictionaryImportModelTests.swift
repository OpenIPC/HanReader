// HanReader — MIT licensed. See LICENSE.

import Foundation
import HanReaderCore
import HanReaderPersistence
import Testing
@testable import HanReaderUI

/// A small DSL set on disk, written the way ABBYY writes one.
private struct Workspace: ~Copyable {
    let root: URL

    init() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("hanreader-import-ui-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    func write(_ name: String, cards: Int) throws -> URL {
        var text = """
        #NAME "Example Dictionary - 010203"\r
        #INDEX_LANGUAGE "Chinese"
        #CONTENTS_LANGUAGE "Russian"

        """
        for index in 0 ..< cards {
            text += "w\(index)\n ài\n [m1]значение \(index)[/m]\n"
        }
        var bytes: [UInt8] = [0xFF, 0xFE]
        for unit in Array(text.utf16) {
            bytes += [UInt8(unit & 0xFF), UInt8(unit >> 8)]
        }
        let url = root.appendingPathComponent(name)
        try Data(bytes).write(to: url)
        return url
    }
}

@MainActor
@Suite("Dictionary import model")
struct DictionaryImportModelTests {
    /// Runs an import to its end state, however it ends.
    private func run(_ model: DictionaryImportModel, _ url: URL) async {
        await withCheckedContinuation { continuation in
            var resumed = false
            model.start(url) {
                guard !resumed else { return }
                resumed = true
                continuation.resume()
            }
        }
    }

    @Test("An import reports what it imported")
    func importsAndReports() async throws {
        let workspace = try Workspace()
        let source = try workspace.write("a.dsl", cards: 40)
        let services = try AppServices.inMemory()
        let model = DictionaryImportModel(services: services)

        await run(model, source)

        guard case let .finished(summary) = model.phase else {
            Issue.record("expected a finished import, got \(model.phase)")
            return
        }
        #expect(summary.entriesWritten == 40)
        #expect(summary.completed)
    }

    /// The reader should see what they are importing while it runs, not only
    /// its file name — a three-volume set is picked by its first file and
    /// called something else entirely.
    @Test("The dictionary's own name is shown")
    func reportsTheName() async throws {
        let workspace = try Workspace()
        let source = try workspace.write("a.dsl", cards: 10)
        let services = try AppServices.inMemory()
        let model = DictionaryImportModel(services: services)

        await run(model, source)
        #expect(model.name == "Example Dictionary - 010203")
    }

    /// Written where the finished container will live, under the name it
    /// will have — which is what lets a second attempt resume rather than
    /// start again beside the first.
    @Test("The container lands in the dictionaries directory")
    func writesToTheDictionaryDirectory() async throws {
        let workspace = try Workspace()
        let source = try workspace.write("a.dsl", cards: 10)
        let services = try AppServices.inMemory()
        let model = DictionaryImportModel(services: services)

        await run(model, source)

        let expected = DictionaryCatalogue.finishedFile(
            forSlug: "example-dictionary-010203",
            in: services.locations.dictionaryDirectory,
        )
        #expect(FileManager.default.fileExists(atPath: expected.path))
        #expect(try DictionaryContainer(contentsOf: expected).entryCount() == 10)
        // And nothing left behind under the in-progress name.
        #expect(!FileManager.default.fileExists(atPath: DictionaryCatalogue.partialFile(
            forSlug: "example-dictionary-010203",
            in: services.locations.dictionaryDirectory,
        ).path))
    }

    /// A reader re-importing a dictionary they already have must not lose it
    /// while the new import runs: the writer clears its destination when it
    /// cannot resume into it, so the destination must not be the dictionary
    /// they are using.
    @Test("An import in progress does not occupy the installed dictionary's place")
    func inProgressImportLeavesTheInstalledOneAlone() async throws {
        let workspace = try Workspace()
        let source = try workspace.write("a.dsl", cards: 30)
        let services = try AppServices.inMemory()
        let installed = DictionaryCatalogue.finishedFile(
            forSlug: "example-dictionary-010203",
            in: services.locations.dictionaryDirectory,
        )

        // A first import, finished.
        await run(DictionaryImportModel(services: services), source)
        #expect(try DictionaryContainer(contentsOf: installed).entryCount() == 30)

        // A second one, stopped before it can finish.
        let model = DictionaryImportModel(services: services)
        model.start(source) {}
        model.stop()
        while model.isRunning {
            try await Task.sleep(for: .milliseconds(10))
        }

        // The dictionary the reader had is still a dictionary.
        #expect(try DictionaryContainer(contentsOf: installed).entryCount() == 30)
    }

    /// A stopped import is recognised by its name, which needs no metadata
    /// and — crucially — no read-only open: a half-written database in
    /// write-ahead mode may not survive one.
    @Test("A stopped import is listed as unfinished, not unreadable")
    func stoppedImportIsUnfinished() async throws {
        let workspace = try Workspace()
        let source = try workspace.write("a.dsl", cards: 200)
        let services = try AppServices.inMemory()

        let model = DictionaryImportModel(services: services)
        model.start(source) {}
        model.stop()
        while model.isRunning {
            try await Task.sleep(for: .milliseconds(10))
        }

        let catalogue = try await AppDatabase.catalogue(
            in: services.locations.dictionaryDirectory,
            bundled: nil,
            library: services.library,
        )
        #expect(catalogue.unreadable.isEmpty)
        #expect(catalogue.unfinished.count == 1)
        #expect(catalogue.installed.isEmpty)
    }

    /// Including after a failure: a run that threw may still have left a
    /// part-written container, and a list that does not mention it is a list
    /// the reader cannot act on.
    @Test("The catalogue is read again however the import ends")
    func reloadsEvenOnFailure() async throws {
        let workspace = try Workspace()
        let url = workspace.root.appendingPathComponent("missing.dsl")
        let services = try AppServices.inMemory()
        let model = DictionaryImportModel(services: services)

        var reloaded = false
        await withCheckedContinuation { continuation in
            model.start(url) {
                reloaded = true
                continuation.resume()
            }
        }
        #expect(reloaded)
    }

    @Test("A file that is not a dictionary fails rather than hangs")
    func failsOnRubbish() async throws {
        let workspace = try Workspace()
        let url = workspace.root.appendingPathComponent("notes.txt")
        try Data("not a dictionary at all".utf8).write(to: url)
        let services = try AppServices.inMemory()
        let model = DictionaryImportModel(services: services)

        await run(model, url)

        // A text file has no headwords and no articles, so there is nothing
        // to import — which must end, and say so, rather than appear to work.
        switch model.phase {
        case let .finished(summary): #expect(summary.entriesWritten == 0)
        case .failed: break
        default: Issue.record("expected an ending, got \(model.phase)")
        }
    }

    @Test("Resetting makes the sheet usable again")
    func reset() async throws {
        let workspace = try Workspace()
        let source = try workspace.write("a.dsl", cards: 5)
        let services = try AppServices.inMemory()
        let model = DictionaryImportModel(services: services)

        await run(model, source)
        model.reset()
        #expect(model.phase == .idle)
        #expect(model.name == nil)
        #expect(!model.isRunning)
    }
}
