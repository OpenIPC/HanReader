// HanReader — MIT licensed. See LICENSE.

import Foundation

/// Identifies a token by its position in the document.
///
/// Packed into one `Int` so it is cheap to use as a SwiftUI identity and as a
/// dictionary key, while still being readable in a debugger.
public struct TokenID: Hashable, Sendable, Comparable {
    public let block: Int
    public let index: Int

    public init(block: Int, index: Int) {
        self.block = block
        self.index = index
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.block, lhs.index) < (rhs.block, rhs.index)
    }
}

/// One token: a word, a punctuation mark, a run of Latin text or digits.
public struct Token: Hashable, Sendable, Identifiable {
    public let id: TokenID
    public let text: String

    /// Where this token sits in the **original** text, as UTF-16 offsets.
    ///
    /// UTF-16 rather than `String.Index`, which is neither `Sendable` nor
    /// serialisable, and rather than character offsets, which cost O(n) to
    /// convert. It is also the unit `NSRange` and `AttributedString` use, and
    /// the unit a stored reading position has to be in.
    ///
    /// The prototype's token carried no position at all, which is why it could
    /// never restore a reading position or align audio to text.
    public let range: Range<Int>

    public let kind: TokenKind

    /// Whether whitespace followed this token in the source.
    ///
    /// Kept so the document can be reassembled exactly. The prototype dropped
    /// whitespace-only gaps, so any text mixing Latin with Chinese lost its
    /// spaces and could not be round-tripped.
    public let trailingSpace: Bool

    public init(
        id: TokenID,
        text: String,
        range: Range<Int>,
        kind: TokenKind,
        trailingSpace: Bool = false,
    ) {
        self.id = id
        self.text = text
        self.range = range
        self.kind = kind
        self.trailingSpace = trailingSpace
    }

    /// Whether this token is worth tapping — a word, not punctuation or space.
    public var isLookupCandidate: Bool {
        switch kind {
        case .han, .latin: true
        case .number, .punctuation, .whitespace, .other: false
        }
    }
}

/// What a block of text is.
public enum BlockKind: UInt8, Sendable, Hashable {
    case paragraph
    /// A deliberate gap between paragraphs, preserved so the reader's layout
    /// matches the source.
    case blankLine
}

/// A paragraph.
///
/// The unit of laziness in the reader: only the handful of blocks on screen
/// are materialised. That is why paragraph structure is modelled rather than
/// signalled by a sentinel token — the prototype emitted a synthetic newline
/// token, which forced its layout to detect line breaks by sniffing for "a
/// zero-height subview wider than 90% of the container".
public struct TextBlock: Hashable, Sendable, Identifiable {
    public let id: Int
    public let kind: BlockKind
    /// UTF-16 range of this block in the original text.
    public let range: Range<Int>
    public let tokens: [Token]

    public init(id: Int, kind: BlockKind, range: Range<Int>, tokens: [Token]) {
        self.id = id
        self.kind = kind
        self.range = range
        self.tokens = tokens
    }
}

/// A text, segmented into paragraphs and tokens.
public struct SegmentedDocument: Hashable, Sendable {
    public let blocks: [TextBlock]
    /// Length of the source in UTF-16 units, so a reading position can be
    /// expressed as a fraction without holding the text.
    public let sourceLength: Int

    public init(blocks: [TextBlock], sourceLength: Int) {
        self.blocks = blocks
        self.sourceLength = sourceLength
    }

    public var tokenCount: Int {
        blocks.reduce(0) { $0 + $1.tokens.count }
    }

    public subscript(id: TokenID) -> Token? {
        guard blocks.indices.contains(id.block) else { return nil }
        let block = blocks[id.block]
        guard block.tokens.indices.contains(id.index) else { return nil }
        return block.tokens[id.index]
    }

    /// The token containing a UTF-16 offset.
    ///
    /// This is how a stored reading position is turned back into a place in
    /// the document after the text has been re-segmented — possibly by a
    /// different engine than the one that produced the offset.
    public func token(atOffset offset: Int) -> Token? {
        guard let block = blocks.first(where: { $0.range.contains(offset) })
            ?? blocks.last(where: { $0.range.lowerBound <= offset })
        else { return nil }
        return block.tokens.first { $0.range.contains(offset) }
            ?? block.tokens.last { $0.range.lowerBound <= offset }
    }
}

// MARK: - Invariants

extension SegmentedDocument {
    /// Whether tokens tile their blocks and blocks tile the source, with no
    /// gaps and no overlaps.
    ///
    /// This is the property that makes reading-position restore and audio
    /// alignment sound, and it is what the prototype violated by discarding
    /// whitespace-only gaps. Asserted by a property test over random input
    /// rather than only on hand-picked cases.
    public var isWellFormed: Bool {
        var expected = 0
        for (index, block) in blocks.enumerated() {
            guard block.id == index else { return false }
            guard block.range.lowerBound == expected else { return false }
            guard block.range.upperBound >= block.range.lowerBound else { return false }

            var inner = block.range.lowerBound
            for (position, token) in block.tokens.enumerated() {
                guard token.id == TokenID(block: index, index: position) else { return false }
                guard token.range.lowerBound == inner else { return false }
                guard token.range.upperBound > token.range.lowerBound else { return false }
                inner = token.range.upperBound
            }
            guard inner == block.range.upperBound else { return false }
            expected = block.range.upperBound
        }
        return expected == sourceLength
    }

    /// Rebuilds the original text from the tokens.
    ///
    /// If this does not equal the input, something was dropped. The prototype
    /// fails this on any text mixing Latin with Chinese.
    public func reassembled() -> String {
        blocks.flatMap(\.tokens).map(\.text).joined()
    }
}
