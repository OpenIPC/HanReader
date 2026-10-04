// HanReader — MIT licensed. See LICENSE.

import Foundation
import HanReaderCore
import Testing
@testable import HanReaderPersistence

@Suite("Library regressions")
struct LibraryRegressionTests {
    /// `String.count` counts graphemes; `characterOffset` is UTF-16. Mixing
    /// the units makes progress overshoot. Not an emoji-only concern here:
    /// rare Hanzi in CJK Extension B are supplementary-plane, so a classical
    /// text would report finishing early.
    @Test("Progress uses one unit throughout")
    func progressUnitsAgree() async throws {
        let repository = try LibraryRepository.inMemory()
        // 𠀋 is U+2000B, in Extension B: one grapheme, two UTF-16 units.
        let content = String(repeating: "\u{2000B}", count: 50)
        #expect(content.count == 50)
        #expect(content.utf16.count == 100)

        guard case let .imported(id) = try await repository
            .importText(title: "T", content: content)
        else {
            Issue.record("import failed"); return
        }
        #expect(try await repository.items()[0].characterCount == 100)

        // Halfway through in UTF-16 terms is halfway through, not past the end.
        try await repository.save(ReadingPosition(
            textID: id,
            blockIndex: 0,
            tokenIndex: 0,
            characterOffset: 50,
        ))
        #expect(try await repository.items()[0].progress == 0.5)
    }

    /// The reader saves its position constantly while scrolling and has no
    /// playhead to supply, so a plain replace wiped the one the audio player
    /// had stored.
    @Test("Saving a position preserves the playhead")
    func positionSaveKeepsPlayhead() async throws {
        let repository = try LibraryRepository.inMemory()
        guard case let .imported(id) = try await repository.importText(title: "T", content: "内容")
        else {
            Issue.record("import failed"); return
        }
        try await repository.save(ReadingPosition(
            textID: id, blockIndex: 0, tokenIndex: 0, characterOffset: 0, audioTime: 90,
        ))
        // A scroll: no audioTime supplied.
        try await repository.save(ReadingPosition(
            textID: id, blockIndex: 1, tokenIndex: 1, characterOffset: 1,
        ))

        let position = try #require(try await repository.position(of: id))
        #expect(position.characterOffset == 1)
        #expect(position.audioTime == 90, "the playhead should survive a position-only save")
    }

    @Test("The playhead can still be cleared deliberately")
    func playheadCanBeCleared() async throws {
        let repository = try LibraryRepository.inMemory()
        guard case let .imported(id) = try await repository.importText(title: "T", content: "内容")
        else {
            Issue.record("import failed"); return
        }
        try await repository.save(ReadingPosition(
            textID: id, blockIndex: 0, tokenIndex: 0, characterOffset: 0, audioTime: 90,
        ))
        try await repository.clearAudioTime(of: id)
        #expect(try await repository.position(of: id)?.audioTime == nil)
    }

    /// The cascade removes the row; nothing removed the file, so a deleted
    /// text left its audio on disk forever, unreferenced and invisible.
    @Test("Deleting a text removes its audio file too")
    func deleteRemovesAudioFile() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let repository = try LibraryRepository.inMemory(audioDirectory: directory)
        guard case let .imported(id) = try await repository.importText(title: "T", content: "内容")
        else {
            Issue.record("import failed"); return
        }

        let file = directory.appendingPathComponent("1-narration.mp3")
        try Data("audio".utf8).write(to: file)
        try await repository.attachAudio(AudioTrack(
            textID: id, relativePath: "1-narration.mp3", duration: 1, importedAt: .now,
        ))

        try await repository.delete(id)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test("Deleting a text with no audio is still fine")
    func deleteWithoutAudio() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let repository = try LibraryRepository.inMemory(audioDirectory: directory)
        guard case let .imported(id) = try await repository.importText(title: "T", content: "内容")
        else {
            Issue.record("import failed"); return
        }
        try await repository.delete(id)
        #expect(try await repository.items().isEmpty)
    }

    /// An absolute path embeds the container UUID, and the breakage only
    /// appears after a restore -- long after the mistake and far from it.
    @Test("An absolute audio path is refused", arguments: [
        "/Users/someone/Library/Containers/ABC/audio.mp3",
        "../outside/audio.mp3",
    ])
    func absoluteAudioPathRejected(path: String) async throws {
        let repository = try LibraryRepository.inMemory()
        guard case let .imported(id) = try await repository.importText(title: "T", content: "内容")
        else {
            Issue.record("import failed"); return
        }
        await #expect(throws: LibraryError.audioPathMustBeRelative(path)) {
            try await repository.attachAudio(AudioTrack(
                textID: id, relativePath: path, duration: 1, importedAt: .now,
            ))
        }
    }

    /// The obvious implementation allocates intermediates proportional to the
    /// whole document to produce 120 characters.
    @Test("Previewing a large document stays bounded")
    func previewIsBounded() {
        let huge = String(repeating: "字 ", count: 2_000_000) // ~4M characters
        let preview = LibraryRepository.preview(of: huge, limit: 120)
        #expect(preview.count == 120)
        #expect(preview.hasPrefix("字 字 字"))
    }

    @Test("Preview collapsing still behaves", arguments: [
        ("  leading\n\nand   interior  ", "leading and interior"),
        ("", ""),
        ("   ", ""),
        ("single", "single"),
    ])
    func previewCollapsing(input: String, expected: String) {
        #expect(LibraryRepository.preview(of: input, limit: 120) == expected)
    }
}
