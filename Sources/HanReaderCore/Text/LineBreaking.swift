// HanReader — MIT licensed. See LICENSE.

import Foundation

/// One item to place on a line: a measured token.
///
/// Deliberately knows nothing about tokens, fonts or views. Line breaking is
/// the one piece of the reader's layout that is pure arithmetic, and keeping
/// it that way is what lets it be tested exhaustively without rendering
/// anything — the alternative is pixel snapshots of CJK text, which go red on
/// every OS update because glyph metrics shift.
public struct LineItem: Hashable, Sendable {
    /// How much horizontal space this item occupies.
    public let advance: Double
    public let height: Double
    /// Space that would precede this item if it does not start a line.
    public let leadingSpace: Double
    /// Whether this item must stay on the same line as the one before it.
    ///
    /// True for closing punctuation: a line may not *begin* with `。` or `，`.
    public let glueToPrevious: Bool
    /// Whether a line may end with this item.
    ///
    /// False for opening brackets and quotes: a line may not *end* with `（`
    /// or `“`, because the mark would be orphaned from what it opens.
    public let canEndLine: Bool

    public init(
        advance: Double,
        height: Double,
        leadingSpace: Double = 0,
        glueToPrevious: Bool = false,
        canEndLine: Bool = true,
    ) {
        self.advance = advance
        self.height = height
        self.leadingSpace = leadingSpace
        self.glueToPrevious = glueToPrevious
        self.canEndLine = canEndLine
    }
}

/// One laid-out line.
public struct LineRun: Hashable, Sendable {
    /// Which items are on this line, as a range into the input.
    public let range: Range<Int>
    /// Where each item starts, relative to the line's leading edge. Parallel
    /// to `range`.
    public let xOffsets: [Double]
    public let height: Double
    /// Total width used, for alignment.
    public let width: Double

    public init(range: Range<Int>, xOffsets: [Double], height: Double, width: Double) {
        self.range = range
        self.xOffsets = xOffsets
        self.height = height
        self.width = width
    }
}

/// Breaks measured items into lines.
///
/// A free function over value types, with no reference to any view or model.
/// Three things follow from that, and they are the reason it is shaped this
/// way rather than living inside a `Layout` conformance:
///
/// - It can be tested against a deterministic measurer, so the tests are
///   hermetic and survive OS font-metric changes.
/// - Its results can be snapshotted as text, which diffs readably in a pull
///   request, instead of as pixels that cry wolf.
/// - Reading an `@Observable` property inside `Layout.sizeThatFits` registers
///   an observation dependency in a scope nobody controls, so the layout has
///   to take plain values anyway.
///
/// - Parameters:
///   - items: measured items, in reading order.
///   - width: the available width. Non-positive widths yield one item per
///     line rather than looping or producing empty lines.
///   - lineSpacing: vertical gap between lines, used only for the total
///     height a caller computes; `layOutLines` itself returns per-line heights.
/// - Returns: one `LineRun` per line, covering every item exactly once.
public func layOutLines(
    _ items: [LineItem],
    width: Double,
    lineSpacing: Double = 0,
)
    -> [LineRun]
{
    _ = lineSpacing
    guard !items.isEmpty else { return [] }

    var lines: [LineRun] = []
    var start = 0

    while start < items.count {
        let line = measureLine(items, from: start, width: width)
        lines.append(line)
        // Guaranteed progress: measureLine always consumes at least one item,
        // so this cannot loop even on a zero width or an oversized item.
        start = line.range.upperBound
    }
    return lines
}

/// Fills one line starting at `start`.
private func measureLine(_ items: [LineItem], from start: Int, width: Double) -> LineRun {
    var offsets: [Double] = []
    var cursor = 0.0
    var height = 0.0
    var index = start

    while index < items.count {
        let item = items[index]
        let gap = index == start ? 0 : item.leadingSpace
        let needed = cursor + gap + item.advance

        // An item that does not fit ends the line -- unless nothing is on the
        // line yet, in which case it goes on anyway. A single token wider than
        // the container must still be placed somewhere, and overflowing is
        // better than looping forever.
        if needed > width, index > start {
            // Glue: this item may not begin a line, so pull the run it is
            // attached to down with it. Without this, `。` starts a line,
            // which is the most visible way to get CJK typography wrong.
            if item.glueToPrevious {
                if let retreat = retreatForGlue(items, lineStart: start, breakingAt: index) {
                    return rebuild(items, from: start, upTo: retreat)
                }
                // The whole line is one glued run and still does not fit.
                // Overflow rather than loop.
            } else {
                // An opening bracket may not end a line, so step back past
                // any trailing openers before breaking.
                let adjusted = retreatForOpeners(items, lineStart: start, breakingAt: index)
                if adjusted > start {
                    return rebuild(items, from: start, upTo: adjusted)
                }
                break
            }
        }

        cursor += gap
        offsets.append(cursor)
        cursor += item.advance
        height = max(height, item.height)
        index += 1
    }

    return LineRun(
        range: start ..< index,
        xOffsets: offsets,
        height: height,
        width: cursor,
    )
}

/// Where to break so that a glued item does not start a line.
///
/// Walks back over the glued run. Returns nil when the run reaches the start
/// of the line, meaning there is nowhere legal to break.
private func retreatForGlue(_ items: [LineItem], lineStart: Int, breakingAt index: Int) -> Int? {
    var candidate = index
    while candidate > lineStart, items[candidate].glueToPrevious {
        candidate -= 1
    }
    return candidate > lineStart ? candidate : nil
}

/// Steps back past trailing items that may not end a line.
private func retreatForOpeners(_ items: [LineItem], lineStart: Int, breakingAt index: Int) -> Int {
    var candidate = index
    while candidate > lineStart, !items[candidate - 1].canEndLine {
        candidate -= 1
    }
    return candidate
}

/// Re-measures a line that was cut short by a break rule.
private func rebuild(_ items: [LineItem], from start: Int, upTo end: Int) -> LineRun {
    var offsets: [Double] = []
    var cursor = 0.0
    var height = 0.0

    for index in start ..< end {
        let item = items[index]
        if index > start {
            cursor += item.leadingSpace
        }
        offsets.append(cursor)
        cursor += item.advance
        height = max(height, item.height)
    }
    return LineRun(range: start ..< end, xOffsets: offsets, height: height, width: cursor)
}

// MARK: - Typography rules

/// Which punctuation may not start or end a line.
///
/// This is 禁則処理 (kinsoku shori) reduced to its most visible rule. It is
/// about fifteen lines and fixes the CJK typography error a reader notices
/// immediately — a full stop at the start of a line — which is most of what
/// a full line-breaking engine would buy here.
///
/// Not attempted: justification, hyphenation, vertical writing. None was in
/// the prototype and none is in scope.
public enum LineBreakRules {
    /// Marks that may not begin a line, so they glue to what precedes them.
    public static let cannotStartLine: Set<Character> = [
        "。", "，", "、", "．", "：", "；", "！", "？",
        "）", "】", "》", "」", "』", "〉", "］", "｝",
        "”", "’", "〕", "…", "‥", "・", "ー", "々",
        ".", ",", ":", ";", "!", "?", ")", "]", "}",
    ]

    /// Marks that may not end a line, so a break moves before them.
    public static let cannotEndLine: Set<Character> = [
        "（", "【", "《", "「", "『", "〈", "［", "｛",
        "“", "‘", "〔",
        "(", "[", "{",
    ]

    public static func glueToPrevious(_ text: String) -> Bool {
        guard let first = text.first, text.count == 1 else { return false }
        return cannotStartLine.contains(first)
    }

    public static func canEndLine(_ text: String) -> Bool {
        guard let first = text.first, text.count == 1 else { return true }
        return !cannotEndLine.contains(first)
    }
}

/// Measures tokens into line items.
///
/// Injected so that tests can supply a deterministic measurer. Real text
/// measurement belongs to the UI layer, which has the fonts.
public protocol TextMeasuring: Sendable {
    /// The advance width of a token's text.
    func advance(of text: String, kind: TokenKind) -> Double
    /// The line height a token contributes.
    func height(of text: String, kind: TokenKind) -> Double
    /// Space before a token when it does not start a line.
    func leadingSpace(before text: String, kind: TokenKind) -> Double
}

extension [Token] {
    /// Measures tokens into items ready for `layOutLines`.
    public func lineItems(measuredBy measurer: some TextMeasuring) -> [LineItem] {
        map { token in
            LineItem(
                advance: measurer.advance(of: token.text, kind: token.kind),
                height: measurer.height(of: token.text, kind: token.kind),
                leadingSpace: measurer.leadingSpace(before: token.text, kind: token.kind),
                glueToPrevious: LineBreakRules.glueToPrevious(token.text),
                canEndLine: LineBreakRules.canEndLine(token.text),
            )
        }
    }
}
