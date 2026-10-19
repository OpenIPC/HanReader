// HanReader — MIT licensed. See LICENSE.

import Foundation

/// What happened to one position when two sequences were lined up.
public enum AlignmentOperation: UInt8, Sendable, Hashable, CaseIterable {
    /// The same element in both.
    case match
    /// Different elements in the same place.
    case substitute
    /// Present in the candidate, absent from the reference.
    case insert
    /// Present in the reference, absent from the candidate.
    case delete
}

/// One position in a lined-up pair of sequences.
///
/// Per element rather than per run, because the two callers want different
/// things from it: scoring a dictation wants to say *what* each wrong
/// character was, and forced alignment wants to know which recognised element
/// a transcript character landed on so it can read its timestamp. Runs are a
/// presentation concern and are coalesced separately.
public struct AlignmentStep: Hashable, Sendable {
    public let operation: AlignmentOperation
    /// Index into the reference, or nil for an insertion.
    public let reference: Int?
    /// Index into the candidate, or nil for a deletion.
    public let candidate: Int?

    public init(operation: AlignmentOperation, reference: Int?, candidate: Int?) {
        self.operation = operation
        self.reference = reference
        self.candidate = candidate
    }
}

/// Lines up two sequences, element by element.
///
/// One implementation serves both halves of listening practice, which is the
/// main reason they are one milestone:
///
/// - **Scoring a dictation** lines up what the learner typed against the
///   transcript, so every character can be called right, wrong, missing or
///   extra.
/// - **Forced alignment** lines up what the speech recogniser heard against
///   the *same* transcript. The recogniser's mistakes do not matter: its
///   correct neighbours carry the timing across them, which is the whole
///   trick of aligning audio to a text you already have.
///
/// ### Banded, so an audiobook does not need a gigabyte
///
/// Plain Levenshtein backtracking needs the whole n×m matrix. Two minutes of
/// listening practice is 600 characters against 600 — a third of a megabyte,
/// nothing. A twenty-minute chapter is 6,000 against 6,000, which is 36 MB,
/// and an hour is over a gigabyte.
///
/// The two sequences being aligned are *nearly the same sequence*, though —
/// one is a transcript and the other is a recognition of the same speech, in
/// the same order. The true path therefore never strays far from the
/// diagonal, so only a band around it is computed. Memory becomes
/// O(n × band) rather than O(n × m).
///
/// A path that would stray outside the band is not found; what comes back
/// instead is the best path within it. That degrades the alignment rather
/// than failing it, which is the right trade for a feature whose boundaries
/// the reader can nudge anyway.
public enum SequenceAlignment {
    /// How far from the diagonal to look, beyond the sequences' difference in
    /// length. Generous: 128 characters of drift is already a recogniser
    /// having lost half a minute of speech, and the cost of the slack is
    /// linear.
    public static let defaultSlack = 128

    public static func align(
        reference: [Character],
        candidate: [Character],
        slack: Int = defaultSlack,
    )
        -> [AlignmentStep]
    {
        // Trivial cases answered directly. They are not just an optimisation:
        // the band arithmetic below assumes at least one row and column, and
        // an empty dictation attempt is the commonest input of all.
        guard !reference.isEmpty else {
            return candidate.indices.map {
                AlignmentStep(operation: .insert, reference: nil, candidate: $0)
            }
        }
        guard !candidate.isEmpty else {
            return reference.indices.map {
                AlignmentStep(operation: .delete, reference: $0, candidate: nil)
            }
        }

        let band = Band(rows: reference.count, columns: candidate.count, slack: slack)
        let moves = fill(reference: reference, candidate: candidate, band: band)
        return backtrace(moves: moves, band: band)
    }

    /// The band around the diagonal that is worth computing, and the
    /// arithmetic for addressing it.
    ///
    /// A type rather than three closures because both the fill and the
    /// backtrace need exactly the same bounds, and two copies of that
    /// arithmetic that drifted apart would produce an alignment that cannot
    /// be walked back.
    struct Band {
        let rows: Int
        let columns: Int
        let band: Int
        let width: Int

        init(rows: Int, columns: Int, slack: Int) {
            self.rows = rows
            self.columns = columns
            // The `abs` term is load-bearing, not padding: without it a row
            // past the end of the shorter sequence would have a lower bound
            // above its upper bound, and forming that range traps.
            band = max(1, abs(rows - columns) + max(0, slack))
            width = 2 * band + 1
        }

        func lowerBound(_ row: Int) -> Int {
            max(0, row - band)
        }

        func upperBound(_ row: Int) -> Int {
            min(columns, row + band)
        }

        func slot(_ row: Int, _ column: Int) -> Int? {
            guard column >= lowerBound(row), column <= upperBound(row) else { return nil }
            return row * width + (column - lowerBound(row))
        }

        var cellCount: Int {
            (rows + 1) * width
        }
    }

    /// Fills the cost matrix, keeping only the move that produced each cell.
    private static func fill(
        reference: [Character],
        candidate: [Character],
        band: Band,
    )
        -> [UInt8]
    {
        let unreachable = Int32.max / 4
        // Flat arrays rather than nested ones: this is the hot loop, and a
        // `[[Int32]]` is a row of pointers to heap allocations.
        var costs = [Int32](repeating: unreachable, count: band.cellCount)
        var moves = [UInt8](repeating: 0, count: band.cellCount)

        func cost(_ row: Int, _ column: Int) -> Int32 {
            guard row >= 0, column >= 0, let index = band.slot(row, column) else {
                return unreachable
            }
            return costs[index]
        }

        for row in 0 ... band.rows {
            for column in band.lowerBound(row) ... band.upperBound(row) {
                guard let index = band.slot(row, column) else { continue }
                if row == 0, column == 0 {
                    costs[index] = 0
                    continue
                }
                let same = row > 0 && column > 0 && reference[row - 1] == candidate[column - 1]
                var best = cost(row - 1, column - 1) + (same ? 0 : 1)
                var move = same ? AlignmentOperation.match : .substitute
                if cost(row - 1, column) + 1 < best {
                    best = cost(row - 1, column) + 1
                    move = .delete
                }
                if cost(row, column - 1) + 1 < best {
                    best = cost(row, column - 1) + 1
                    move = .insert
                }
                costs[index] = best
                moves[index] = move.rawValue
            }
        }
        return moves
    }

    /// Walks the recorded moves back from the end, then reverses, so the
    /// steps come out in reading order.
    private static func backtrace(moves: [UInt8], band: Band) -> [AlignmentStep] {
        var steps: [AlignmentStep] = []
        steps.reserveCapacity(max(band.rows, band.columns))
        var row = band.rows
        var column = band.columns

        while row > 0 || column > 0 {
            // Outside the band, or at an edge: the only move left is the one
            // that exists. Handling these explicitly keeps the loop total,
            // which matters because a non-terminating backtrace is an app
            // that hangs rather than one that scores badly.
            guard row > 0 else {
                steps.append(.init(operation: .insert, reference: nil, candidate: column - 1))
                column -= 1
                continue
            }
            guard column > 0 else {
                steps.append(.init(operation: .delete, reference: row - 1, candidate: nil))
                row -= 1
                continue
            }
            guard let index = band.slot(row, column),
                  let move = AlignmentOperation(rawValue: moves[index])
            else {
                steps.append(.init(operation: .delete, reference: row - 1, candidate: nil))
                row -= 1
                continue
            }
            switch move {
            case .match, .substitute:
                steps.append(.init(operation: move, reference: row - 1, candidate: column - 1))
                row -= 1
                column -= 1
            case .delete:
                steps.append(.init(operation: .delete, reference: row - 1, candidate: nil))
                row -= 1
            case .insert:
                steps.append(.init(operation: .insert, reference: nil, candidate: column - 1))
                column -= 1
            }
        }
        return steps.reversed()
    }
}
