// HanReader — MIT licensed. See LICENSE.

import Foundation
import Testing
@testable import HanReaderCore

/// A measurer with fixed, invented metrics.
///
/// Hermetic on purpose. Using real font metrics would make every assertion
/// here depend on the version of PingFang the machine happens to ship, so the
/// suite would go red on OS updates with nothing in the project at fault —
/// which is exactly why the reader's layout is tested through this rather
/// than through pixel snapshots.
///
/// The ratios are roughly realistic: a Han glyph is square, Latin is about
/// half as wide per character.
struct FixedMeasurer: TextMeasuring {
    var size: Double = 10
    var wordSpacing: Double = 1

    func advance(of text: String, kind: TokenKind) -> Double {
        switch kind {
        case .han, .punctuation: Double(text.count) * size
        case .latin: Double(text.count) * size * 0.5
        case .number: Double(text.count) * size * 0.5
        case .whitespace: Double(text.count) * size * 0.25
        case .other: Double(text.count) * size
        }
    }

    func height(of _: String, kind _: TokenKind) -> Double {
        size
    }

    func leadingSpace(before _: String, kind: TokenKind) -> Double {
        kind == .whitespace ? 0 : wordSpacing
    }
}

/// Builds items directly, bypassing segmentation, so a test says exactly what
/// it means.
/// One item to build, described rather than positional.
private struct Spec {
    var advance: Double
    var glue = false
    var opener = false
}

private func items(_ specs: [Spec]) -> [LineItem] {
    specs.map {
        LineItem(
            advance: $0.advance,
            height: 10,
            leadingSpace: 0,
            glueToPrevious: $0.glue,
            canEndLine: !$0.opener,
        )
    }
}

private func plain(_ advances: [Double], leadingSpace: Double = 0) -> [LineItem] {
    advances.map { LineItem(advance: $0, height: 10, leadingSpace: leadingSpace) }
}

@Suite("Line breaking")
struct LineBreakingTests {
    @Test("Items that fit go on one line")
    func singleLine() {
        let lines = layOutLines(plain([10, 10, 10]), width: 100)
        #expect(lines.count == 1)
        #expect(lines[0].range == 0 ..< 3)
        #expect(lines[0].xOffsets == [0, 10, 20])
        #expect(lines[0].width == 30)
        #expect(lines[0].height == 10)
    }

    @Test("Items wrap when they run out of room")
    func wraps() {
        let lines = layOutLines(plain([10, 10, 10, 10]), width: 25)
        #expect(lines.map(\.range) == [0 ..< 2, 2 ..< 4])
    }

    /// The boundary cases, where an off-by-one shows up.
    @Test("Exact fit and one-too-many", arguments: [
        (30.0, [0 ..< 3]),
        (29.0, [0 ..< 2, 2 ..< 3]),
        (31.0, [0 ..< 3]),
    ])
    func boundaries(width: Double, expected: [Range<Int>]) {
        #expect(layOutLines(plain([10, 10, 10]), width: width).map(\.range) == expected)
    }

    @Test("Leading space counts towards the width")
    func leadingSpace() {
        // 10 + (2+10) + (2+10) = 34, so a width of 30 fits only two.
        let lines = layOutLines(plain([10, 10, 10], leadingSpace: 2), width: 30)
        #expect(lines.map(\.range) == [0 ..< 2, 2 ..< 3])
        // The first item on a line never pays for leading space.
        #expect(lines[1].xOffsets == [0])
    }

    /// Must place the item and move on rather than loop forever.
    @Test("An item wider than the line overflows instead of hanging", .timeLimit(.minutes(1)))
    func oversizedItem() {
        let lines = layOutLines(plain([10, 500, 10]), width: 100)
        #expect(lines.count == 3)
        #expect(lines[1].range == 1 ..< 2)
        #expect(lines[1].width == 500)
    }

    @Test("Degenerate widths terminate", .timeLimit(.minutes(1)), arguments: [0.0, -5.0])
    func degenerateWidth(width: Double) {
        let lines = layOutLines(plain([10, 10, 10]), width: width)
        #expect(lines.count == 3)
        #expect(lines.allSatisfy { $0.range.count == 1 })
    }

    @Test("Empty input produces no lines")
    func empty() {
        #expect(layOutLines([], width: 100).isEmpty)
    }

    /// Every item appears on exactly one line, in order. Without this a
    /// break-rule bug could silently drop or duplicate a token.
    @Test("Lines cover every item exactly once")
    func coversEverything() {
        var generator = SystemRandomNumberGenerator()
        for _ in 0 ..< 300 {
            let count = Int.random(in: 1 ... 40, using: &generator)
            let specs = (0 ..< count).map { _ in
                Spec(
                    advance: Double(Int.random(in: 1 ... 30, using: &generator)),
                    glue: Bool.random(using: &generator),
                    opener: Bool.random(using: &generator),
                )
            }
            let width = Double(Int.random(in: 1 ... 120, using: &generator))
            let lines = layOutLines(items(specs), width: width)

            let covered = lines.flatMap { Array($0.range) }
            #expect(covered == Array(0 ..< count), "coverage broken at width \(width)")
            for line in lines {
                #expect(line.xOffsets.count == line.range.count)
            }
        }
    }
}

@Suite("CJK line-breaking rules")
struct KinsokuTests {
    /// The rule a reader notices immediately: a full stop may not open a line.
    @Test("Closing punctuation never starts a line")
    func closingPunctuationGlues() {
        // Three 10-wide items then a glued mark, in a width that would
        // otherwise put the mark on line two.
        let specs = [
            Spec(advance: 10), Spec(advance: 10), Spec(advance: 10),
            Spec(advance: 10, glue: true),
        ]
        let lines = layOutLines(items(specs), width: 30)
        // Without gluing this would be [0..<3, 3..<4], orphaning the mark.
        #expect(lines.map(\.range) == [0 ..< 2, 2 ..< 4])
    }

    @Test("Opening punctuation never ends a line")
    func openersMoveDown() {
        let specs = [
            Spec(advance: 10), Spec(advance: 10),
            Spec(advance: 10, opener: true), Spec(advance: 10),
        ]
        let lines = layOutLines(items(specs), width: 30)
        // The opener at index 2 would have ended line one; it moves down.
        #expect(lines.map(\.range) == [0 ..< 2, 2 ..< 4])
    }

    /// When the whole line is one glued run there is nowhere legal to break,
    /// so overflowing is the only option — and it must not loop.
    @Test("An unbreakable glued run overflows rather than hanging", .timeLimit(.minutes(1)))
    func unbreakableRun() {
        let specs = [Spec(advance: 10)]
            + (0 ..< 9).map { _ in Spec(advance: 10, glue: true) }
        let lines = layOutLines(items(specs), width: 25)
        #expect(lines.count == 1)
        #expect(lines[0].range == 0 ..< 10)
    }

    @Test("The mark sets agree with the rules", arguments: [
        ("。", true, true), ("，", true, true), ("）", true, true), ("」", true, true),
        ("（", false, false), ("「", false, false), ("“", false, false),
        ("中", false, true), ("word", false, true),
    ])
    func rules(text: String, glues: Bool, canEnd: Bool) {
        #expect(LineBreakRules.glueToPrevious(text) == glues)
        #expect(LineBreakRules.canEndLine(text) == canEnd)
    }

    /// A multi-character token is a word, not a mark, whatever it starts with.
    @Test("Rules apply to single marks only")
    func singleCharacterOnly() {
        #expect(LineBreakRules.glueToPrevious("。。") == false)
        #expect(LineBreakRules.canEndLine("（x") == true)
    }
}

@Suite("Measuring tokens")
struct TokenMeasuringTests {
    private let lexicon = Lexicon(words: ["中国", "人民", "学习"])

    private func document(_ text: String) -> SegmentedDocument {
        TextSegmenter(words: MaxMatchSegmenter(lexicon: lexicon)).segment(text)
    }

    @Test("Tokens become items carrying the break rules")
    func measuring() {
        let tokens = document("中国人民。").blocks.flatMap(\.tokens)
        let items = tokens.lineItems(measuredBy: FixedMeasurer())

        #expect(items.count == tokens.count)
        // 中国 is two Han glyphs at 10 each.
        #expect(items[0].advance == 20)
        // The full stop glues to what precedes it.
        #expect(items.last?.glueToPrevious == true)
    }

    /// The end-to-end shape the reader will use: segment, measure, lay out.
    @Test("A sentence lays out with the full stop kept off the line start")
    func endToEnd() {
        let tokens = document("中国人民学习中国人民。").blocks.flatMap(\.tokens)
        let items = tokens.lineItems(measuredBy: FixedMeasurer())
        let lines = layOutLines(items, width: 65)

        #expect(lines.count > 1)
        // No line may begin with a glued item.
        for line in lines.dropFirst() {
            #expect(
                items[line.range.lowerBound].glueToPrevious == false,
                "a line started with glued punctuation",
            )
        }
        // And nothing was lost.
        #expect(lines.flatMap { Array($0.range) } == Array(0 ..< items.count))
    }
}

@Suite("Line-breaking regressions")
struct LineBreakingRegressionTests {
    /// An opener alone on a line is exactly what the rule exists to prevent,
    /// so when there is nowhere legal to break the line must overflow rather
    /// than break illegally.
    @Test("A narrow line does not strand an opening bracket")
    func narrowLineKeepsOpenerWithItsText() {
        let specs = [Spec(advance: 10, opener: true), Spec(advance: 10)]
        let lines = layOutLines(items(specs), width: 10)
        #expect(lines.map(\.range) == [0 ..< 2], "（ was left alone on its line")
    }

    /// Retreating for glue found a legal-looking boundary without checking
    /// that the resulting line could legally *end* there.
    @Test("Retreating for glue does not strand an opener")
    func glueRetreatRespectsOpeners() {
        // 中 （ 甲 。 at ten each, width thirty.
        let specs = [
            Spec(advance: 10),
            Spec(advance: 10, opener: true),
            Spec(advance: 10),
            Spec(advance: 10, glue: true),
        ]
        let lines = layOutLines(items(specs), width: 30)
        // Must not be [0..<2, 2..<4]: that ends line one on the opener.
        #expect(lines.map(\.range) == [0 ..< 1, 1 ..< 4])
    }

    /// The degenerate-width tests only covered unglued items, so this path
    /// was unexercised.
    @Test(
        "Glue is honoured even at a degenerate width",
        .timeLimit(.minutes(1)),
        arguments: [0.0, -5.0],
    )
    func degenerateWidthWithGlue(width: Double) {
        let specs = [Spec(advance: 10), Spec(advance: 10, glue: true)]
        let lines = layOutLines(items(specs), width: width)
        // One line, because the second item may not begin one. Splitting here
        // would honour the width at the cost of the typography rule, which is
        // the wrong trade.
        #expect(lines.map(\.range) == [0 ..< 2])
        #expect(lines.flatMap { Array($0.range) } == [0, 1])
    }

    /// A long run of punctuation made the retreat helper rescan a growing
    /// prefix on every overflow.
    @Test("A long glued run lays out in reasonable time", .timeLimit(.minutes(1)))
    func longGluedRunIsNotQuadratic() {
        let specs = [Spec(advance: 10)] + (0 ..< 4000).map { _ in Spec(advance: 10, glue: true) }
        let lines = layOutLines(items(specs), width: 25)
        #expect(lines.count == 1)
        #expect(lines[0].range.count == 4001)
    }

    @Test("A long run of openers lays out in reasonable time", .timeLimit(.minutes(1)))
    func longOpenerRunIsNotQuadratic() {
        let specs = (0 ..< 4000).map { _ in Spec(advance: 10, opener: true) } + [Spec(advance: 10)]
        let lines = layOutLines(items(specs), width: 25)
        #expect(lines.flatMap { Array($0.range) } == Array(0 ..< 4001))
    }

    /// `lineSpacing` was accepted and immediately discarded, so every value
    /// produced the same result and no caller could position anything.
    @Test("Line spacing positions the lines")
    func lineSpacingIsUsed() {
        let lines = layOutLines(plain([10, 10, 10, 10]), width: 25, lineSpacing: 4)
        #expect(lines.count == 2)
        #expect(lines[0].y == 0)
        // First line is 10 tall, plus 4 of spacing.
        #expect(lines[1].y == 14)
    }

    @Test("Total height accounts for spacing between lines")
    func totalHeight() {
        let lines = layOutLines(plain([10, 10, 10, 10]), width: 25, lineSpacing: 4)
        // Two 10-tall lines with one 4-unit gap.
        #expect(lines.totalHeight == 24)
        #expect(layOutLines([], width: 10, lineSpacing: 4).totalHeight == 0)
    }
}
