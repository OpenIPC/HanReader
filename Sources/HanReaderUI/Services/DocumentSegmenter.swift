// HanReader — MIT licensed. See LICENSE.

import Foundation
import HanReaderCore

/// Segments a text and repairs the result, off the main actor.
///
/// A `Sendable` value with no state beyond its lexicon, so the whole job can
/// be handed to a background task. The prototype tokenized on the main actor
/// when a text was opened, which is what made opening a long document stall
/// the window.
///
/// The repair pass is not optional. Apple's tokenizer is good — 38 of 39
/// sampled tokens resolved against a dictionary — but it is *inconsistent*:
/// it keeps 这个 whole while splitting 一|个|人 and 三|个, even though 一个人
/// and 三个 are both headwords. Those splits produce tokens no dictionary
/// defines, so the reader would tap a word and be told it does not exist,
/// which reads as a dictionary failure rather than a segmentation one.
///
/// `nonisolated` deliberately. This module compiles with
/// `defaultIsolation(MainActor.self)`, which would otherwise make `segment`
/// main-actor-isolated and so impossible to run off the main thread — the
/// one thing this type exists to do.
nonisolated struct DocumentSegmenter: Sendable {
    private let tokenizer: any Tokenizing
    private let repair: DictionaryRepairPass

    init(tokenizer: some Tokenizing, lexicon: Lexicon) {
        self.tokenizer = tokenizer
        repair = DictionaryRepairPass(lexicon: lexicon)
    }

    func segment(_ text: String) -> SegmentedDocument {
        repair.repair(tokenizer.segment(text))
    }
}
