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

    /// Both spellings, deduplicated.
    ///
    /// Anything derived from headwords — the segmentation lexicon, the
    /// per-character reading table — has to cover both, or traditional text
    /// gets no words in the matcher and no fallback pinyin.
    public var bothScripts: [String] {
        guard let traditional else { return [simplified] }
        return [simplified, traditional]
    }
}

/// A reference from one entry to another, as it appears inside a gloss.
///
/// CC-CEDICT writes these inline — `see 獅子|狮子[shi1 zi5]` — and roughly one
/// gloss in eleven contains one. The range is kept so the UI can make just
/// that span tappable rather than linkifying the whole gloss or, worse,
/// showing the raw markup.
public struct CrossReference: Hashable, Sendable, Codable {
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
public struct Gloss: Hashable, Sendable, Codable {
    /// Display text, with cross-reference markup already resolved to the
    /// simplified form so it reads as prose.
    public let text: String
    public let references: [CrossReference]
    /// Emphasis within the text, as offsets rather than inline markup.
    ///
    /// Kept rather than flattened because BKRS italicises 631,732 spans,
    /// nearly all of them parenthetical grammatical notes — "(кого-л.)",
    /// "(о человеке)" — which read as part of the definition once the
    /// italics are gone. Dropping them is the difference between a gloss
    /// and a gloss with its asides folded into it.
    public let styles: [StyleRun]

    public init(text: String, references: [CrossReference] = [], styles: [StyleRun] = []) {
        self.text = text
        self.references = references
        self.styles = styles
    }

    private enum CodingKeys: String, CodingKey {
        case text, references, styles
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decode(String.self, forKey: .text)
        references = try container.decodeIfPresent([CrossReference].self, forKey: .references) ?? []
        styles = try container.decodeIfPresent([StyleRun].self, forKey: .styles) ?? []
    }

    /// Empty collections are omitted rather than written as `[]`.
    ///
    /// Every CC-CEDICT sense has no references and no styles, and writing
    /// the empty arrays anyway added 14 MB to a 35 MB bundled dictionary —
    /// 40% of the file, to say "nothing here" 107,619 times.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(text, forKey: .text)
        if !references.isEmpty {
            try container.encode(references, forKey: .references)
        }
        if !styles.isEmpty {
            try container.encode(styles, forKey: .styles)
        }
    }
}

/// How a span of a gloss is emphasised.
public enum TextStyle: String, Hashable, Sendable, Codable, CaseIterable {
    case bold
    case italic
    /// A coloured span. The source names a colour; what the reader sees is
    /// the app's own palette, because a dictionary's `brown` is not a
    /// colour that works on both a light and a dark page.
    case highlighted
}

/// One emphasised span of a gloss.
public struct StyleRun: Hashable, Sendable, Codable {
    public let style: TextStyle
    /// Where the span sits in the gloss, as a UTF-16 offset range — the
    /// unit `NSRange` and `AttributedString` both use, and the same unit
    /// `CrossReference` uses.
    public let range: Range<Int>

    public init(style: TextStyle, range: Range<Int>) {
        self.style = style
        self.range = range
    }
}

/// A sentence showing a word in use.
public struct UsageExample: Hashable, Sendable, Codable {
    /// The Chinese, if it could be separated from the translation.
    public let chinese: String
    /// The translation, which for BKRS is Russian.
    public let translation: String
    /// The example exactly as the dictionary wrote it.
    ///
    /// Always kept. The split between the two scripts is a heuristic over
    /// where the Han characters stop, and an example that splits badly must
    /// still be readable in full rather than silently truncated to whichever
    /// half the heuristic liked.
    public let raw: String

    public init(chinese: String, translation: String, raw: String) {
        self.chinese = chinese
        self.translation = translation
        self.raw = raw
    }
}

/// What kind of thing a sense is.
///
/// This is presentation metadata, not a learner feature: a sense that only
/// says "variant of 妳" is a poor choice for the one-line summary in the
/// reader's detail panel, and the UI needs to be able to prefer a real
/// definition when one exists.
public enum SenseKind: UInt8, Sendable, Hashable, Codable {
    case definition
    /// Points at another entry: `variant of`, `see also`, `abbr. for`.
    case reference
    /// A surname or other label rather than a meaning.
    case label
}

/// One numbered sense of an entry.
public struct Sense: Hashable, Sendable, Identifiable, Codable {
    public let id: Int
    public let kind: SenseKind
    public let gloss: Gloss

    /// How deeply this sense is nested, counting from zero.
    ///
    /// Flat rather than a tree, with `parent` carrying the structure. A flat
    /// list with an explicit level is isomorphic to a tree, encodes without
    /// recursion, and renders directly as an indented list — which is all
    /// the UI needs.
    public let level: Int
    /// The enclosing sense, or nil at the top.
    public let parent: Int?
    /// The dictionary's own numbering: `I`, `1)`, `а)`.
    ///
    /// Lifted out of the gloss rather than left at the front of it, so the
    /// reader can renumber or indent without the original marker appearing
    /// twice.
    public let label: String?
    /// Grammatical category: гл., сущ., прил.
    public let partOfSpeech: [String]
    /// Field or register: бот., ист., уст.
    public let registers: [String]
    public let examples: [UsageExample]

    public init(
        id: Int,
        kind: SenseKind,
        gloss: Gloss,
        level: Int = 0,
        parent: Int? = nil,
        label: String? = nil,
        partOfSpeech: [String] = [],
        registers: [String] = [],
        examples: [UsageExample] = [],
    ) {
        self.id = id
        self.kind = kind
        self.gloss = gloss
        self.level = level
        self.parent = parent
        self.label = label
        self.partOfSpeech = partOfSpeech
        self.registers = registers
        self.examples = examples
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, gloss, level, parent, label, partOfSpeech, registers, examples
    }

    /// Decoded field by field with defaults, so a container compiled before
    /// these fields existed still opens. A synthesised `init(from:)` fails
    /// on any missing key, which would turn a model addition into a forced
    /// re-import of a 3.4-million-entry dictionary.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        kind = try container.decode(SenseKind.self, forKey: .kind)
        gloss = try container.decode(Gloss.self, forKey: .gloss)
        level = try container.decodeIfPresent(Int.self, forKey: .level) ?? 0
        parent = try container.decodeIfPresent(Int.self, forKey: .parent)
        label = try container.decodeIfPresent(String.self, forKey: .label)
        partOfSpeech = try container.decodeIfPresent([String].self, forKey: .partOfSpeech) ?? []
        registers = try container.decodeIfPresent([String].self, forKey: .registers) ?? []
        examples = try container.decodeIfPresent([UsageExample].self, forKey: .examples) ?? []
    }

    /// Defaults are omitted, for the same reason as `Gloss`: a dictionary
    /// with no nesting, no numbering and no examples should not pay for
    /// the fields that describe them.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(kind, forKey: .kind)
        try container.encode(gloss, forKey: .gloss)
        if level != 0 {
            try container.encode(level, forKey: .level)
        }
        if let parent {
            try container.encode(parent, forKey: .parent)
        }
        if let label {
            try container.encode(label, forKey: .label)
        }
        if !partOfSpeech.isEmpty {
            try container.encode(partOfSpeech, forKey: .partOfSpeech)
        }
        if !registers.isEmpty {
            try container.encode(registers, forKey: .registers)
        }
        if !examples.isEmpty {
            try container.encode(examples, forKey: .examples)
        }
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
