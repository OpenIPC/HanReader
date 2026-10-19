// HanReader — MIT licensed. See LICENSE.

import Foundation
import HanReaderCore
import HanReaderPersistence
import Testing
@testable import HanReaderUI

@MainActor
@Suite("Attaching audio")
struct AudioAttachmentTests {
    private func workspace() throws -> (root: URL, locations: AppDatabase.Locations) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("audio-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (root, AppDatabase.Locations(
            library: root.appendingPathComponent("library.sqlite"),
            dictionaries: root.appendingPathComponent("dictionaries", isDirectory: true),
            audio: root.appendingPathComponent("audio", isDirectory: true),
        ))
    }

    private func source(_ root: URL, named name: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try Data("pretend this is audio".utf8).write(to: url)
        return url
    }

    /// The platform-fatal bug this code exists to prevent. The prototype
    /// stored `dest.path`, an absolute path containing the app container's
    /// UUID — which changes when an iOS app is reinstalled or restored, so
    /// every attachment broke at once, silently, long afterwards.
    @Test("The stored path is relative, and inside the container")
    func pathIsRelative() async throws {
        let space = try workspace()
        let library = try LibraryRepository.inMemory(audioDirectory: space.locations.audio)
        let id = try await imported(into: library)
        let file = try await AudioAttachment.attach(
            source(space.root, named: "narration.m4a"),
            to: id,
            in: space.locations,
            library: library,
        )

        let track = try #require(try await library.audioTrack(for: id))
        #expect(!track.relativePath.hasPrefix("/"))
        #expect(!track.relativePath.contains("/"))
        #expect(track.relativePath.hasSuffix(".m4a"))
        // And resolving it finds the copy, not the original.
        #expect(AudioAttachment.file(for: track, in: space.locations) == file)
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    /// The reader picked the file out of a security-scoped location, and
    /// that grant does not survive the launch. A reference would be a
    /// reference that stops working.
    @Test("The file is copied, not referenced")
    func fileIsCopied() async throws {
        let space = try workspace()
        let library = try LibraryRepository.inMemory(audioDirectory: space.locations.audio)
        let id = try await imported(into: library)
        let original = try source(space.root, named: "narration.m4a")
        let copy = try await AudioAttachment.attach(
            original,
            to: id,
            in: space.locations,
            library: library,
        )

        #expect(copy != original)
        let copied = try Data(contentsOf: copy)

        // Changed **in place**, through a file handle: `Data.write(to:)`
        // replaces the file with a new one, which a hard link would survive
        // — so that would pass whether or not the bytes were really copied.
        let handle = try FileHandle(forWritingTo: original)
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: Data("something else entirely".utf8))
        try handle.close()

        #expect(try Data(contentsOf: copy) == copied)
        #expect(try Data(contentsOf: copy) != Data(contentsOf: original))

        // And deleting what the reader chose leaves the narration intact.
        try FileManager.default.removeItem(at: original)
        #expect(FileManager.default.fileExists(atPath: copy.path))
    }

    /// The name comes from the text, not from the file the reader picked, so
    /// two texts narrated by two files both called `audio.m4a` do not
    /// collide — and so no part of the reader's own filesystem is kept.
    @Test("Two texts with identically named sources do not collide")
    func namesDoNotCollide() async throws {
        let space = try workspace()
        let library = try LibraryRepository.inMemory(audioDirectory: space.locations.audio)
        let first = try await imported(into: library, content: "我爱你")
        let second = try await imported(into: library, content: "你好世界")

        let one = try await AudioAttachment.attach(
            source(space.root, named: "audio.m4a"),
            to: first,
            in: space.locations,
            library: library,
        )
        let two = try await AudioAttachment.attach(
            source(space.root, named: "audio.m4a"),
            to: second,
            in: space.locations,
            library: library,
        )
        #expect(one != two)
        #expect(FileManager.default.fileExists(atPath: one.path))
        #expect(FileManager.default.fileExists(atPath: two.path))
    }

    /// Re-attaching replaces, rather than leaving the old file on disk with
    /// nothing pointing at it.
    @Test("Replacing a narration leaves one file behind, not two")
    func replacingDoesNotOrphan() async throws {
        let space = try workspace()
        let library = try LibraryRepository.inMemory(audioDirectory: space.locations.audio)
        let id = try await imported(into: library)

        _ = try await AudioAttachment.attach(
            source(space.root, named: "first.m4a"),
            to: id,
            in: space.locations,
            library: library,
        )
        _ = try await AudioAttachment.attach(
            source(space.root, named: "second.m4a"),
            to: id,
            in: space.locations,
            library: library,
        )

        let files = try FileManager.default.contentsOfDirectory(
            atPath: space.locations.audio.path,
        )
        #expect(files.count == 1)
        // And one row, not two: the schema is one track per text.
        #expect(try await library.audioTrack(for: id) != nil)
    }

    private func imported(
        into library: LibraryRepository,
        content: String = "我在一个山村学校当老师",
    ) async throws
        -> TextID
    {
        switch try await library.importText(title: "听力", content: content) {
        case let .imported(id): id
        case let .alreadyPresent(id): id
        }
    }
}
