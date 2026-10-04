// HanReader — MIT licensed. See LICENSE.

/// A Mandarin tone.
///
/// The raw values match CC-CEDICT's numeric convention, where the neutral tone
/// is written `5`. Note that `0` is *not* used for the neutral tone anywhere in
/// HanReader, and `ma0` is never produced: the neutral tone renders with no
/// diacritic at all, and as `5` in numeric style.
public enum Tone: UInt8, Sendable, Hashable, CaseIterable {
    case first = 1
    case second = 2
    case third = 3
    case fourth = 4
    case neutral = 5

    /// The combining mark that renders this tone, or `nil` for the neutral
    /// tone, which carries none.
    ///
    /// Used only by the no-vowel fallback in ``PinyinSyllable/diacritic``;
    /// ordinary syllables are rendered from a precomposed table instead,
    /// because precomposed characters are what fonts and search expect.
    var combiningMark: Unicode.Scalar? {
        switch self {
        case .first: "\u{0304}" // macron
        case .second: "\u{0301}" // acute
        case .third: "\u{030C}" // caron
        case .fourth: "\u{0300}" // grave
        case .neutral: nil
        }
    }
}
