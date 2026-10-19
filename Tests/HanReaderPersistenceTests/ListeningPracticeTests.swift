// HanReader — MIT licensed. See LICENSE.

import Foundation
import GRDB
import HanReaderCore
import Testing
@testable import HanReaderPersistence

@Suite("Listening practice storage")
struct ListeningPracticeTests {
    private func library() throws -> LibraryRepository {
        try LibraryRepository.inMemory()
    }

    private func text(in library: LibraryRepository) async throws -> TextID {
        switch try await library.importText(
            title: "听力64",
            content: "山村的孩子需要他。我在一个山村学校当老师,教学任务很重。",
        ) {
        case let .imported(id): id
        case let .alreadyPresent(id): id
        }
    }

    private func phrase(_ index: Int, _ start: Double, _ end: Double) -> Phrase {
        Phrase(
            index: index,
            start: start,
            end: end,
            textRange: (index * 10) ..< (index * 10 + 9),
            confidence: 0.9,
        )
    }

    // MARK: - Phrases

    @Test("Phrases round-trip in order")
    func roundTrip() async throws {
        let library = try library()
        let id = try await text(in: library)
        try await library.savePhrases([phrase(0, 0, 4), phrase(1, 4, 9.5)], for: id)

        let stored = try await library.phrases(for: id)
        #expect(stored.map(\.index) == [0, 1])
        #expect(stored.first?.start == 0)
        #expect(stored.first?.end == 4)
        #expect(stored.last?.duration == 5.5)
        #expect(stored.first?.textRange == 0 ..< 9)
        #expect(stored.allSatisfy { $0.origin == .recognised })
        #expect(stored.allSatisfy { $0.grade == nil })
    }

    /// Phrases are positional. A half-written set is not a shorter set, it is
    /// a set whose indices no longer mean what the attempts recorded against
    /// them mean — so saving replaces the lot.
    @Test("Saving replaces the previous set rather than adding to it")
    func savingReplaces() async throws {
        let library = try library()
        let id = try await text(in: library)
        try await library.savePhrases([phrase(0, 0, 4), phrase(1, 4, 9)], for: id)
        try await library.savePhrases([phrase(0, 0, 9)], for: id)

        let stored = try await library.phrases(for: id)
        #expect(stored.count == 1)
        #expect(stored.first?.end == 9)
    }

    /// Re-aligning a recording usually moves boundaries by fractions of a
    /// second. Throwing away what the reader has already mastered would make
    /// fixing one boundary cost them the whole text.
    @Test("Re-aligning keeps attempts whose phrase still covers the same text")
    func realigningKeepsAttempts() async throws {
        let library = try library()
        let id = try await text(in: library)
        try await library.savePhrases([phrase(0, 0, 4)], for: id)
        try await library.recordAttempt("山村的孩子需要他", accuracy: 1, at: 0, in: id)

        try await library.savePhrases([phrase(0, 0, 4.2)], for: id)
        #expect(try await library.attempts(for: id)[0]?.accuracy == 1)
    }

    /// Review finding: attempts are keyed by index and phrases are
    /// positional, so re-aligning into a different number of phrases handed
    /// an earlier answer to whatever landed on that index — marking a phrase
    /// the reader has never seen as already passed.
    @Test("Re-aligning drops attempts whose phrase no longer covers that text")
    func realigningDropsStaleAttempts() async throws {
        let library = try library()
        let id = try await text(in: library)
        try await library.savePhrases([phrase(0, 0, 4), phrase(1, 4, 9)], for: id)
        try await library.recordAttempt("第一句", accuracy: 1, at: 0, in: id)
        try await library.recordAttempt("第二句", accuracy: 1, at: 1, in: id)

        // A re-alignment that split the first phrase in two: index 1 now
        // covers different words entirely.
        let resplit = [
            Phrase(index: 0, start: 0, end: 2, textRange: 0 ..< 9),
            Phrase(index: 1, start: 2, end: 4, textRange: 9 ..< 14),
            Phrase(index: 2, start: 4, end: 9, textRange: 10 ..< 19),
        ]
        try await library.savePhrases(resplit, for: id)

        let attempts = try await library.attempts(for: id)
        // Index 0 still covers 0..<9, so its answer still means something.
        #expect(attempts[0]?.typed == "第一句")
        // Index 1 covers different words now, so its answer is gone.
        #expect(attempts[1] == nil)
        #expect(attempts[2] == nil)
    }

    /// Review finding: `movePhrase` marks a boundary `manual` precisely so a
    /// later re-alignment can leave it alone — but saving replaced it with
    /// the recogniser's, so the reader would fix the same boundary for ever.
    @Test("Re-aligning keeps a boundary somebody dragged")
    func realigningKeepsManualBoundaries() async throws {
        let library = try library()
        let id = try await text(in: library)
        try await library.savePhrases([phrase(0, 0, 4), phrase(1, 4, 9)], for: id)
        try await library.movePhrase(0, in: id, start: 0.4, end: 3.6)

        // The recogniser runs again and offers its own times for the same
        // words.
        try await library.savePhrases([phrase(0, 0, 4), phrase(1, 4, 9)], for: id)

        let stored = try await library.phrases(for: id)
        #expect(stored.first?.start == 0.4)
        #expect(stored.first?.end == 3.6)
        #expect(stored.first?.origin == .manual)
        // The one nobody touched takes the new times.
        #expect(stored.last?.start == 4)
        #expect(stored.last?.origin == .recognised)
    }

    /// But only for the same words. A correction is about where a particular
    /// phrase begins; re-splitting the text makes it meaningless.
    @Test("A correction does not follow text it was not made for")
    func correctionsDoNotFollowDifferentText() async throws {
        let library = try library()
        let id = try await text(in: library)
        try await library.savePhrases([phrase(0, 0, 4)], for: id)
        try await library.movePhrase(0, in: id, start: 0.4, end: 3.6)

        try await library.savePhrases(
            [Phrase(index: 0, start: 0, end: 4, textRange: 100 ..< 120)],
            for: id,
        )
        let stored = try #require(try await library.phrases(for: id).first)
        #expect(stored.start == 0)
        #expect(stored.origin == .recognised)
    }

    @Test("A text with no phrases reports as much without fetching them")
    func hasPhrases() async throws {
        let library = try library()
        let id = try await text(in: library)
        #expect(try await library.hasPhrases(for: id) == false)
        try await library.savePhrases([phrase(0, 0, 4)], for: id)
        #expect(try await library.hasPhrases(for: id) == true)
    }

    /// A boundary somebody dragged into place must be distinguishable, so a
    /// later re-alignment can leave it alone.
    @Test("Moving a boundary records that a person did it")
    func movingMarksManual() async throws {
        let library = try library()
        let id = try await text(in: library)
        try await library.savePhrases([phrase(0, 0, 4)], for: id)
        try await library.movePhrase(0, in: id, start: 0.5, end: 4.5)

        let stored = try #require(try await library.phrases(for: id).first)
        #expect(stored.start == 0.5)
        #expect(stored.end == 4.5)
        #expect(stored.origin == .manual)
        // And only the times moved: dragging a waveform handle says nothing
        // about which words belong to the phrase.
        #expect(stored.textRange == 0 ..< 9)
    }

    @Test("A grade is stored and can be taken back")
    func grading() async throws {
        let library = try library()
        let id = try await text(in: library)
        try await library.savePhrases([phrase(0, 0, 4)], for: id)

        try await library.gradePhrase(0, in: id, as: .hard)
        #expect(try await library.phrases(for: id).first?.grade == .hard)
        try await library.gradePhrase(0, in: id, as: nil)
        #expect(try await library.phrases(for: id).first?.grade == nil)
    }

    /// A row written by a later version of the app is not a reason to refuse
    /// a reader their own library. The unknown value degrades to the default
    /// rather than throwing out of the read.
    @Test("An unknown origin reads back as recognised rather than failing")
    func unknownOriginDegrades() async throws {
        let library = try library()
        let id = try await text(in: library)
        try await library.savePhrases([phrase(0, 0, 4)], for: id)
        try await library.dbQueue.write { db in
            try db.execute(
                sql: "UPDATE phrase SET origin = 'from-a-later-version' WHERE textId = ?",
                arguments: [id.rawValue],
            )
        }
        #expect(try await library.phrases(for: id).first?.origin == .recognised)
    }

    // MARK: - Attempts

    @Test("An attempt is counted against the ones before it")
    func attemptsAccumulate() async throws {
        let library = try library()
        let id = try await text(in: library)
        try await library.savePhrases([phrase(0, 0, 4)], for: id)

        try await library.recordAttempt("山村", accuracy: 0.25, at: 0, in: id)
        try await library.recordAttempt("山村的孩", accuracy: 0.5, at: 0, in: id)
        try await library.recordAttempt("山村的孩子需要他", accuracy: 1, at: 0, in: id)

        let attempt = try #require(try await library.attempts(for: id)[0])
        #expect(attempt.attempts == 3)
        // The latest, not the best: what a learner wants to know is whether
        // they have it now.
        #expect(attempt.accuracy == 1)
        #expect(attempt.typed == "山村的孩子需要他")
        #expect(attempt.isPassing())
    }

    @Test("Attempts are keyed per phrase")
    func attemptsArePerPhrase() async throws {
        let library = try library()
        let id = try await text(in: library)
        try await library.savePhrases([phrase(0, 0, 4), phrase(1, 4, 9)], for: id)

        try await library.recordAttempt("一", accuracy: 0.5, at: 0, in: id)
        try await library.recordAttempt("二", accuracy: 1, at: 1, in: id)

        let attempts = try await library.attempts(for: id)
        #expect(attempts.count == 2)
        #expect(attempts[0]?.accuracy == 0.5)
        #expect(attempts[1]?.accuracy == 1)
    }

    @Test("Forgetting a text's practice clears both tables")
    func forgetting() async throws {
        let library = try library()
        let id = try await text(in: library)
        try await library.savePhrases([phrase(0, 0, 4)], for: id)
        try await library.recordAttempt("山村", accuracy: 0.5, at: 0, in: id)

        try await library.forgetPhrases(for: id)
        #expect(try await library.phrases(for: id).isEmpty)
        #expect(try await library.attempts(for: id).isEmpty)
    }

    /// Both tables cascade from the text, so deleting it cannot leave rows
    /// pointing at nothing. The prototype deleted progress by hand and leaked
    /// its audio rows entirely.
    @Test("Deleting a text takes its practice with it")
    func deletionCascades() async throws {
        let library = try library()
        let id = try await text(in: library)
        try await library.savePhrases([phrase(0, 0, 4)], for: id)
        try await library.recordAttempt("山村", accuracy: 0.5, at: 0, in: id)

        try await library.delete(id)
        #expect(try await library.phrases(for: id).isEmpty)
        #expect(try await library.attempts(for: id).isEmpty)
    }
}
