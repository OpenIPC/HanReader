// HanReader — MIT licensed. See LICENSE.

import Foundation

/// A headword in its two scripts.
///
/// `traditional` is `nil` when the two forms are identical, which is the case
/// for 37% of CC-CEDICT. Storing `nil` rather than a duplicate keeps the
/// "are these different?" question a property of the model instead of a string
/// comparison repeated at every call site, and it is what the database schema
/// stores.
public struct Headword: Hashable, Sendable {
    public let simplified: String
    public let traditional: String?

    public init(simplified: String, traditional: String?) {
        self.simplified = simplified
        self.traditional = traditional == simplified ? nil : traditional
    }

    /// The traditional form, falling back to the simplified one.
    public var traditionalOrSimplified: String {
        traditional ?? simplified
    }

    /// Whether the two scripts actually differ, and so whether showing both
    /// tells the reader anything.
    public var scriptsDiffer: Bool {
        traditional != nil
    }
}

/// A reference from one entry to another, as it appears inside a gloss.
///
/// CC-CEDICT writes these inline — `see 獅子|狮子[shi1 zi5]` — and roughly one
/// gloss in eleven contains one. The range is kept so the UI can make just
/// that span tappable rather than linkifying the whole gloss or, worse,
/// showing the raw markup.
public struct CrossReference: Hashable, Sendable {
    public let simplified: String
    public let traditional: String?
    /// The reading as written in the reference, if it carried one.
    public let reading: String?
    /// Where the reference sits in the gloss text, as a UTF-16 offset range —
    /// the unit `NSRange` and `AttributedString` both use.
    public let range: Range<Int>

    public init(simplified: String, traditional: String?, reading: String?, range: Range<Int>) {
        self.simplified = simplified
        self.traditional = traditional
        self.reading = reading
        self.range = range
    }
}

/// One gloss: a line of meaning, plus any references found inside it.
public struct Gloss: Hashable, Sendable {
    /// Display text, with cross-reference markup already resolved to the
    /// simplified form so it reads as prose.
    public let text: String
    public let references: [CrossReference]

    public init(text: String, references: [CrossReference] = []) {
        self.text = text
        self.references = references
    }
}

/// What kind of thing a sense is.
///
/// This is presentation metadata, not a learner feature: a sense that only
/// says "variant of 妳" is a poor choice for the one-line summary in the
/// reader's detail panel, and the UI needs to be able to prefer a real
/// definition when one exists.
public enum SenseKind: UInt8, Sendable, Hashable {
    case definition
    /// Points at another entry: `variant of`, `see also`, `abbr. for`.
    case reference
    /// A surname or other label rather than a meaning.
    case label
}

/// One numbered sense of an entry.
public struct Sense: Hashable, Sendable, Identifiable {
    public let id: Int
    public let kind: SenseKind
    public let gloss: Gloss

    public init(id: Int, kind: SenseKind, gloss: Gloss) {
        self.id = id
        self.kind = kind
        self.gloss = gloss
    }
}

/// A single dictionary entry: one headword with one reading.
///
/// Deliberately **not** keyed on the headword alone. CC-CEDICT has 107,619
/// entries over 104,460 distinct simplified forms: 和 has eight, 宿 five, and
/// 了 is both `le` and `liǎo`. An entry is therefore identified by headword
/// *and* reading, and a lookup returns a list.
public struct DictionaryEntry: Hashable, Sendable {
    public let headword: Headword
    /// The reading, parsed. Kept as tokens rather than a string so it can be
    /// rendered in any style and compared across dictionaries.
    public let reading: [PinyinToken]
    public let senses: [Sense]

    public init(headword: Headword, reading: [PinyinToken], senses: [Sense]) {
        self.headword = headword
        self.reading = reading
        self.senses = senses
    }

    /// The reading in CC-CEDICT's numeric style.
    ///
    /// This is the cross-dictionary merge key: BKRS stores diacritics and
    /// CC-CEDICT numerals, and both normalise to this so that 了's two
    /// readings group correctly rather than appearing as four entries.
    public var readingKey: String {
        Pinyin.display(reading, style: .numeric)
    }

    /// The reading as a reader should see it.
    public var readingDisplay: String {
        Pinyin.display(reading, style: .diacritic)
    }

    /// The first sense that actually defines something, falling back to the
    /// first of any kind. Used for one-line summaries, where "variant of 妳"
    /// is close to useless.
    public var summarySense: Sense? {
        senses.first { $0.kind == .definition } ?? senses.first
    }
}
