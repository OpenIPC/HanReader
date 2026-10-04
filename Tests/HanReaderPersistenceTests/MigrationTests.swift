// HanReader — MIT licensed. See LICENSE.

import Foundation
import GRDB
import HanReaderCore
import Testing
@testable import HanReaderPersistence

@Suite("Library migrations")
struct MigrationTests {
    /// A golden schema snapshot.
    ///
    /// Not here to be pretty: it is here so that an accidental schema change
    /// shows up as a readable diff in review rather than as a mysterious
    /// runtime failure months later. When this fails, either the change was
    /// unintended, or it was intended and needs a new migration plus an
    /// updated snapshot.
    @Test("The v1 schema is what we think it is")
    func schemaSnapshot() throws {
        let queue = try AppDatabase.inMemoryLibrary()
        let schema = try queue.read { db in
            try String.fetchAll(db, sql: """
                SELECT name || '(' || (
                    SELECT group_concat(p.name, ',')
                    FROM pragma_table_info(m.name) p
                ) || ')'
                FROM sqlite_master m
                WHERE type = 'table' AND name NOT LIKE 'sqlite_%' AND name NOT LIKE 'grdb_%'
                ORDER BY name
            """)
        }
        #expect(schema == [
            "appState(key,value)",
            "audioTrack(textId,relativePath,duration,importedAt)",
            "readingPosition(textId,blockIndex,tokenIndex,characterOffset,audioTime,updatedAt)",
            "revealedWord(textId,word,revealedAt)",
            "text(id,title,content,contentHash,characterCount,preview,"
                + "sourceName,importedAt,lastOpenedAt)",
        ])
    }

    @Test("All migrations are applied on a fresh database")
    func freshDatabaseIsFullyMigrated() throws {
        let queue = try AppDatabase.inMemoryLibrary()
        let migrator = LibrarySchema.migrator()
        let completed = try queue.read { db in
            try migrator.hasCompletedMigrations(db)
        }
        #expect(completed)
        #expect(migrator.migrations == ["v1_initial"])
    }

    /// Running the migrator again must be a no-op. Every launch does this.
    @Test("Migrating twice changes nothing")
    func idempotent() throws {
        let queue = try AppDatabase.inMemoryLibrary()
        try LibrarySchema.migrator().migrate(queue)
        try LibrarySchema.migrator().migrate(queue)
        let tables = try queue.read { db in
            try Int.fetchOne(db, sql: """
                SELECT count(*) FROM sqlite_master
                WHERE type = 'table' AND name NOT LIKE 'sqlite_%' AND name NOT LIKE 'grdb_%'
            """)
        }
        #expect(tables == 5)
    }

    /// The case an empty-database test cannot reach: a migration that works
    /// on a fresh schema but fails against rows that already exist. This
    /// builds a v1 database, fills it with realistic data, and re-migrates.
    ///
    /// Today there is only one migration so this is close to trivial. It is
    /// written now so the shape exists before it is needed: the first time a
    /// v2 is added, this test is where it gets exercised against real rows.
    @Test("Migrating a database that already holds data preserves it")
    func migratingPopulatedDatabase() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("library.sqlite")

        // Populate through the public API, so the data is shaped as the app
        // would really write it.
        do {
            let repository = try LibraryRepository(url: url)
            guard case let .imported(id) = try await repository.importText(
                title: "孔乙己", content: "我从十二岁起，便在镇口的咸亨酒店里当伙计。",
            ) else { Issue.record("import failed"); return }
            try await repository.save(ReadingPosition(
                textID: id, blockIndex: 2, tokenIndex: 5, characterOffset: 9, audioTime: 12.5,
            ))
            try await repository.reveal("咸亨酒店", in: id)
            try await repository.attachAudio(AudioTrack(
                textID: id, relativePath: "1.mp3", duration: 60, importedAt: .now,
            ))
        }

        // Reopen, which runs the migrator again over populated tables.
        let reopened = try LibraryRepository(url: url)
        let items = try await reopened.items()
        #expect(items.count == 1)
        let id = try #require(items.first?.id)
        #expect(try await reopened.position(of: id)?.characterOffset == 9)
        #expect(try await reopened.position(of: id)?.audioTime == 12.5)
        #expect(try await reopened.revealedWords(in: id) == ["咸亨酒店"])
        #expect(try await reopened.audioTrack(for: id)?.relativePath == "1.mp3")
    }

    /// Foreign keys are **off** by default in SQLite, so every ON DELETE
    /// CASCADE in the schema would silently do nothing without the
    /// configuration enabling them. This asserts the setting rather than the
    /// behaviour, because the behaviour tests would pass either way on a
    /// database with no orphans yet.
    @Test("Foreign key enforcement is actually on")
    func foreignKeysEnabled() throws {
        let queue = try AppDatabase.inMemoryLibrary()
        let enabled = try queue.read { db in
            try Bool.fetchOne(db, sql: "PRAGMA foreign_keys")
        }
        #expect(enabled == true)
    }

    /// A row referencing a text that does not exist must be rejected, not
    /// quietly stored.
    @Test("An orphaned row is refused")
    func orphanRejected() throws {
        let queue = try AppDatabase.inMemoryLibrary()
        #expect(throws: DatabaseError.self) {
            try queue.write { db in
                try db.execute(sql: """
                    INSERT INTO readingPosition
                        (textId, blockIndex, tokenIndex, characterOffset, updatedAt)
                    VALUES (99999, 0, 0, 0, ?)
                """, arguments: [Date()])
            }
        }
    }

    /// Content deduplication is enforced by the database, not only by the
    /// repository's check — so a future code path cannot route around it.
    @Test("Duplicate content is rejected at the schema level")
    func contentHashIsUnique() throws {
        let queue = try AppDatabase.inMemoryLibrary()
        let hash = Data(repeating: 0xAB, count: 32)
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO text (title, content, contentHash, characterCount, preview, importedAt)
                VALUES ('A', 'x', ?, 1, 'x', ?)
            """, arguments: [hash, Date()])
        }
        #expect(throws: DatabaseError.self) {
            try queue.write { db in
                try db.execute(sql: """
                    INSERT INTO text
                        (title, content, contentHash, characterCount, preview, importedAt)
                    VALUES ('B', 'x', ?, 1, 'x', ?)
                """, arguments: [hash, Date()])
            }
        }
    }

    /// Opening a database written by a newer build must fail with something
    /// readable rather than crashing or, worse, appearing to work.
    @Test("A database from a future version is refused clearly")
    func futureSchemaIsRefused() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("library.sqlite")

        _ = try LibraryRepository(url: url)

        // Forge a migration this build has never heard of.
        let queue = try DatabaseQueue(path: url.path)
        try queue.write { db in
            try db
                .execute(
                    sql: "INSERT INTO grdb_migrations (identifier) VALUES ('v999_from_the_future')",
                )
        }

        // GRDB's own migrate(_:) does NOT refuse this -- it ignores migrations
        // it does not recognise and carries on, which would let an older build
        // read a newer library through the wrong schema and write to it. The
        // guard in AppDatabase is what makes opening fail instead.
        #expect(throws: DatabaseOpenError.createdByNewerVersion) {
            _ = try LibraryRepository(url: url)
        }
    }
}

@Suite("Database locations")
struct DatabaseLocationTests {
    /// The dictionary database is large and fully regenerable, so it must not
    /// go into a user's iCloud backup. The library, which is their own work,
    /// must.
    @Test("Library and dictionary databases are separate files")
    func separateFiles() throws {
        let locations = try AppDatabase.Locations.standard()
        #expect(locations.library != locations.dictionaries)
        #expect(locations.library.lastPathComponent == "library.sqlite")
        #expect(locations.dictionaries.lastPathComponent == "dictionaries.sqlite")
        #expect(locations.library.deletingLastPathComponent()
            == locations.dictionaries.deletingLastPathComponent())
    }

    @Test("Backup exclusion can be applied and reads back")
    func backupExclusion() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let file = directory.appendingPathComponent("dictionaries.sqlite")
        try Data().write(to: file)
        try AppDatabase.excludeFromBackup(file)

        let values = try file.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)
    }
}
