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
        guard !band.exceedsBudget
        else { return trivial(reference: reference, candidate: candidate) }
        let moves = fill(reference: reference, candidate: candidate, band: band)
        return backtrace(moves: moves, band: band)
    }

    /// Nothing matched: every reference element missing, every candidate
    /// element invented.
    ///
    /// A real alignment of two sequences this mismatched would say very
    /// nearly this anyway, so it is the shape of the answer rather than a
    /// refusal to answer. Forced alignment reads the resulting confidence of
    /// zero and falls back to asking the reader.
    private static func trivial(
        reference: [Character],
        candidate: [Character],
    )
        -> [AlignmentStep]
    {
        reference.indices.map {
            AlignmentStep(operation: .delete, reference: $0, candidate: nil)
        } + candidate.indices.map {
            AlignmentStep(operation: .insert, reference: nil, candidate: $0)
        }
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
            //
            // It is also what makes the band dangerous, which is the point
            // of the clamp below. Speech recognition that gave up on a long
            // recording produces exactly the degenerate shape — thousands of
            // transcript characters against a handful of recognised ones —
            // and the band would then be as wide as the transcript, turning
            // this from O(n × band) back into O(n²). On a book that is
            // hundreds of megabytes for an alignment whose answer is "almost
            // all of it is missing".
            band = max(1, abs(rows - columns) + max(0, slack))
            width = 2 * band + 1
        }

        /// Whether computing this band would cost more memory than the
        /// answer is worth.
        ///
        /// The band cannot simply be clamped: it has to be at least the
        /// difference in length or a row past the end of the shorter
        /// sequence has a lower bound above its upper bound, and the path
        /// from one corner to the other no longer fits inside it. So the
        /// choice is to spend the memory or to decline, and for a pair this
        /// mismatched there is no good alignment to find — the honest answer
        /// is that almost none of it lines up, which is what the trivial
        /// alignment says for nothing.
        var exceedsBudget: Bool {
            band > Self.maximumBand || cellCount > Self.maximumCells
        }

        /// One byte a cell, since only the moves are kept. 64 MB is far
        /// more than any real alignment needs — a two-minute exercise uses a
        /// ten-thousandth of it, and an hour-long chapter against its own
        /// transcript about a hundredth.
        static let maximumCells = 64_000_000

        /// And a width beyond which the two sequences are not variants of
        /// each other at all.
        ///
        /// The band has to span the difference in length, so a band this
        /// wide means thousands of characters appear on one side and not the
        /// other — speech recognition that gave up, not a transcript with
        /// mistakes in it.
        static let maximumBand = 4096

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

    /// Fills the matrix, keeping only the move that produced each cell.
    ///
    /// Costs are kept for **two rows**, not the whole matrix: a cell depends
    /// only on the row above it and the cell to its left, so the rest is
    /// dead weight. Only the moves have to survive, and a move is one byte —
    /// so the backtrace costs a fifth of what holding the costs as well
    /// would, and an audiobook chapter against its own transcript fits in
    /// single-digit megabytes.
    private static func fill(
        reference: [Character],
        candidate: [Character],
        band: Band,
    )
        -> [UInt8]
    {
        let unreachable = Int32.max / 4
        var moves = [UInt8](repeating: 0, count: band.cellCount)
        var previous = [Int32](repeating: unreachable, count: band.width)
        var current = [Int32](repeating: unreachable, count: band.width)

        for row in 0 ... band.rows {
            let lower = band.lowerBound(row)
            let upper = band.upperBound(row)
            let previousLower = row > 0 ? band.lowerBound(row - 1) : 0
            let previousUpper = row > 0 ? band.upperBound(row - 1) : -1

            // No clearing between rows. Every offset this row reads is one
            // it has already written: the loop writes `lower ... upper` in
            // order, and `left` only looks at columns before the current
            // one. A reset would be a wide array cleared per row for cells
            // nothing looks at.
            for column in lower ... upper {
                let offset = column - lower
                if row == 0, column == 0 {
                    current[offset] = 0
                    continue
                }
                // The row above, where it exists and reaches this column.
                func above(_ target: Int) -> Int32 {
                    guard row > 0, target >= previousLower, target <= previousUpper else {
                        return unreachable
                    }
                    return previous[target - previousLower]
                }
                // The cell to the left, which this loop has already written.
                func left(_ target: Int) -> Int32 {
                    guard target >= lower, target < column else { return unreachable }
                    return current[target - lower]
                }

                let same = row > 0 && column > 0 && reference[row - 1] == candidate[column - 1]
                var best = above(column - 1) + (same ? 0 : 1)
                var move = same ? AlignmentOperation.match : .substitute
                if above(column) + 1 < best {
                    best = above(column) + 1
                    move = .delete
                }
                if left(column - 1) + 1 < best {
                    best = left(column - 1) + 1
                    move = .insert
                }
                current[offset] = best
                if let slot = band.slot(row, column) {
                    moves[slot] = move.rawValue
                }
            }
            swap(&previous, &current)
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
