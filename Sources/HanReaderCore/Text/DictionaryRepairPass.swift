// HanReader — MIT licensed. See LICENSE.

import Foundation

/// Merges adjacent tokens that the lexicon recognises as one word.
///
/// Runs after any segmenter, including Apple's. Measured on macOS 26,
/// `NLTokenizer` is good but *inconsistent*: it keeps `这个` while splitting
/// `一 | 个 | 人` and `三 | 个`, even though `一个人` and `三个` are both
/// dictionary headwords. That is a repair problem, not grounds for replacing
/// a segmenter that is otherwise accurate.
///
/// Two properties make it safe to run unconditionally:
///
/// - **It only ever merges.** Never splitting means it cannot turn a correct
///   segmentation into a wrong one — the worst it can do is join two tokens
///   that were better apart, and the merge must be a dictionary word for that
///   to happen at all.
/// - **It is window-bounded**, so it is linear with a small constant rather
///   than quadratic in paragraph length.
public struct DictionaryRepairPass: Sendable {
    /// How many adjacent tokens may be merged at once.
    ///
    /// Four covers the compounds the tokenizer actually splits. Allowing more
    /// would start reaching for long idioms, which is the failure mode the
    /// lexicon's length cap exists to prevent.
    public static let maximumTokens = 4

    private let lexicon: Lexicon

    public init(lexicon: Lexicon) {
        self.lexicon = lexicon
    }

    /// Repairs every block of a document.
    public func repair(_ document: SegmentedDocument) -> SegmentedDocument {
        guard !lexicon.isEmpty else { return document }
        let blocks = document.blocks.enumerated().map { index, block in
            TextBlock(
                id: index,
                kind: block.kind,
                range: block.range,
                tokens: repair(block.tokens, blockIndex: index),
            )
        }
        return SegmentedDocument(blocks: blocks, sourceLength: document.sourceLength)
    }

    /// Repairs one run of tokens.
    ///
    /// Token ids are reassigned, because merging changes the indices. Ranges
    /// are taken from the endpoints of the merged span, which keeps the tiling
    /// invariant intact without recomputing anything.
    func repair(_ tokens: [Token], blockIndex: Int) -> [Token] {
        var result: [Token] = []
        var index = 0

        while index < tokens.count {
            let merged = longestMerge(in: tokens, from: index)
            if merged > 1,
               let first = tokens[safe: index],
               let last = tokens[safe: index + merged - 1]
            {
                let span = tokens[index ..< (index + merged)]
                result.append(Token(
                    id: TokenID(block: blockIndex, index: result.count),
                    text: span.map(\.text).joined(),
                    range: first.range.lowerBound ..< last.range.upperBound,
                    kind: .han,
                    trailingSpace: last.trailingSpace,
                ))
                index += merged
            } else {
                let token = tokens[index]
                result.append(Token(
                    id: TokenID(block: blockIndex, index: result.count),
                    text: token.text,
                    range: token.range,
                    kind: token.kind,
                    trailingSpace: token.trailingSpace,
                ))
                index += 1
            }
        }
        return result
    }

    /// How many tokens starting at `start` form a single dictionary word.
    ///
    /// Returns 1 when nothing merges. Only Han tokens are considered, and the
    /// span must be contiguous in the source — a merge across a gap would
    /// produce a token whose text does not match its own range.
    private func longestMerge(in tokens: [Token], from start: Int) -> Int {
        guard tokens[start].kind == .han else { return 1 }

        let limit = min(Self.maximumTokens, tokens.count - start)
        guard limit > 1 else { return 1 }

        var combined = tokens[start].text
        var best = 1
        var bestWeight = -Double.infinity

        for offset in 1 ..< limit {
            let next = tokens[start + offset]
            // Stop at anything that is not contiguous Han: punctuation and
            // spaces are real boundaries, and merging across one would be
            // wrong however plausible the resulting string looks.
            guard next.kind == .han,
                  next.range.lowerBound == tokens[start + offset - 1].range.upperBound
            else { break }

            combined += next.text
            guard combined.count <= LexiconBuilder.maximumWordLength else { break }
            // The best-weighted merge, not the longest. Preferring length
            // would contradict the penalty the lexicon carries and reach for
            // a rare long headword over a more plausible short one.
            if let weight = lexicon.weight(of: combined), weight > bestWeight {
                bestWeight = weight
                best = offset + 1
            }
        }
        return best
    }
}

extension Array {
    /// Bounds-checked access, so the merge path states its assumptions rather
    /// than force-unwrapping indices it computed itself.
    fileprivate subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
