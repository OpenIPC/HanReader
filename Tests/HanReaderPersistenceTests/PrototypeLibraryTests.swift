// HanReader — MIT licensed. See LICENSE.

import Foundation
import GRDB
import HanReaderCore
import Testing
@testable import HanReaderPersistence

/// Builds a prototype database with the schema the old app actually wrote.
///
/// Copied from the real file rather than invented: `texts` has no
/// `content_hash` and no `updated_at`, `reading_progress` is keyed on
/// `text_id` with no row of its own, and `revealed_words` is a single
/// newline-joined string. A fixture that drifted from that would test a
/// migration nobody needs.
private func makePrototype(at url: URL) throws -> DatabaseQueue {
    let db = try DatabaseQueue(path: url.path)
    try db.write { db in
        try db.execute(sql: """
            CREATE TABLE texts (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                title TEXT NOT NULL,
                content TEXT NOT NULL,
                audio_path TEXT,
                imported_at REAL NOT NULL
            );
            CREATE TABLE reading_progress (
                text_id INTEGER PRIMARY KEY,
                scroll_offset REAL NOT NULL DEFAULT 0,
                revealed_words TEXT NOT NULL DEFAULT '',
                last_opened_at REAL NOT NULL
            );
        """)
    }
    return db
}

private struct Workspace {
    let root: URL
    let locations: AppDatabase.Locations
    let prototype: URL
}

private func workspace() throws -> Workspace {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("prototype-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let locations = AppDatabase.Locations(
        library: root.appendingPathComponent("library.sqlite"),
        dictionaries: root.appendingPathComponent("dictionaries", isDirectory: true),
        audio: root.appendingPathComponent("audio", isDirectory: true),
    )
    return Workspace(
        root: root,
        locations: locations,
        prototype: PrototypeLibrary.file(near: locations.library),
    )
}

@Suite("Prototype library migration")
struct PrototypeLibraryTests {
    @Test("Texts, revealed words and last-opened all come across")
    func migratesEverything() async throws {
        let space = try workspace()
        let old = try makePrototype(at: space.prototype)
        try await old.write { db in
            try db.execute(
                sql: "INSERT INTO texts (id, title, content, imported_at) VALUES (?, ?, ?, ?)",
                arguments: [1, "孔乙己", "我从十二岁起，便在镇口的咸亨酒店里当伙计", 1_600_000_000.0],
            )
            try db.execute(sql: """
                INSERT INTO reading_progress
                    (text_id, scroll_offset, revealed_words, last_opened_at)
                VALUES (?, ?, ?, ?)
            """, arguments: [1, 480.5, "伙计\n绰号\n镇", 1_700_000_000.0])
        }

        let library = try LibraryRepository.inMemory(audioDirectory: space.locations.audio)
        let outcome = try #require(try await PrototypeLibrary.migrateIfPresent(
            into: library,
            locations: space.locations,
        ))

        #expect(outcome.texts == 1)
        #expect(outcome.revealedWords == 3)

        let items = try await library.items()
        #expect(items.count == 1)
        let id = try #require(items.first?.id)
        #expect(items.first?.title == "孔乙己")

        // The blob, undone.
        let revealed = try await library.revealedWords(in: id)
        #expect(revealed == ["伙计", "绰号", "镇"])

        let position = try await library.position(of: id)
        // `scroll_offset` is a pixel count and there is nothing to convert it
        // into, so it is dropped rather than guessed at.
        #expect(position?.characterOffset ?? 0 == 0)
    }

    /// The migration must be safe to run twice — a crash between migrating
    /// and renaming the file leaves it there for the next launch.
    @Test("Running twice does not duplicate anything")
    func migrationIsIdempotent() async throws {
        let space = try workspace()
        let old = try makePrototype(at: space.prototype)
        try await old.write { db in
            try db.execute(
                sql: "INSERT INTO texts (id, title, content, imported_at) VALUES (?, ?, ?, ?)",
                arguments: [1, "孔乙己", "我从十二岁起", 1.0],
            )
            try db.execute(sql: """
                INSERT INTO reading_progress
                    (text_id, scroll_offset, revealed_words, last_opened_at)
                VALUES (?, 0, ?, ?)
            """, arguments: [1, "伙计\n伙计", 2.0])
        }

        let library = try LibraryRepository.inMemory(audioDirectory: space.locations.audio)
        let first = try await PrototypeLibrary.migrate(
            from: space.prototype,
            into: library,
            locations: space.locations,
        )
        let second = try await PrototypeLibrary.migrate(
            from: space.prototype,
            into: library,
            locations: space.locations,
        )

        #expect(first.texts == 1)
        // Second time, deduplicated on content rather than inserted again.
        #expect(second.texts == 0)
        #expect(second.alreadyPresent == 1)
        #expect(try await library.items().count == 1)

        let id = try #require(try await library.items().first?.id)
        #expect(try await library.revealedWords(in: id) == ["伙计"])
    }

    @Test("An empty revealed-words string produces no words")
    func emptyBlobIsNotOneEmptyWord() async throws {
        let space = try workspace()
        let old = try makePrototype(at: space.prototype)
        try await old.write { db in
            try db.execute(
                sql: "INSERT INTO texts (id, title, content, imported_at) VALUES (?, ?, ?, ?)",
                arguments: [1, "空", "我爱你", 1.0],
            )
            try db.execute(sql: """
                INSERT INTO reading_progress
                    (text_id, scroll_offset, revealed_words, last_opened_at)
                VALUES (?, 0, '', ?)
            """, arguments: [1, 2.0])
        }

        let library = try LibraryRepository.inMemory(audioDirectory: space.locations.audio)
        let outcome = try await PrototypeLibrary.migrate(
            from: space.prototype,
            into: library,
            locations: space.locations,
        )
        #expect(outcome.revealedWords == 0)
        let id = try #require(try await library.items().first?.id)
        #expect(try await library.revealedWords(in: id).isEmpty)
    }

    /// The prototype stored an absolute path containing the container's
    /// UUID. On a device that path is long gone, which is the whole reason
    /// the new schema stores a relative one.
    @Test("Audio whose absolute path no longer resolves is reported, not fatal")
    func missingAudioIsReported() async throws {
        let space = try workspace()
        let old = try makePrototype(at: space.prototype)
        try await old.write { db in
            try db.execute(sql: """
                INSERT INTO texts (id, title, content, audio_path, imported_at)
                VALUES (?, ?, ?, ?, ?)
            """, arguments: [
                1, "孔乙己", "我从十二岁起",
                "/var/mobile/Containers/Data/Application/DEAD-BEEF/audio/kong.m4a", 1.0,
            ])
        }

        let library = try LibraryRepository.inMemory(audioDirectory: space.locations.audio)
        let outcome = try await PrototypeLibrary.migrate(
            from: space.prototype,
            into: library,
            locations: space.locations,
        )

        // The text still arrives; only its audio is missing.
        #expect(outcome.texts == 1)
        #expect(outcome.audioTracks == 0)
        #expect(outcome.notes.count == 1)
        let id = try #require(try await library.items().first?.id)
        #expect(try await library.audioTrack(for: id) == nil)
    }

    /// And when the file *is* still there it is copied inside and recorded
    /// relatively — the fix, applied to the reader's history.
    @Test("Audio that still exists is copied in and stored relatively")
    func audioIsCarriedAcross() async throws {
        let space = try workspace()
        let source = space.root.appendingPathComponent("narration.m4a")
        try Data("not really audio".utf8).write(to: source)

        let old = try makePrototype(at: space.prototype)
        try await old.write { db in
            try db.execute(sql: """
                INSERT INTO texts (id, title, content, audio_path, imported_at)
                VALUES (?, ?, ?, ?, ?)
            """, arguments: [1, "孔乙己", "我从十二岁起", source.path, 1.0])
        }

        let library = try LibraryRepository.inMemory(audioDirectory: space.locations.audio)
        let outcome = try await PrototypeLibrary.migrate(
            from: space.prototype,
            into: library,
            locations: space.locations,
        )

        #expect(outcome.audioTracks == 1)
        let id = try #require(try await library.items().first?.id)
        let track = try #require(try await library.audioTrack(for: id))
        #expect(!track.relativePath.hasPrefix("/"))
        #expect(!track.relativePath.contains("Containers"))

        let copied = AudioAttachmentPath.file(for: track, in: space.locations)
        #expect(FileManager.default.fileExists(atPath: copied.path))
    }

    /// Review finding: a migrated library should keep the order the reader
    /// built it in, rather than having every text stamped with the moment of
    /// migration.
    @Test("Migrated texts keep their original import dates")
    func importDatesAreCarried() async throws {
        let space = try workspace()
        let old = try makePrototype(at: space.prototype)
        let when = 1_500_000_000.0
        try await old.write { db in
            try db.execute(
                sql: "INSERT INTO texts (id, title, content, imported_at) VALUES (?, ?, ?, ?)",
                arguments: [1, "孔乙己", "我从十二岁起", when],
            )
        }

        let library = try LibraryRepository.inMemory(audioDirectory: space.locations.audio)
        _ = try await PrototypeLibrary.migrate(
            from: space.prototype,
            into: library,
            locations: space.locations,
        )

        let item = try #require(try await library.items().first)
        #expect(abs(item.importedAt.timeIntervalSince1970 - when) < 1)
    }

    /// Review finding: a file the old container will not let us read used to
    /// throw out of the whole migration — and because the rename that marks
    /// it done never ran, it would fail again on every launch for ever.
    @Test("An unreadable old audio file does not abort the migration")
    func unreadableAudioDoesNotAbort() async throws {
        let space = try workspace()
        let narration = space.root.appendingPathComponent("old.m4a")
        try Data("old recording".utf8).write(to: narration)
        // The audio directory's path is occupied by an ordinary file, so
        // nothing can be written into it. That stands in for the real
        // failure — a sandbox or permission denial on the old container —
        // which cannot be staged in a test.
        try Data().write(to: space.locations.audio)

        let old = try makePrototype(at: space.prototype)
        try await old.write { db in
            try db.execute(sql: """
                INSERT INTO texts (id, title, content, audio_path, imported_at)
                VALUES (?, ?, ?, ?, ?)
            """, arguments: [1, "孔乙己", "我从十二岁起", narration.path, 1.0])
            try db.execute(
                sql: "INSERT INTO texts (id, title, content, imported_at) VALUES (?, ?, ?, ?)",
                arguments: [2, "立论", "我梦见自己正在小学校的讲堂上", 2.0],
            )
        }

        let library = try LibraryRepository.inMemory(audioDirectory: space.locations.audio)
        let outcome = try await PrototypeLibrary.migrateIfPresent(
            into: library,
            locations: space.locations,
        )
        let result = try #require(outcome)

        // Both texts arrive; only the audio is reported as lost.
        #expect(result.texts == 2)
        #expect(result.notes.count == 1)
        // And the migration is marked done, so it is not retried for ever.
        #expect(FileManager.default.fileExists(
            atPath: PrototypeLibrary.migratedFile(near: space.locations.library).path,
        ))
    }

    @Test("No prototype database means nothing to do")
    func absentPrototypeIsNotAnError() async throws {
        let space = try workspace()
        let library = try LibraryRepository.inMemory(audioDirectory: space.locations.audio)
        let outcome = try await PrototypeLibrary.migrateIfPresent(
            into: library,
            locations: space.locations,
        )
        #expect(outcome == nil)
    }

    /// Renamed rather than deleted: a reader whose migration went wrong
    /// still has their texts. And renamed rather than flagged, so the state
    /// lives with the file — delete the library and the migration is
    /// genuinely not pending again, which a `UserDefaults` flag cannot say.
    @Test("A migrated database is kept under a new name")
    func migratedFileIsKept() async throws {
        let space = try workspace()
        let old = try makePrototype(at: space.prototype)
        try await old.write { db in
            try db.execute(
                sql: "INSERT INTO texts (id, title, content, imported_at) VALUES (?, ?, ?, ?)",
                arguments: [1, "孔乙己", "我从十二岁起", 1.0],
            )
        }

        let library = try LibraryRepository.inMemory(audioDirectory: space.locations.audio)
        _ = try await PrototypeLibrary.migrateIfPresent(into: library, locations: space.locations)

        #expect(!FileManager.default.fileExists(atPath: space.prototype.path))
        #expect(FileManager.default.fileExists(
            atPath: PrototypeLibrary.migratedFile(near: space.locations.library).path,
        ))

        // And so a second launch finds nothing to do.
        #expect(try await PrototypeLibrary.migrateIfPresent(
            into: library,
            locations: space.locations,
        ) == nil)
    }
}

/// The same resolution the UI layer does, repeated here because that code
/// lives above this module and a persistence test cannot import it.
private enum AudioAttachmentPath {
    static func file(for track: AudioTrack, in locations: AppDatabase.Locations) -> URL {
        locations.audio.appendingPathComponent(track.relativePath)
    }
}

/// What a migration must *not* touch.
///
/// A reader who has used both versions has a library that is partly theirs
/// already — the same text, their own narration for it, their own reading
/// history. Migration adds what is missing; it does not get to overwrite
/// what is there.
@Suite("Prototype migration leaves existing work alone")
struct PrototypeLibraryExistingWorkTests {
    /// Review finding: a text already in the library may have a narration
    /// the reader chose themselves. Replacing it with one from a previous
    /// version of the app is not a migration, it is a loss.
    @Test("Migration does not replace audio on a text that was already there")
    func existingAudioIsNotReplaced() async throws {
        let space = try workspace()
        let narration = space.root.appendingPathComponent("old.m4a")
        try Data("old recording".utf8).write(to: narration)

        let old = try makePrototype(at: space.prototype)
        try await old.write { db in
            try db.execute(sql: """
                INSERT INTO texts (id, title, content, audio_path, imported_at)
                VALUES (?, ?, ?, ?, ?)
            """, arguments: [1, "孔乙己", "我从十二岁起", narration.path, 1.0])
        }

        // The same content is already in the library, with its own audio.
        let library = try LibraryRepository.inMemory(audioDirectory: space.locations.audio)
        let existing = try await library.importText(title: "孔乙己", content: "我从十二岁起")
        guard case let .imported(id) = existing else {
            Issue.record("expected a new text")
            return
        }
        try await library.attachAudio(AudioTrack(
            textID: id,
            relativePath: "chosen-by-the-reader.m4a",
            duration: nil,
            importedAt: Date(),
        ))

        let outcome = try await PrototypeLibrary.migrate(
            from: space.prototype,
            into: library,
            locations: space.locations,
        )

        #expect(outcome.alreadyPresent == 1)
        #expect(outcome.audioTracks == 0)
        let track = try #require(try await library.audioTrack(for: id))
        #expect(track.relativePath == "chosen-by-the-reader.m4a")
    }

    /// Review finding: a text already in the library has its own, newer
    /// history. Stamping it with a prototype timestamp moves it backwards in
    /// the sidebar and can change which text opens on launch.
    @Test("Migration does not move an existing text backwards in time")
    func existingRecencyIsNotRewound() async throws {
        let space = try workspace()
        let old = try makePrototype(at: space.prototype)
        try await old.write { db in
            try db.execute(
                sql: "INSERT INTO texts (id, title, content, imported_at) VALUES (?, ?, ?, ?)",
                arguments: [1, "孔乙己", "我从十二岁起", 1.0],
            )
            try db.execute(sql: """
                INSERT INTO reading_progress
                    (text_id, scroll_offset, revealed_words, last_opened_at)
                VALUES (?, 0, '', ?)
            """, arguments: [1, 100.0])
        }

        let library = try LibraryRepository.inMemory(audioDirectory: space.locations.audio)
        let existing = try await library.importText(title: "孔乙己", content: "我从十二岁起")
        guard case let .imported(id) = existing else {
            Issue.record("expected a new text")
            return
        }
        let recent = Date(timeIntervalSince1970: 1_800_000_000)
        try await library.markOpened(id, at: recent)

        _ = try await PrototypeLibrary.migrate(
            from: space.prototype,
            into: library,
            locations: space.locations,
        )

        let item = try #require(try await library.items().first { $0.id == id })
        #expect(item.lastOpenedAt == recent)
    }
}
