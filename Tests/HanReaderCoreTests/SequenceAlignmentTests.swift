// HanReader — MIT licensed. See LICENSE.

import Testing
@testable import HanReaderCore

/// The classic full-matrix edit distance, written out plainly.
///
/// A second implementation on purpose: the real one is banded and hard to
/// eyeball, and "the banded answer equals the textbook answer" is the only
/// check that actually pins it.
private func textbookDistance(_ reference: [Character], _ candidate: [Character]) -> Int {
    var previous = Array(0 ... candidate.count)
    var current = [Int](repeating: 0, count: candidate.count + 1)
    for row in 1 ... max(reference.count, 1) where !reference.isEmpty {
        current[0] = row
        for column in 1 ... max(candidate.count, 1) where !candidate.isEmpty {
            let same = reference[row - 1] == candidate[column - 1]
            current[column] = min(
                previous[column] + 1,
                current[column - 1] + 1,
                previous[column - 1] + (same ? 0 : 1),
            )
        }
        if candidate.isEmpty {
            current[0] = row
        }
        previous = current
    }
    if reference.isEmpty {
        return candidate.count
    }
    if candidate.isEmpty {
        return reference.count
    }
    return previous[candidate.count]
}

private func distance(_ steps: [AlignmentStep]) -> Int {
    steps.count { $0.operation != .match }
}

private func align(_ reference: String, _ candidate: String, slack: Int = 128) -> [AlignmentStep] {
    SequenceAlignment.align(
        reference: Array(reference),
        candidate: Array(candidate),
        slack: slack,
    )
}

@Suite("Sequence alignment")
struct SequenceAlignmentTests {
    // MARK: - The invariant everything else rests on

    /// Both sequences are covered exactly once, in order, with nothing
    /// invented and nothing dropped.
    ///
    /// The same shape of property test as the token tiling one: a scorer
    /// built on an alignment that skipped a character would report an
    /// accuracy that is simply wrong, and no example-based test reliably
    /// catches an off-by-one at a band edge.
    @Test(
        "Every element of both sequences is covered exactly once",
        arguments: [
            ("卖主是位六十多岁的老太太", "卖主是为六十多岁的老太太"),
            ("我在一个山村学校当老师", "我在山村学校当老师"),
            ("短", "很长很长很长的一句话"),
            ("很长很长很长的一句话", "短"),
            ("", "abc"),
            ("abc", ""),
            ("", ""),
            ("aaaa", "aaaa"),
        ],
    )
    func coversBothSequences(reference: String, candidate: String) {
        let referenceCharacters = Array(reference)
        let candidateCharacters = Array(candidate)
        let steps = align(reference, candidate)

        let referenceIndices = steps.compactMap(\.reference)
        let candidateIndices = steps.compactMap(\.candidate)

        #expect(referenceIndices == Array(referenceCharacters.indices))
        #expect(candidateIndices == Array(candidateCharacters.indices))

        // And the operations agree with the indices they carry.
        for step in steps {
            switch step.operation {
            case .match, .substitute:
                #expect(step.reference != nil && step.candidate != nil)
            case .insert:
                #expect(step.reference == nil && step.candidate != nil)
            case .delete:
                #expect(step.reference != nil && step.candidate == nil)
            }
        }
    }

    /// A match must actually be a match. Nothing downstream re-checks this,
    /// so an alignment that labelled a substitution as a match would score a
    /// wrong answer as right.
    @Test("A step labelled match holds equal elements")
    func matchesAreEqual() {
        let reference = Array("卖主是位六十多岁的老太太")
        let candidate = Array("卖主是为六十多岁的老太太")
        for step in SequenceAlignment.align(reference: reference, candidate: candidate) {
            guard let left = step.reference, let right = step.candidate else { continue }
            if step.operation == .match {
                #expect(reference[left] == candidate[right])
            } else {
                #expect(reference[left] != candidate[right])
            }
        }
    }

    // MARK: - Against the textbook

    @Test(
        "The banded distance equals the full-matrix distance",
        arguments: [
            ("卖主是位六十多岁的老太太", "卖主是为六十多岁的老太太"),
            ("我在一个山村学校当老师", "我在山村学校当老师"),
            ("教学任务很重", "教学任务很重"),
            ("kitten", "sitting"),
            ("flaw", "lawn"),
            ("", "non-empty"),
            ("non-empty", ""),
        ],
    )
    func matchesTextbookDistance(reference: String, candidate: String) {
        let steps = align(reference, candidate)
        #expect(distance(steps) == textbookDistance(Array(reference), Array(candidate)))
    }

    // MARK: - Shapes the callers depend on

    @Test("Identical sequences are all matches")
    func identical() {
        let steps = align("卖主是位六十多岁的老太太", "卖主是位六十多岁的老太太")
        #expect(steps.allSatisfy { $0.operation == .match })
        #expect(steps.count == 12)
    }

    /// What a learner typing one wrong character produces, and the case the
    /// homophone tier is built on top of.
    @Test("One wrong character is a substitution, not a delete and an insert")
    func oneSubstitution() {
        let steps = align("是位", "事位")
        #expect(steps.map(\.operation) == [.substitute, .match])
    }

    @Test("A missing character is a deletion")
    func oneDeletion() {
        let steps = align("一个人", "一人")
        #expect(steps.count(where: { $0.operation == .delete }) == 1)
        #expect(steps.count(where: { $0.operation == .match }) == 2)
    }

    @Test("An extra character is an insertion")
    func oneInsertion() {
        let steps = align("一人", "一个人")
        #expect(steps.count(where: { $0.operation == .insert }) == 1)
        #expect(steps.count(where: { $0.operation == .match }) == 2)
    }

    @Test("Two empty sequences produce no steps")
    func bothEmpty() {
        #expect(align("", "").isEmpty)
    }

    // MARK: - The band

    /// The band is what keeps an hour-long recording from needing a gigabyte.
    /// Inside it the answer must be exact, which is the case that matters:
    /// a dictation attempt is tens of characters and can never approach it.
    @Test("A narrow band still gives the exact answer for nearby sequences")
    func narrowBandIsExactWhenTheDriftIsSmall() {
        let reference = "卖主是位六十多岁的老太太她叫我给个价我就说五角钱一个"
        let candidate = "卖主是为六十多岁的老太太她叫我给个假我就说五角钱一个"
        let wide = align(reference, candidate, slack: 128)
        let narrow = align(reference, candidate, slack: 2)
        #expect(distance(narrow) == distance(wide))
        #expect(distance(narrow) == 2)
    }

    /// And when the true path *would* leave the band, the result is still a
    /// complete, well-formed alignment — worse, but not broken. A backtrace
    /// that could not reach the origin would hang the app rather than score
    /// badly, which is why this is a test and not a comment.
    @Test("A path that leaves the band still produces a total alignment")
    func narrowBandStillTerminates() {
        let reference = String(repeating: "甲", count: 200) + "乙丙丁"
        let candidate = "乙丙丁" + String(repeating: "甲", count: 200)
        let steps = SequenceAlignment.align(
            reference: Array(reference),
            candidate: Array(candidate),
            slack: 1,
        )
        #expect(steps.compactMap(\.reference) == Array(0 ..< reference.count))
        #expect(steps.compactMap(\.candidate) == Array(0 ..< candidate.count))
    }

    /// With no slack asked for, the band is still kept at one — enough to
    /// see a single dropped character paired with a single added one.
    ///
    /// These two are the same length, so a band of zero would explore only
    /// the diagonal and call it three substitutions. It is two: drop 甲, keep
    /// 乙丙, add 丁. Identical sequences would not have shown the difference,
    /// which is what this test originally used and why it proved nothing.
    /// Review finding: the band widens by the difference in length, so a
    /// long transcript against a near-empty recognition — speech recognition
    /// that gave up — made the band as wide as the transcript and the
    /// matrices quadratic. 6,000 characters against 3 would have been
    /// hundreds of megabytes for an answer that is "almost all of it is
    /// missing".
    @Test("A wildly mismatched pair is declined rather than paid for")
    func degenerateLengthsAreDeclined() {
        let rows = 6000
        let band = SequenceAlignment.Band(rows: rows, columns: 3, slack: 128)
        // The band cannot be narrowed — it has to span the difference in
        // length or the path does not fit inside it — so the only choice is
        // to spend the memory or decline.
        #expect(band.exceedsBudget)

        // Declining still returns a complete, well-formed alignment: every
        // reference character missing, every candidate character invented.
        let steps = SequenceAlignment.align(
            reference: Array(String(repeating: "山", count: rows)),
            candidate: Array("山村的"),
        )
        #expect(steps.compactMap(\.reference) == Array(0 ..< rows))
        #expect(steps.compactMap(\.candidate) == [0, 1, 2])
        #expect(steps.allSatisfy { $0.operation == .delete || $0.operation == .insert })
    }

    /// The clamp must not touch the sizes this is actually used at. A phrase
    /// is tens of characters and a whole exercise is hundreds; both must get
    /// the exact answer.
    @Test("Real-sized inputs are never clamped")
    func realisticSizesAreUnclamped() {
        let band = SequenceAlignment.Band(rows: 609, columns: 600, slack: 128)
        #expect(band.band == 137)
        #expect(!band.exceedsBudget)
        // A whole audiobook chapter against its own transcript, too.
        #expect(!SequenceAlignment.Band(rows: 20000, columns: 20100, slack: 128).exceedsBudget)
    }

    @Test("A slack of zero still leaves room for one indel")
    func zeroSlackKeepsOneStepOfRoom() {
        let steps = SequenceAlignment.align(
            reference: Array("甲乙丙"),
            candidate: Array("乙丙丁"),
            slack: 0,
        )
        #expect(distance(steps) == 2)
        #expect(steps.compactMap(\.reference) == [0, 1, 2])
        #expect(steps.compactMap(\.candidate) == [0, 1, 2])
    }
}
