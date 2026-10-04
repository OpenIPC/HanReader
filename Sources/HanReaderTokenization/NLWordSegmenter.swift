// HanReader — MIT licensed. See LICENSE.

import Foundation
public import HanReaderCore
import NaturalLanguage

/// Splits Han runs using Apple's `NLTokenizer`.
///
/// The only place `NaturalLanguage` is imported, which a SwiftLint rule and a
/// Linux CI build both enforce. Its segmentation quality is good — measured on
/// macOS 26 it correctly produced `不好意思`, `阅兵式`, `出差`, `高铁` and
/// `好吃` — and 38 of 39 sampled tokens had a dictionary entry, so the feared
/// "tapped word has no definition" problem is small for ordinary prose.
///
/// What it is **not** is stable. The model is closed and its output for a
/// given sentence can change with an OS release, so no test may assert its
/// exact segmentation; the suite pins `MaxMatchSegmenter` instead and checks
/// only coarse invariants here. Its other weakness is inconsistency rather
/// than inaccuracy — it keeps `这个` but splits `一 | 个 | 人` — which
/// `DictionaryRepairPass` is there to clean up.
public struct NLWordSegmenter: HanWordSegmenting {
    public init() {}

    public func split(_ run: String) -> [String] {
        guard !run.isEmpty else { return [] }

        // Allocated per call rather than stored. `NLTokenizer` is a reference
        // type and not `Sendable`, so a stored instance could not be shared
        // across concurrency domains; the prototype allocated one per
        // *paragraph* inside its loop, which was the same cost for no
        // isolation benefit.
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.setLanguage(.simplifiedChinese)
        tokenizer.string = run

        var words: [String] = []
        var cursor = run.startIndex

        tokenizer.enumerateTokens(in: run.startIndex ..< run.endIndex) { range, _ in
            // Anything the tokenizer skipped still belongs to the output.
            // Dropping it would break the invariant that the pieces
            // concatenate back to the input -- which the prototype violated,
            // losing spaces from any text mixing Latin with Chinese.
            if range.lowerBound > cursor {
                words.append(String(run[cursor ..< range.lowerBound]))
            }
            words.append(String(run[range]))
            cursor = range.upperBound
            return true
        }

        if cursor < run.endIndex {
            words.append(String(run[cursor...]))
        }
        return words
    }
}

extension TextSegmenter where WordSegmenter == NLWordSegmenter {
    /// A segmenter using Apple's tokenizer.
    public static func system() -> TextSegmenter<NLWordSegmenter> {
        TextSegmenter(words: NLWordSegmenter())
    }
}
