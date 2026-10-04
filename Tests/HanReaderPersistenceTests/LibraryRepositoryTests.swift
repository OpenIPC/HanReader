// HanReader — MIT licensed. See LICENSE.

import Foundation
import HanReaderCore
import Testing
@testable import HanReaderPersistence

@Suite("Library import")
struct LibraryImportTests {
    @Test("Importing a text makes it visible with its metadata")
    func importText() async throws {
        let repository = try LibraryRepository.inMemory()
        let outcome = try await repository.importText(
            title: "孔乙己",
            content: "我从十二岁起，便在镇口的咸亨酒店里当伙计。",
        )

        guard case let .imported(id) = outcome else {
            Issue.record("expected .imported, got \(outcome)")
            return
        }

        let items = try await repository.items()
        #expect(items.count == 1)
        #expect(items[0].id == id)
        #expect(items[0].title == "孔乙己")
        #expect(items[0].characterCount == 21)
        #expect(items[0].hasAudio == false)
        #expect(items[0].progress == nil)
        #expect(try await repository.content(of: id)?.hasPrefix("我从") == true)
    }

    /// Deduplication is on content, not title. The prototype compared titles
    /// and silently did nothing on a match, so re-importing an edited file
    /// looked like a broken button.
    @Test("The same content twice is reported, not duplicated")
    func duplicateContent() async throws {
        let repository = try LibraryRepository.inMemory()
        let first = try await repository.importText(title: "A", content: "同样的内容")
        let second = try await repository.importText(title: "A different title", content: "同样的内容")

        guard case let .imported(id) = first, case let .alreadyPresent(existing) = second else {
            Issue.record("expected imported then alreadyPresent, got \(first) and \(second)")
            return
        }
        #expect(existing == id)
        #expect(try await repository.items().count == 1)
    }

    /// ...and the converse, which is the half the prototype got wrong: two
    /// files may legitimately share a title.
    @Test("The same title with different content imports twice")
    func sameTitleDifferentContent() async throws {
        let repository = try LibraryRepository.inMemory()
        _ = try await repository.importText(title: "孔乙己", content: "第一版")
        _ = try await repository.importText(title: "孔乙己", content: "第二版，修改过的")
        #expect(try await repository.items().count == 2)
    }

    @Test("The preview is stored, collapsed, and bounded")
    func preview() async throws {
        let repository = try LibraryRepository.inMemory()
        let content = "第一行\n\n第二行   第三行\n" + String(repeating: "字", count: 500)
        _ = try await repository.importText(title: "T", content: content)

        let preview = try await repository.items()[0].preview
        #expect(preview.count == 120)
        #expect(!preview.contains("\n"))
        #expect(preview.hasPrefix("第一行 第二行 第三行"))
    }

    @Test("Previews do not cut a multi-byte character in half")
    func previewIsCharacterSafe() {
        let preview = LibraryRepository.preview(of: String(repeating: "漢", count: 300), limit: 10)
        #expect(preview == String(repeating: "漢", count: 10))
        #expect(preview.unicodeScalars.allSatisfy { $0 != "\u{FFFD}" })
    }
}

@Suite("Reading position")
struct ReadingPositionTests {
    @Test("A position round-trips, including the audio playhead")
    func roundTrip() async throws {
        let repository = try LibraryRepository.inMemory()
        guard case let .imported(id) = try await repository
            .importText(title: "T", content: "一二三四五")
        else {
            Issue.record("import failed"); return
        }

        let saved = ReadingPosition(
            textID: id,
            blockIndex: 3,
            tokenIndex: 7,
            characterOffset: 2,
            audioTime: 42.5,
        )
        try await repository.save(saved)

        let loaded = try #require(try await repository.position(of: id))
        #expect(loaded.blockIndex == 3)
        #expect(loaded.tokenIndex == 7)
        #expect(loaded.characterOffset == 2)
        // The prototype lost the playhead on every relaunch.
        #expect(loaded.audioTime == 42.5)
    }

    @Test("Saving twice updates rather than failing on the primary key")
    func upsert() async throws {
        let repository = try LibraryRepository.inMemory()
        guard case let .imported(id) = try await repository.importText(title: "T", content: "一二三")
        else {
            Issue.record("import failed"); return
        }
        try await repository.save(ReadingPosition(
            textID: id,
            blockIndex: 0,
            tokenIndex: 0,
            characterOffset: 0,
        ))
        try await repository.save(ReadingPosition(
            textID: id,
            blockIndex: 1,
            tokenIndex: 2,
            characterOffset: 2,
        ))
        #expect(try await repository.position(of: id)?.characterOffset == 2)
    }

    @Test("Progress is derived for the library list")
    func progress() async throws {
        let repository = try LibraryRepository.inMemory()
        guard case let .imported(id) = try await repository.importText(
            title: "T", content: String(repeating: "字", count: 100),
        ) else { Issue.record("import failed"); return }

        #expect(try await repository.items()[0].progress == nil)
        try await repository.save(ReadingPosition(
            textID: id,
            blockIndex: 0,
            tokenIndex: 0,
            characterOffset: 25,
        ))
        #expect(try await repository.items()[0].progress == 0.25)
    }

    @Test("Fractions are clamped rather than exceeding the text")
    func fractionClamping() {
        let position = ReadingPosition(
            textID: TextID(rawValue: 1),
            blockIndex: 0,
            tokenIndex: 0,
            characterOffset: 500,
        )
        #expect(position.fraction(ofTextLength: 100) == 1)
        #expect(position.fraction(ofTextLength: 0) == 0)
    }
}

@Suite("Revealed words")
struct RevealedWordTests {
    /// Relational rather than a newline-joined blob, so a word containing a
    /// newline cannot corrupt the set — which the prototype's format could
    /// not survive.
    @Test("Words round-trip, including one containing a newline")
    func roundTrip() async throws {
        let repository = try LibraryRepository.inMemory()
        guard case let .imported(id) = try await repository.importText(title: "T", content: "内容")
        else {
            Issue.record("import failed"); return
        }
        try await repository.reveal("爱", in: id)
        try await repository.reveal("学习", in: id)
        try await repository.reveal("带\n换行", in: id)

        #expect(try await repository.revealedWords(in: id) == ["爱", "学习", "带\n换行"])
    }

    @Test("Revealing the same word twice is harmless")
    func idempotent() async throws {
        let repository = try LibraryRepository.inMemory()
        guard case let .imported(id) = try await repository.importText(title: "T", content: "内容")
        else {
            Issue.record("import failed"); return
        }
        try await repository.reveal("爱", in: id)
        try await repository.reveal("爱", in: id)
        #expect(try await repository.revealedWords(in: id).count == 1)
    }

    @Test("Unrevealing and clearing")
    func removal() async throws {
        let repository = try LibraryRepository.inMemory()
        guard case let .imported(id) = try await repository.importText(title: "T", content: "内容")
        else {
            Issue.record("import failed"); return
        }
        try await repository.reveal("爱", in: id)
        try await repository.reveal("学", in: id)
        try await repository.unreveal("爱", in: id)
        #expect(try await repository.revealedWords(in: id) == ["学"])
        try await repository.clearRevealedWords(in: id)
        #expect(try await repository.revealedWords(in: id).isEmpty)
    }

    @Test("Revealed words are scoped to their text")
    func scoped() async throws {
        let repository = try LibraryRepository.inMemory()
        guard case let .imported(first) = try await repository.importText(title: "A", content: "甲"),
              case let .imported(second) = try await repository.importText(title: "B", content: "乙")
        else { Issue.record("import failed"); return }

        try await repository.reveal("爱", in: first)
        #expect(try await repository.revealedWords(in: first) == ["爱"])
        #expect(try await repository.revealedWords(in: second).isEmpty)
    }
}

@Suite("Audio attachment")
struct AudioTrackTests {
    /// The path is relative. The prototype stored an absolute one containing
    /// the container UUID, which iOS changes across installs and restores, so
    /// every attachment broke on the first backup restore.
    @Test("A track round-trips and shows up in the library list")
    func attach() async throws {
        let repository = try LibraryRepository.inMemory()
        guard case let .imported(id) = try await repository.importText(title: "T", content: "内容")
        else {
            Issue.record("import failed"); return
        }
        #expect(try await repository.items()[0].hasAudio == false)

        try await repository.attachAudio(AudioTrack(
            textID: id, relativePath: "1-narration.mp3", duration: 123.4, importedAt: .now,
        ))

        let track = try #require(try await repository.audioTrack(for: id))
        #expect(track.relativePath == "1-narration.mp3")
        #expect(!track.relativePath.hasPrefix("/"), "the stored path must be relative")
        #expect(track.duration == 123.4)
        #expect(try await repository.items()[0].hasAudio)
    }

    @Test("Re-attaching replaces rather than failing")
    func replace() async throws {
        let repository = try LibraryRepository.inMemory()
        guard case let .imported(id) = try await repository.importText(title: "T", content: "内容")
        else {
            Issue.record("import failed"); return
        }
        try await repository.attachAudio(AudioTrack(
            textID: id,
            relativePath: "a.mp3",
            duration: 1,
            importedAt: .now,
        ))
        try await repository.attachAudio(AudioTrack(
            textID: id,
            relativePath: "b.mp3",
            duration: 2,
            importedAt: .now,
        ))
        #expect(try await repository.audioTrack(for: id)?.relativePath == "b.mp3")
    }
}

@Suite("Deletion and cascades")
struct DeletionTests {
    /// Cascades only fire because foreign keys are enabled in the
    /// configuration — SQLite has them **off** by default, so a schema full of
    /// ON DELETE CASCADE does nothing without it. The prototype deleted
    /// progress by hand and leaked its audio rows entirely.
    @Test("Deleting a text removes everything attached to it")
    func cascade() async throws {
        let repository = try LibraryRepository.inMemory()
        guard case let .imported(id) = try await repository.importText(title: "T", content: "内容")
        else {
            Issue.record("import failed"); return
        }
        try await repository.attachAudio(AudioTrack(
            textID: id,
            relativePath: "a.mp3",
            duration: 1,
            importedAt: .now,
        ))
        try await repository.save(ReadingPosition(
            textID: id,
            blockIndex: 1,
            tokenIndex: 1,
            characterOffset: 1,
        ))
        try await repository.reveal("爱", in: id)

        try await repository.delete(id)

        #expect(try await repository.items().isEmpty)
        #expect(try await repository.audioTrack(for: id) == nil)
        #expect(try await repository.position(of: id) == nil)
        #expect(try await repository.revealedWords(in: id).isEmpty)
    }

    @Test("Deleting one text leaves the others alone")
    func scoped() async throws {
        let repository = try LibraryRepository.inMemory()
        guard case let .imported(first) = try await repository.importText(title: "A", content: "甲"),
              case let .imported(second) = try await repository.importText(title: "B", content: "乙")
        else { Issue.record("import failed"); return }

        try await repository.reveal("爱", in: second)
        try await repository.delete(first)

        #expect(try await repository.items().map(\.id) == [second])
        #expect(try await repository.revealedWords(in: second) == ["爱"])
    }
}

@Suite("Library ordering")
struct LibraryOrderingTests {
    /// Most recently opened first, falling back to import date — so the list
    /// surfaces what the reader is actually working through.
    @Test("Recently opened texts come first")
    func ordering() async throws {
        let repository = try LibraryRepository.inMemory()
        // Explicit timestamps: three imports in the same millisecond would
        // otherwise leave the fallback ordering up to the clock's resolution.
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        guard case let .imported(first) = try await repository.importText(
            title: "A",
            content: "甲",
            now: base,
        ),
            case let .imported(second) = try await repository.importText(
                title: "B", content: "乙", now: base.addingTimeInterval(1),
            ),
            case let .imported(third) = try await repository.importText(
                title: "C", content: "丙", now: base.addingTimeInterval(2),
            )
        else { Issue.record("import failed"); return }

        // By import date alone: c, b, a.
        #expect(try await repository.items().map(\.id) == [third, second, first])

        // Opening the oldest brings it to the front.
        try await repository.markOpened(first, at: base.addingTimeInterval(60))
        #expect(try await repository.items().map(\.id) == [first, third, second])
    }
}
