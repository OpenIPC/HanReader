// HanReader — MIT licensed. See LICENSE.

public import Foundation
internal import GRDB
public import HanReaderCore

/// Listening practice: the phrases a recording was cut into, and how the
/// reader has done at each.
///
/// Split out for the same reason as the audio section above — one coherent
/// concern, arriving whole in M11, and the repository's own body is long
/// enough already.
extension LibraryRepository {
    /// Replaces a text's phrases wholesale.
    ///
    /// All or nothing, in one transaction. Phrases are positional: a half-
    /// written set is not a shorter set, it is a set whose indices no longer
    /// mean what the attempts recorded against them mean.
    ///
    /// Attempts are deliberately **not** cleared. Re-aligning a recording
    /// usually moves boundaries by fractions of a second, and throwing away
    /// the reader's record of what they have already mastered would make
    /// fixing one boundary cost them the whole text.
    public func savePhrases(_ phrases: [Phrase], for id: TextID) async throws {
        try await dbQueue.write { db in
            try db.execute(sql: "DELETE FROM phrase WHERE textId = ?", arguments: [id.rawValue])
            for phrase in phrases {
                try db.execute(sql: """
                    INSERT INTO phrase
                        (textId, idx, startTime, endTime, textStart, textEnd,
                         confidence, origin, grade)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [
                    id.rawValue, phrase.index, phrase.start, phrase.end,
                    phrase.textRange.lowerBound, phrase.textRange.upperBound,
                    phrase.confidence, phrase.origin.rawValue, phrase.grade?.rawValue,
                ])
            }
        }
    }

    public func phrases(for id: TextID) async throws -> [Phrase] {
        try await dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT idx, startTime, endTime, textStart, textEnd, confidence, origin, grade
                    FROM phrase WHERE textId = ? ORDER BY idx
                """,
                arguments: [id.rawValue],
            ).map { row in
                Phrase(
                    index: row["idx"],
                    start: row["startTime"],
                    end: row["endTime"],
                    textRange: (row["textStart"] as Int) ..< (row["textEnd"] as Int),
                    confidence: row["confidence"],
                    // An unknown value becomes `.recognised` rather than
                    // failing the read. A row written by a later version is
                    // not a reason to refuse a reader their own library.
                    origin: PhraseOrigin(rawValue: row["origin"] ?? "") ?? .recognised,
                    grade: (row["grade"] as String?).flatMap(PhraseGrade.init(rawValue:)),
                )
            }
        }
    }

    public func hasPhrases(for id: TextID) async throws -> Bool {
        try await dbQueue.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM phrase WHERE textId = ?",
                arguments: [id.rawValue],
            ) ?? 0 > 0
        }
    }

    /// Moves one phrase's boundaries, and records that a person did it.
    ///
    /// Marked `manual` so a later re-alignment can leave it alone. Only the
    /// times change: dragging a boundary in the waveform says nothing about
    /// which words belong to the phrase.
    public func movePhrase(
        _ index: Int,
        in id: TextID,
        start: Double,
        end: Double,
    ) async throws {
        try await dbQueue.write { db in
            try db.execute(sql: """
                UPDATE phrase SET startTime = ?, endTime = ?, origin = ?
                WHERE textId = ? AND idx = ?
            """, arguments: [start, end, PhraseOrigin.manual.rawValue, id.rawValue, index])
        }
    }

    public func gradePhrase(
        _ index: Int,
        in id: TextID,
        as grade: PhraseGrade?,
    ) async throws {
        try await dbQueue.write { db in
            try db.execute(
                sql: "UPDATE phrase SET grade = ? WHERE textId = ? AND idx = ?",
                arguments: [grade?.rawValue, id.rawValue, index],
            )
        }
    }

    public func forgetPhrases(for id: TextID) async throws {
        try await dbQueue.write { db in
            try db.execute(sql: "DELETE FROM phrase WHERE textId = ?", arguments: [id.rawValue])
            try db.execute(
                sql: "DELETE FROM dictationAttempt WHERE textId = ?",
                arguments: [id.rawValue],
            )
        }
    }

    // MARK: - Attempts

    /// Records an attempt, counting it against however many came before.
    ///
    /// The count is incremented in SQL rather than read and written back: two
    /// quick attempts would otherwise race and record one.
    public func recordAttempt(
        _ typed: String,
        accuracy: Double,
        at index: Int,
        in id: TextID,
        now: Date = .now,
    ) async throws {
        try await dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO dictationAttempt (textId, idx, typed, accuracy, attempts, updatedAt)
                VALUES (?, ?, ?, ?, 1, ?)
                ON CONFLICT(textId, idx) DO UPDATE SET
                    typed = excluded.typed,
                    accuracy = excluded.accuracy,
                    attempts = dictationAttempt.attempts + 1,
                    updatedAt = excluded.updatedAt
            """, arguments: [id.rawValue, index, typed, accuracy, now])
        }
    }

    public func attempts(for id: TextID) async throws -> [Int: DictationAttempt] {
        try await dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT idx, typed, accuracy, attempts, updatedAt
                    FROM dictationAttempt WHERE textId = ?
                """,
                arguments: [id.rawValue],
            ).reduce(into: [:]) { result, row in
                let index: Int = row["idx"]
                result[index] = DictationAttempt(
                    phraseIndex: index,
                    typed: row["typed"],
                    accuracy: row["accuracy"],
                    attempts: row["attempts"],
                    updatedAt: row["updatedAt"],
                )
            }
        }
    }
}
