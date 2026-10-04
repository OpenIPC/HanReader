// HanReader — MIT licensed. See LICENSE.

import Foundation

/// What a token is made of.
///
/// Replaces the prototype's two booleans (`isPunctuation`, `isNewline`), which
/// could not express the thing that actually matters: Latin text and digits
/// inside Chinese prose. `iPhone 15` was classified as punctuation.
public enum TokenKind: UInt8, Sendable, Hashable, Codable {
    /// A Han ideograph, or a run of them forming a word.
    case han
    /// A run of Latin letters, kept whole: `iPhone`, `OK`.
    case latin
    /// A run of digits, kept whole: `15`, `2026`.
    case number
    case punctuation
    case whitespace
    /// Anything else — emoji, symbols, other scripts.
    case other
}

/// Classifies characters for the tokenizer.
///
/// Uses Unicode properties rather than hand-rolled block ranges. The
/// prototype listed two blocks plus a `Set<Unicode.Scalar>`, which was
/// simultaneously **incomplete** — it missed CJK Extension B and 〇 — and
/// **over-broad**: its U+FF00–U+FFEF range swept in fullwidth Latin letters
/// and halfwidth katakana, so `ＡＢＣ１２３` came out as punctuation.
public enum ScalarClass {
    /// Whether this is a Han ideograph.
    ///
    /// `isIdeographic` covers the unified ideographs and all the extensions,
    /// including the supplementary-plane ones. The compatibility block is
    /// added explicitly because those characters are ideographs in practice
    /// but are not all flagged as such.
    public static func isHan(_ scalar: Unicode.Scalar) -> Bool {
        if scalar.properties.isIdeographic {
            return true
        }
        // CJK Compatibility Ideographs.
        if (0xF900 ... 0xFAFF).contains(scalar.value) {
            return true
        }
        if (0x2F800 ... 0x2FA1F).contains(scalar.value) {
            return true
        }
        return false
    }

    /// Classifies a single scalar.
    public static func classify(_ scalar: Unicode.Scalar) -> TokenKind {
        if isHan(scalar) {
            return .han
        }
        if scalar.properties.isWhitespace {
            return .whitespace
        }

        switch scalar.properties.generalCategory {
        case .decimalNumber, .letterNumber, .otherNumber:
            return .number
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter,
             .modifierLetter, .otherLetter:
            // Han is handled above, so a remaining letter is some other
            // script. Latin is the case worth separating, because it forms
            // words that must not be split character by character.
            return isLatin(scalar) ? .latin : .other
        case .connectorPunctuation, .dashPunctuation, .openPunctuation,
             .closePunctuation, .initialPunctuation, .finalPunctuation,
             .otherPunctuation, .mathSymbol, .currencySymbol,
             .modifierSymbol:
            // Math, currency and modifier symbols behave like punctuation for
            // layout. `otherSymbol` deliberately does NOT: it is where emoji
            // and pictographs live, and they are neither punctuation nor
            // candidates for the line-breaking rules that glue CJK marks to
            // their neighbours.
            return .punctuation
        default:
            return .other
        }
    }

    /// Whether a scalar belongs to the Latin script, including the fullwidth
    /// forms that the prototype misclassified as punctuation.
    public static func isLatin(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x41 ... 0x5A, 0x61 ... 0x7A: true // ASCII
        case 0xC0 ... 0x24F: true // Latin-1 Supplement, Extended-A and -B
        case 0x1E00 ... 0x1EFF: true // Latin Extended Additional
        case 0xFF21 ... 0xFF3A, 0xFF41 ... 0xFF5A: true // fullwidth A-Z, a-z
        default: false
        }
    }

    /// Whether a scalar is a digit, in any of its widths.
    public static func isDigit(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x30 ... 0x39: true // ASCII
        case 0xFF10 ... 0xFF19: true // fullwidth ０-９
        default: scalar.properties.generalCategory == .decimalNumber
        }
    }
}

extension Character {
    /// Whether this character is a Han ideograph.
    public var isHanCharacter: Bool {
        unicodeScalars.contains(where: ScalarClass.isHan)
    }

    /// The kind of token this character would start.
    public var tokenKind: TokenKind {
        guard let first = unicodeScalars.first else { return .other }
        return ScalarClass.classify(first)
    }
}
