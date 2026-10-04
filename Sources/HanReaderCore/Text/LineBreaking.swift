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
    /// Where this line's top sits, including the spacing above it.
    public let y: Double
    public let height: Double
    /// Total width used, for alignment.
    public let width: Double

    public init(
        range: Range<Int>,
        xOffsets: [Double],
        y: Double,
        height: Double,
        width: Double,
    ) {
        self.range = range
        self.xOffsets = xOffsets
        self.y = y
        self.height = height
        self.width = width
    }
}

extension [LineRun] {
    /// Total height of the laid-out lines, including the gaps between them.
    public var totalHeight: Double {
        guard let last else { return 0 }
        return last.y + last.height
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
/// Breaking works from a precomputed table of *legal* break positions rather
/// than by retreating on demand. A break before item `i` is legal only if `i`
/// may begin a line and `i - 1` may end one, so both typography rules are
/// consulted at every boundary — checking them separately, as the first
/// version did, let a retreat for one rule land on a position the other
/// forbids. Precomputing also makes the search linear: retreating on demand
/// rescanned a growing prefix, so a long run of punctuation cost quadratic
/// time.
///
/// - Parameters:
///   - items: measured items, in reading order.
///   - width: the available width. Non-positive widths put one item per line,
///     except where a break would be illegal.
///   - lineSpacing: vertical gap between lines, reflected in each line's `y`.
/// - Returns: one `LineRun` per line, covering every item exactly once.
public func layOutLines(
    _ items: [LineItem],
    width: Double,
    lineSpacing: Double = 0,
)
    -> [LineRun]
{
    guard !items.isEmpty else { return [] }

    let legal = legalBreakPositions(items)
    var lines: [LineRun] = []
    var start = 0
    var y = 0.0

    while start < items.count {
        let end = lineEnd(items, from: start, width: width, legal: legal)
        let line = buildLine(items, from: start, upTo: end, y: y)
        lines.append(line)
        y += line.height + lineSpacing
        // Guaranteed progress: lineEnd always returns more than `start`.
        start = end
    }
    return lines
}

/// Whether a line may begin at each position.
///
/// Index `i` means "a break immediately before item `i`". Position 0 and
/// `count` are the document's own edges and are always legal.
private func legalBreakPositions(_ items: [LineItem]) -> [Bool] {
    var legal = [Bool](repeating: false, count: items.count + 1)
    legal[0] = true
    legal[items.count] = true
    guard items.count > 1 else { return legal }

    for index in 1 ..< items.count {
        // Both rules at once. `glueToPrevious` forbids starting a line here;
        // the previous item's `canEndLine` forbids ending one there.
        legal[index] = !items[index].glueToPrevious && items[index - 1].canEndLine
    }
    return legal
}

/// Where the line beginning at `start` should end.
private func lineEnd(
    _ items: [LineItem],
    from start: Int,
    width: Double,
    legal: [Bool],
)
    -> Int
{
    var cursor = 0.0
    var index = start

    while index < items.count {
        let item = items[index]
        let gap = index == start ? 0 : item.leadingSpace
        if cursor + gap + item.advance > width, index > start {
            break
        }
        cursor += gap + item.advance
        index += 1
    }

    // Everything fits.
    if index >= items.count {
        return items.count
    }

    // Retreat to the nearest legal break after `start`.
    var candidate = index
    while candidate > start, !legal[candidate] {
        candidate -= 1
    }
    if candidate > start {
        return candidate
    }

    // Nothing legal before the overflow point, so the line must overflow:
    // extend to the next legal break instead of breaking illegally. This is
    // what keeps an opening bracket with the text it opens on a narrow line,
    // and what holds an unbreakable run of punctuation together.
    var forward = index + 1
    while forward < items.count, !legal[forward] {
        forward += 1
    }
    return min(forward, items.count)
}

/// Measures and positions the items on one line.
private func buildLine(
    _ items: [LineItem],
    from start: Int,
    upTo end: Int,
    y: Double,
)
    -> LineRun
{
    var offsets: [Double] = []
    offsets.reserveCapacity(end - start)
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
    return LineRun(
        range: start ..< end,
        xOffsets: offsets,
        y: y,
        height: height,
        width: cursor,
    )
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
