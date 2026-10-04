// HanReader — MIT licensed. See LICENSE.

import Foundation

/// A reading to draw above a token, and where it came from.
///
/// The provenance is not a detail. 77% of BKRS entries carry no reading at
/// all, so for a reader using the Russian dictionary most words get their
/// pinyin assembled character by character from CC-CEDICT instead of looked up
/// whole. That composition is an approximation and it is **wrong for
/// heteronyms**: 了 is `le` or `liǎo` depending on use, and nothing here can
/// tell which without a part-of-speech tagger, which is out of scope.
///
/// So a composed reading renders more faintly than a looked-up one. The reader
/// can see which annotations the dictionary vouched for, without having to be
/// told in a release note that some of them are guesses.
nonisolated struct TokenReading: Hashable, Sendable {
    /// Pinyin with diacritics, as the reader should see it.
    ///
    /// Dictionary form, never sandhi-adjusted. Sandhi is positional, so
    /// applying it would render the same word differently in different
    /// sentences and defeat the recognition the annotation exists to build.
    /// `AVSpeechSynthesizer` applies its own sandhi, so a displayed `yī`
    /// spoken as `yí` is expected and documented rather than a bug.
    let display: String

    /// Whether this was assembled from per-character readings rather than
    /// found as a whole word.
    let isComposed: Bool
}
