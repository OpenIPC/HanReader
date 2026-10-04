// HanReader — MIT licensed. See LICENSE.

import Foundation

/// Splits text into paragraphs and tokens.
///
/// The seam exists so that the Apple tokenizer and the deterministic one can
/// be swapped. `NLTokenizer` is a closed model whose segmentation of a given
/// sentence can change between OS releases, so a test asserting its exact
/// output is flaky by construction — the deterministic implementation is what
/// the suite pins, and what runs where `NaturalLanguage` is unavailable.
public protocol Tokenizing: Sendable {
    /// Segments `text` into tokens, preserving paragraph structure.
    func segment(_ text: String) -> SegmentedDocument
}

/// Builds documents by splitting into paragraphs and delegating word
/// segmentation for each run of Han characters.
///
/// Everything except the Han runs is handled identically whichever word
/// segmenter is in use: paragraph splitting, script-run detection,
/// punctuation, Latin and digits. Only the hard part varies.
public struct TextSegmenter<WordSegmenter: HanWordSegmenting>: Tokenizing {
    private let words: WordSegmenter

    public init(words: WordSegmenter) {
        self.words = words
    }

    public func segment(_ text: String) -> SegmentedDocument {
        let utf16 = Array(text.utf16)
        var blocks: [TextBlock] = []
        var cursor = 0

        for (index, paragraph) in Self.paragraphs(in: text).enumerated() {
            let tokens = tokenize(
                paragraph.text,
                blockIndex: index,
                startingAt: paragraph.range.lowerBound,
            )
            blocks.append(TextBlock(
                id: index,
                kind: paragraph.isBlank ? .blankLine : .paragraph,
                range: paragraph.range,
                tokens: tokens,
            ))
            cursor = paragraph.range.upperBound
        }

        // Anything after the final separator still belongs to the document;
        // dropping it would break the tiling invariant.
        if cursor < utf16.count {
            let range = cursor ..< utf16.count
            let text = String(decoding: utf16[range], as: UTF16.self)
            blocks.append(TextBlock(
                id: blocks.count,
                kind: .blankLine,
                range: range,
                tokens: tokenize(text, blockIndex: blocks.count, startingAt: cursor),
            ))
        }

        return SegmentedDocument(blocks: blocks, sourceLength: utf16.count)
    }

    // MARK: - Paragraphs

    private struct Paragraph {
        let text: String
        let range: Range<Int>
        let isBlank: Bool
    }

    /// Splits on line breaks, keeping the separators attached to the block
    /// they end so that the blocks tile the source exactly.
    ///
    /// Uses `isNewline`, which treats CRLF as the single grapheme it is in
    /// Swift. Splitting on a literal `"\n"` does not split a CRLF file at all
    /// — the mistake that would have made the whole CC-CEDICT import arrive as
    /// one line.
    private static func paragraphs(in text: String) -> [Paragraph] {
        var result: [Paragraph] = []
        var start = 0
        var offset = 0
        var current = ""

        for character in text {
            let width = String(character).utf16.count
            if character.isNewline {
                current.append(character)
                offset += width
                let range = start ..< offset
                result.append(Paragraph(
                    text: current,
                    range: range,
                    isBlank: current.allSatisfy(\.isWhitespace),
                ))
                current = ""
                start = offset
            } else {
                current.append(character)
                offset += width
            }
        }
        if !current.isEmpty {
            result.append(Paragraph(
                text: current,
                range: start ..< offset,
                isBlank: current.allSatisfy(\.isWhitespace),
            ))
        }
        return result
    }

    // MARK: - Tokens

    /// Splits a paragraph into runs by character class, then asks the word
    /// segmenter to break up the Han runs.
    private func tokenize(_ text: String, blockIndex: Int, startingAt base: Int) -> [Token] {
        var tokens: [Token] = []
        var offset = base

        func append(_ piece: String, kind: TokenKind) {
            let width = piece.utf16.count
            guard width > 0 else { return }
            tokens.append(Token(
                id: TokenID(block: blockIndex, index: tokens.count),
                text: piece,
                range: offset ..< (offset + width),
                kind: kind,
                trailingSpace: false,
            ))
            offset += width
        }

        for run in Self.runs(in: text) {
            switch run.kind {
            case .han:
                // Only Han runs need word segmentation; the rest are already
                // the right granularity.
                for word in words.split(run.text) {
                    append(word, kind: .han)
                }
            case .latin, .number, .whitespace:
                // Kept whole: `iPhone` is one token, not six, and a run of
                // spaces is one token so the text reassembles exactly.
                append(run.text, kind: run.kind)
            case .punctuation, .other:
                // One token per character: punctuation is tapped and laid out
                // individually, and gluing is decided per mark.
                for character in run.text {
                    append(String(character), kind: run.kind)
                }
            }
        }
        return tokens
    }

    private struct Run {
        let text: String
        let kind: TokenKind
    }

    /// Groups adjacent characters of the same class.
    private static func runs(in text: String) -> [Run] {
        var runs: [Run] = []
        var current = ""
        var currentKind: TokenKind?

        for character in text {
            let kind = character.tokenKind
            if kind == currentKind {
                current.append(character)
            } else {
                if let currentKind, !current.isEmpty {
                    runs.append(Run(text: current, kind: currentKind))
                }
                current = String(character)
                currentKind = kind
            }
        }
        if let currentKind, !current.isEmpty {
            runs.append(Run(text: current, kind: currentKind))
        }
        return runs
    }
}

/// Splits a run of Han characters into words.
///
/// Narrow on purpose: everything else about segmentation is shared, and only
/// this part differs between the Apple tokenizer and the deterministic one.
public protocol HanWordSegmenting: Sendable {
    /// Splits a run containing only Han characters. The concatenation of the
    /// result must equal the input.
    func split(_ run: String) -> [String]
}

/// Splits every character separately.
///
/// The baseline, and what the reader falls back to with no lexicon: for
/// Chinese, character-by-character is wrong but never *misleading*, which is
/// the right failure mode.
public struct CharacterSegmenter: HanWordSegmenting {
    public init() {}

    public func split(_ run: String) -> [String] {
        run.map(String.init)
    }
}
