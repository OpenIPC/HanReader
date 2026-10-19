// HanReader — MIT licensed. See LICENSE.

public import Foundation
internal import GRDB
import HanReaderCore

/// Brings a reader's texts across from the prototype.
///
/// The prototype wrote `library.db` beside where this app now writes
/// `library.sqlite`, so an existing user has one sitting next to the other.
/// It is small — a handful of texts — and migrating it is a one-off.
///
/// ### What comes across, and what does not
///
/// - **Texts** come across whole. Deduplicated on content by `importText`,
///   so running this twice cannot produce two copies of anything.
/// - **Revealed words** come across, split out of the newline-joined blob the
///   prototype packed them into. That blob is why the new schema has a
///   `revealedWord` table: a set stored as a string cannot be queried, cannot
///   be indexed, and silently corrupts the moment a word contains a newline.
/// - **`last_opened_at`** comes across, so the reader's most recent text is
///   still the one that opens.
/// - **`scroll_offset` is discarded, deliberately.** It is a pixel offset,
///   which is meaningless after a font-size change, a window resize, or a
///   move between a Mac and a phone — and the prototype never restored it
///   either. The new `readingPosition` is anchored to a character offset
///   instead, and there is no way to derive one from a pixel count.
/// - **`audio_path`** is an absolute path containing the app container's
///   UUID. It is followed if the file is still there and copied inside, which
///   is the fix; if it is not, the text comes across without its audio and
///   the outcome says so.
///
/// ### Running once
///
/// Marked by renaming the file rather than by a flag, so the state lives with
/// the thing it describes. The prototype's `UserDefaults.bool(forKey:
/// "dictionaryParsed_bkrs_v1")` is the counter-example: delete the database
/// and the flag still says it was parsed.
public enum PrototypeLibrary {
    /// What a migration did, for a report the reader can act on.
    public struct Outcome: Sendable, Equatable {
        public var texts = 0
        public var alreadyPresent = 0
        public var revealedWords = 0
        public var audioTracks = 0
        /// Things worth telling the reader — an audio file that was no longer
        /// where the prototype left it, a row that could not be read.
        public var notes: [String] = []

        public var isEmpty: Bool {
            texts == 0 && alreadyPresent == 0
        }
    }

    /// The prototype's database, beside the current one.
    public static func file(near library: URL) -> URL {
        library.deletingLastPathComponent().appendingPathComponent("library.db")
    }

    /// Where a migrated file is moved to, so it is kept rather than deleted —
    /// a reader whose migration went wrong still has their texts.
    public static func migratedFile(near library: URL) -> URL {
        library.deletingLastPathComponent().appendingPathComponent("library.db.migrated")
    }

    /// Migrates the prototype library if there is one, and returns nil if
    /// there is not.
    @discardableResult
    public static func migrateIfPresent(
        into repository: LibraryRepository,
        locations: AppDatabase.Locations,
    ) async throws
        -> Outcome?
    {
        let source = file(near: locations.library)
        guard FileManager.default.fileExists(atPath: source.path) else { return nil }

        let outcome = try await migrate(from: source, into: repository, locations: locations)
        // Moved only on success. A migration that threw must be able to run
        // again, or a transient failure costs the reader their library.
        try? FileManager.default.removeItem(at: migratedFile(near: locations.library))
        try FileManager.default.moveItem(at: source, to: migratedFile(near: locations.library))
        return outcome
    }

    static func migrate(
        from source: URL,
        into repository: LibraryRepository,
        locations: AppDatabase.Locations,
    ) async throws
        -> Outcome
    {
        let old = try openReadOnly(source)
        let texts = try await readTexts(from: old)
        let progress = try await readProgress(from: old)

        let run = Migration(repository: repository, locations: locations)
        var outcome = Outcome()
        let identifiers = try await run.importTexts(texts, into: &outcome)
        try await run.applyProgress(progress, identifiers: identifiers, into: &outcome)
        return outcome
    }

    /// Read-only: the prototype's file is the reader's only copy until the
    /// migration succeeds, and nothing here needs to write to it.
    private static func openReadOnly(_ source: URL) throws -> DatabaseQueue {
        var configuration = Configuration()
        configuration.readonly = true
        return try DatabaseQueue(path: source.path, configuration: configuration)
    }

    /// Projected to plain values inside the read. A GRDB `Row` is tied to its
    /// statement and is not `Sendable`, so carrying one across an `await` is
    /// both a compile error and, were it allowed, a dangling read.
    private static func readTexts(from old: DatabaseQueue) async throws -> [OldText] {
        try await old.read { db in
            try Row.fetchAll(db, sql: """
                SELECT id, title, content, audio_path FROM texts ORDER BY id
            """).map {
                OldText(
                    id: $0["id"],
                    title: $0["title"],
                    content: $0["content"],
                    audioPath: $0["audio_path"],
                )
            }
        }
    }

    private static func readProgress(from old: DatabaseQueue) async throws -> [OldProgress] {
        try await old.read { db in
            try Row.fetchAll(db, sql: """
                SELECT text_id, revealed_words, last_opened_at FROM reading_progress
            """).map {
                OldProgress(
                    textID: $0["text_id"],
                    revealedWords: $0["revealed_words"] ?? "",
                    lastOpenedAt: $0["last_opened_at"],
                )
            }
        }
    }
}

/// One migration run, holding what every step needs.
///
/// A type rather than six parameters threaded through four functions —
/// which is what it was, until the destination and the repository had to
/// reach the audio step as well.
private struct Migration {
    let repository: LibraryRepository
    let locations: AppDatabase.Locations

    /// - Returns: old row id to new `TextID`, so the progress rows can find
    ///   the text they belong to.
    func importTexts(
        _ texts: [OldText],
        into outcome: inout PrototypeLibrary.Outcome,
    ) async throws
        -> [Int64: TextID]
    {
        var identifiers: [Int64: TextID] = [:]
        for text in texts {
            guard let title = text.title, let content = text.content, let oldID = text.id else {
                outcome.notes.append("A text could not be read and was skipped.")
                continue
            }
            let result = try await repository.importText(
                title: title,
                content: content,
                sourceName: "HanReader (prototype)",
            )
            switch result {
            case let .imported(id):
                identifiers[oldID] = id
                outcome.texts += 1
            case let .alreadyPresent(id):
                identifiers[oldID] = id
                outcome.alreadyPresent += 1
            }
            if let path = text.audioPath, let id = identifiers[oldID] {
                try await carryAudio(from: path, for: id, title: title, into: &outcome)
            }
        }
        return identifiers
    }

    func applyProgress(
        _ progress: [OldProgress],
        identifiers: [Int64: TextID],
        into outcome: inout PrototypeLibrary.Outcome,
    ) async throws {
        for row in progress {
            guard let oldID = row.textID, let id = identifiers[oldID] else { continue }
            // Split on newlines, which is the whole of undoing the blob —
            // and the empty entries are filtered because an empty set was
            // stored as an empty string, which splits into one empty word.
            for word in row.revealedWords.split(separator: "\n") where !word.isEmpty {
                try await repository.reveal(String(word), in: id)
                outcome.revealedWords += 1
            }
            if let opened = row.lastOpenedAt {
                try await repository.markOpened(id, at: Date(timeIntervalSince1970: opened))
            }
        }
    }

    /// Follows an absolute audio path and copies the file inside, if it is
    /// still where the prototype left it.
    private func carryAudio(
        from path: String,
        for id: TextID,
        title: String,
        into outcome: inout PrototypeLibrary.Outcome,
    ) async throws {
        let original = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: original.path) else {
            // The failure the relative-path rule exists to prevent, met here
            // as history rather than as a bug: the container moved and the
            // stored path no longer points at anything.
            outcome.notes
                .append(
                    "The audio for \u{201C}\(title)\u{201D} was not where the old version left it.",
                )
            return
        }
        try FileManager.default.createDirectory(
            at: locations.audio,
            withIntermediateDirectories: true,
        )
        let name = "text-\(id.rawValue).\(original.pathExtension.lowercased())"
        let destination = locations.audio.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: original, to: destination)
        try await repository.attachAudio(AudioTrack(
            textID: id,
            relativePath: name,
            duration: nil,
            importedAt: Date(),
        ))
        outcome.audioTracks += 1
    }
}

/// One row of the prototype's `texts` table, as plain values.
///
/// Optional throughout rather than trusted: this is a file written by a
/// previous version of the app, possibly years ago, and a migration that
/// traps on a null is a migration that loses the whole library over one bad
/// row.
private struct OldText: Sendable {
    let id: Int64?
    let title: String?
    let content: String?
    let audioPath: String?
}

private struct OldProgress: Sendable {
    let textID: Int64?
    let revealedWords: String
    let lastOpenedAt: Double?
}
