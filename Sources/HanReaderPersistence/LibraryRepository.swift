// HanReader — MIT licensed. See LICENSE.

import CryptoKit
public import Foundation
import GRDB
public import HanReaderCore

/// Reads and writes the user's library.
///
/// No GRDB type appears in this API. `InternalImportsByDefault` makes that a
/// compile error rather than a review comment, which is what keeps the storage
/// engine replaceable with a blast radius of one directory.
public struct LibraryRepository: Sendable {
    /// What happened when a text was imported.
    public enum ImportOutcome: Sendable, Hashable {
        case imported(TextID)
        /// The same *content* is already present. The caller should open that
        /// text and say so, rather than appearing to do nothing — which is
        /// what the prototype did whenever two files shared a title.
        case alreadyPresent(TextID)
    }

    private let dbQueue: DatabaseQueue

    /// Where attached audio lives. Needed so that deleting a text can remove
    /// its audio file, not merely the row pointing at it.
    private let audioDirectory: URL?

    /// Opens the library at `url`, creating and migrating it as needed.
    public init(url: URL, audioDirectory: URL? = nil) throws {
        dbQueue = try AppDatabase.openLibrary(at: url)
        self.audioDirectory = audioDirectory
    }

    /// Opens the library at its standard location in the application support
    /// directory.
    public init(locations: AppDatabase.Locations) throws {
        try self.init(url: locations.library, audioDirectory: locations.audio)
    }

    /// An in-memory library, for tests and previews.
    ///
    /// The queue is held privately, so GRDB never crosses this module's
    /// boundary -- `InternalImportsByDefault` would refuse to compile a
    /// public initializer taking one.
    public static func inMemory(audioDirectory: URL? = nil) throws -> Self {
        try Self(dbQueue: AppDatabase.inMemoryLibrary(), audioDirectory: audioDirectory)
    }

    init(dbQueue: DatabaseQueue, audioDirectory: URL? = nil) {
        self.dbQueue = dbQueue
        self.audioDirectory = audioDirectory
    }

    // MARK: - Reading

    /// Everything needed to draw the library list, and nothing more.
    ///
    /// Note the absence of `content` in the projection: the whole point of
    /// storing `preview` is that this query stays cheap no matter how large
    /// the library or the individual texts are.
    public func items() async throws -> [LibraryItem] {
        try await dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT t.id, t.title, t.preview, t.characterCount, t.importedAt, t.lastOpenedAt,
                       (a.textId IS NOT NULL) AS hasAudio,
                       p.characterOffset AS characterOffset
                FROM text t
                LEFT JOIN audioTrack a ON a.textId = t.id
                LEFT JOIN readingPosition p ON p.textId = t.id
                -- id DESC as a tie-break: several texts imported in the
                -- same millisecond would otherwise come back in an order
                -- SQLite is free to vary between runs.
                ORDER BY COALESCE(t.lastOpenedAt, t.importedAt) DESC, t.id DESC
            """)
            return rows.map { row in
                let count: Int = row["characterCount"]
                let offset: Int? = row["characterOffset"]
                return LibraryItem(
                    id: TextID(rawValue: row["id"]),
                    title: row["title"],
                    preview: row["preview"],
                    characterCount: count,
                    hasAudio: row["hasAudio"],
                    importedAt: row["importedAt"],
                    lastOpenedAt: row["lastOpenedAt"],
                    progress: offset.map { count > 0 ? min(1, Double($0) / Double(count)) : 0 },
                )
            }
        }
    }

    /// The body of one text. Fetched only when a text is opened.
    public func content(of id: TextID) async throws -> String? {
        try await dbQueue.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT content FROM text WHERE id = ?",
                arguments: [id.rawValue],
            )
        }
    }

    // MARK: - Writing

    /// Imports a text, or reports that its content is already in the library.
    public func importText(
        title: String,
        content: String,
        sourceName: String? = nil,
        now: Date = .now,
    ) async throws
        -> ImportOutcome
    {
        let hash = Data(SHA256.hash(data: Data(content.utf8)))
        return try await dbQueue.write { db in
            if let existing = try Int64.fetchOne(
                db,
                sql: "SELECT id FROM text WHERE contentHash = ?",
                arguments: [hash],
            ) {
                return .alreadyPresent(TextID(rawValue: existing))
            }
            try db.execute(sql: """
                INSERT INTO text
                    (title, content, contentHash, characterCount, preview, sourceName, importedAt)
                VALUES (?, ?, ?, ?, ?, ?, ?)
            """, arguments: [
                title, content, hash, content.utf16.count,
                Self.preview(of: content), sourceName, now,
            ])
            return .imported(TextID(rawValue: db.lastInsertedRowID))
        }
    }

    public func delete(_ id: TextID) async throws {
        // The cascade removes the audioTrack ROW, but nothing removes the file
        // it names -- so without this a deleted text leaves its audio on disk
        // forever, unreferenced and invisible.
        let orphanedAudio = try await audioTrack(for: id)?.relativePath

        // Position and revealed words go with the text via ON DELETE CASCADE,
        // which only works because foreign keys are enabled in the
        // configuration -- SQLite has them off by default.
        try await dbQueue.write { db in
            try db.execute(sql: "DELETE FROM text WHERE id = ?", arguments: [id.rawValue])
        }

        if let orphanedAudio, let directory = audioDirectory {
            try? FileManager.default.removeItem(
                at: directory.appendingPathComponent(orphanedAudio),
            )
        }
    }

    /// Clears a stored playhead. Separate from `save(_:)`, which deliberately
    /// preserves one it was not given.
    public func clearAudioTime(of id: TextID) async throws {
        try await dbQueue.write { db in
            try db.execute(
                sql: "UPDATE readingPosition SET audioTime = NULL WHERE textId = ?",
                arguments: [id.rawValue],
            )
        }
    }

    public func markOpened(_ id: TextID, at date: Date = .now) async throws {
        try await dbQueue.write { db in
            try db.execute(
                sql: "UPDATE text SET lastOpenedAt = ? WHERE id = ?",
                arguments: [date, id.rawValue],
            )
        }
    }

    // MARK: - Reading position

    public func position(of id: TextID) async throws -> ReadingPosition? {
        try await dbQueue.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM readingPosition WHERE textId = ?",
                arguments: [id.rawValue],
            ) else { return nil }
            return ReadingPosition(
                textID: id,
                blockIndex: row["blockIndex"],
                tokenIndex: row["tokenIndex"],
                characterOffset: row["characterOffset"],
                audioTime: row["audioTime"],
                updatedAt: row["updatedAt"],
            )
        }
    }

    public func save(_ position: ReadingPosition) async throws {
        try await dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO readingPosition
                    (textId, blockIndex, tokenIndex, characterOffset, audioTime, updatedAt)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(textId) DO UPDATE SET
                    blockIndex = excluded.blockIndex,
                    tokenIndex = excluded.tokenIndex,
                    characterOffset = excluded.characterOffset,
                    -- COALESCE, not a plain replace. The reader saves its
                    -- position constantly while scrolling and has no playhead
                    -- to supply, so assigning excluded.audioTime would clear
                    -- the one the audio player stored. Use clearAudioTime(of:)
                    -- to remove it deliberately.
                    audioTime = COALESCE(excluded.audioTime, readingPosition.audioTime),
                    updatedAt = excluded.updatedAt
            """, arguments: [
                position.textID.rawValue, position.blockIndex, position.tokenIndex,
                position.characterOffset, position.audioTime, position.updatedAt,
            ])
        }
    }

    // MARK: - Revealed words

    public func revealedWords(in id: TextID) async throws -> Set<String> {
        try await dbQueue.read { db in
            try Set(String.fetchAll(
                db,
                sql: "SELECT word FROM revealedWord WHERE textId = ?",
                arguments: [id.rawValue],
            ))
        }
    }

    /// One row, not a rewrite of the whole set.
    public func reveal(_ word: String, in id: TextID, at date: Date = .now) async throws {
        try await dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO revealedWord (textId, word, revealedAt) VALUES (?, ?, ?)
                ON CONFLICT(textId, word) DO NOTHING
            """, arguments: [id.rawValue, word, date])
        }
    }

    public func unreveal(_ word: String, in id: TextID) async throws {
        try await dbQueue.write { db in
            try db.execute(
                sql: "DELETE FROM revealedWord WHERE textId = ? AND word = ?",
                arguments: [id.rawValue, word],
            )
        }
    }

    public func clearRevealedWords(in id: TextID) async throws {
        try await dbQueue.write { db in
            try db.execute(
                sql: "DELETE FROM revealedWord WHERE textId = ?",
                arguments: [id.rawValue],
            )
        }
    }

    // MARK: - Audio

    public func attachAudio(_ track: AudioTrack) async throws {
        // Validated rather than trusted. An absolute path stores the container
        // UUID, and the resulting breakage only shows up after a restore --
        // long after the mistake, and far from it.
        guard !track.relativePath.hasPrefix("/"), !track.relativePath.contains("..") else {
            throw LibraryError.audioPathMustBeRelative(track.relativePath)
        }
        try await dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO audioTrack (textId, relativePath, duration, importedAt)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(textId) DO UPDATE SET
                    relativePath = excluded.relativePath,
                    duration = excluded.duration,
                    importedAt = excluded.importedAt
            """, arguments: [
                track.textID.rawValue, track.relativePath, track.duration, track.importedAt,
            ])
        }
    }

    public func audioTrack(for id: TextID) async throws -> AudioTrack? {
        try await dbQueue.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM audioTrack WHERE textId = ?",
                arguments: [id.rawValue],
            ) else { return nil }
            return AudioTrack(
                textID: id,
                relativePath: row["relativePath"],
                duration: row["duration"],
                importedAt: row["importedAt"],
            )
        }
    }

    // MARK: - Helpers

    /// The stored preview. Taken by character so a multi-byte script is not
    /// cut mid-character, and collapsed so newlines do not render as gaps.
    /// Scans only as far as it needs to.
    ///
    /// The obvious implementation -- trim, split, join, then take a prefix --
    /// allocates intermediates proportional to the *whole document* in order
    /// to produce 120 characters. For a novel that is tens of megabytes of
    /// garbage per import.
    static func preview(of content: String, limit: Int = 120) -> String {
        var out = ""
        out.reserveCapacity(limit)
        var pendingSpace = false

        for character in content {
            if character.isWhitespace {
                // Leading whitespace is dropped; interior runs collapse to one
                // space, emitted only once something follows.
                pendingSpace = !out.isEmpty
                continue
            }
            if pendingSpace {
                out.append(" ")
                pendingSpace = false
                if out.count == limit {
                    return out
                }
            }
            out.append(character)
            if out.count == limit {
                return out
            }
        }
        return out
    }
}

/// Things the library can refuse to do.
public enum LibraryError: Error, Sendable, Equatable, LocalizedError {
    /// An audio path must be relative to the audio directory; an absolute one
    /// embeds a container location that does not survive a restore.
    case audioPathMustBeRelative(String)

    public var errorDescription: String? {
        switch self {
        case let .audioPathMustBeRelative(path):
            "Audio must be stored as a path relative to the audio directory, but got \(path)."
        }
    }
}
