// HanReader — MIT licensed. See LICENSE.

import Foundation

/// What a DSL file's `#` directives say about itself.
///
/// Read rather than assumed. The predecessor prototype hardcoded the three
/// BKRS filenames and took the dictionary's name from a constant in the source
/// — so importing any other DSL dictionary mislabelled it, and importing a
/// renamed copy of this one failed outright. Everything here comes out of the
/// file.
public struct DSLHeader: Hashable, Sendable {
    /// `#NAME` — what the dictionary calls itself: `大БКРС - 250920 ( 1 / 3 )`.
    public var name: String?
    /// `#INDEX_LANGUAGE` — the language of the headwords.
    public var indexLanguage: String?
    /// `#CONTENTS_LANGUAGE` — the language of the definitions. This is what
    /// decides whether a Russian-locale reader sees this dictionary first.
    public var contentsLanguage: String?
    /// `#INCLUDE` targets, as written: file names relative to this file.
    public var includes: [String] = []
    /// Every other directive, keyed by name without the `#`.
    ///
    /// Kept rather than discarded, because a directive this version has not
    /// heard of is still something the dictionary chose to state.
    public var other: [String: String] = [:]

    public init() {}

    /// Reads a directive line.
    ///
    /// The name runs to the first space; the value is the rest, with one layer
    /// of surrounding quotes removed. A directive with no value records the
    /// empty string, which is distinguishable from absent.
    mutating func consume(directive line: String) {
        let rest = line.dropFirst()
        let split = rest.firstIndex(of: " ")
        let directive = String(split.map { rest[rest.startIndex ..< $0] } ?? rest)
        let rawValue = split.map { String(rest[rest.index(after: $0)...]) } ?? ""
        let value = Self.unquote(rawValue.trimmingCharacters(in: .whitespaces))

        switch directive {
        case "NAME": name = value
        case "INDEX_LANGUAGE": indexLanguage = value
        case "CONTENTS_LANGUAGE": contentsLanguage = value
        case "INCLUDE": includes.append(value)
        default: other[directive] = value
        }
    }

    private static func unquote(_ value: String) -> String {
        guard value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") else { return value }
        return String(value.dropFirst().dropLast())
    }
}

/// One card, and where it starts.
public struct DSLCardRecord: Hashable, Sendable {
    public let card: DSLCard
    /// Byte offset of the card's first headword line.
    ///
    /// The resume point. It is recorded at a card boundary rather than at a
    /// line or a batch boundary because that is the only place the importer can
    /// restart without either losing a card or writing one twice.
    public let offset: Int

    public init(card: DSLCard, offset: Int) {
        self.card = card
        self.offset = offset
    }
}

/// Groups a DSL file's lines into cards.
///
/// The structure is positional, and that is the whole of it:
///
/// ```
/// 爱                       ← unindented: a headword
///  ài                      ← first indented line: the reading
///  [m1][b]I[/b] …          ← the rest: the article
/// ```
///
/// ### Three line kinds, and the order the tests go in
///
/// An indented line is article text; an unindented line starting with `#` is a
/// directive; anything else unindented is a headword. Indentation is tested
/// first, so an indented line beginning with `#` stays article text rather
/// than being read as a directive — the format escapes a literal leading `#`,
/// but only on an unindented line, where it would be ambiguous.
///
/// ### Consecutive headwords are one card
///
/// The DSL spec lets several spellings share one article, written as
/// consecutive unindented lines. BKRS never does — all 3,434,224 cards have
/// exactly one headword — but accepting it costs two lines and refusing it
/// would be a parser bug waiting for the next dictionary.
///
/// ### A card's article is not always one line
///
/// This set writes each card's entire sense run on a single physical line,
/// which is what made the predecessor's "one line is one sense" reading
/// produce exactly one sense per card. Exactly one card in the set —
/// 乐芙兰 — breaks a line *inside* an open `[m1]`, and most other DSL
/// dictionaries write one sense per line. So the article is a list of lines
/// and the sense structure is read from the markup, never from the line count.
public struct DSLCardReader {
    /// What the file says about itself, filled in as directives are read.
    /// Complete once the first card has been returned.
    public private(set) var header = DSLHeader()
    public private(set) var diagnostics: [DSLDiagnostic] = []
    /// Headwords found at the end of the file with no article under them.
    ///
    /// Empty for a card-aligned file. A file split on a byte boundary leaves
    /// its last headword here, and the matching article arrives as
    /// `bodyWithoutHeadword` diagnostics at the start of the next file; a
    /// multi-file driver repairs the seam by passing these in as
    /// `leadingHeadwords`.
    public private(set) var trailingHeadwords: [String] = []

    private var lines: DSLByteReader
    private var headwords: [String]
    private var body: [String] = []
    private var cardOffset = 0

    public init(
        source: any DSLByteSource,
        resumingAt offset: Int? = nil,
        leadingHeadwords: [String] = [],
        chunkSize: Int = DSLByteReader.defaultChunkSize,
    ) throws {
        lines = try DSLByteReader(
            source: source,
            resumingAt: offset,
            chunkSize: chunkSize,
        )
        headwords = leadingHeadwords
        cardOffset = offset ?? 0
    }

    /// How the file spells its characters.
    public var encoding: DSLByteEncoding {
        lines.encoding
    }

    /// The next card, or nil at end of file.
    public mutating func next() throws -> DSLCardRecord? {
        while let line = try lines.next() {
            let text = line.text
            if text.isEmpty {
                continue
            }

            if let article = Self.stripIndent(text) {
                guard !headwords.isEmpty else {
                    diagnostics.append(DSLDiagnostic(
                        kind: .bodyWithoutHeadword,
                        text: text,
                        offset: line.offset,
                    ))
                    continue
                }
                body.append(article)
                continue
            }

            if text.hasPrefix("#") {
                header.consume(directive: text)
                continue
            }

            // A headword. If an article has already been collected, the card
            // above this line is complete.
            guard body.isEmpty else {
                let record = takeCard()
                headwords = [text]
                cardOffset = line.offset
                return record
            }
            if headwords.isEmpty {
                cardOffset = line.offset
            }
            headwords.append(text)
        }
        return finalCard()
    }

    // MARK: - Cards

    private mutating func takeCard() -> DSLCardRecord {
        let record = DSLCardRecord(
            card: DSLCard(
                headwords: headwords,
                pinyin: body.first ?? "",
                body: Array(body.dropFirst()),
            ),
            offset: cardOffset,
        )
        headwords.removeAll(keepingCapacity: true)
        body.removeAll(keepingCapacity: true)
        return record
    }

    /// At end of file: a complete card, or a dangling headword reported and
    /// handed to `trailingHeadwords`.
    private mutating func finalCard() -> DSLCardRecord? {
        guard !headwords.isEmpty else { return nil }
        guard !body.isEmpty else {
            for headword in headwords {
                diagnostics.append(DSLDiagnostic(
                    kind: .headwordWithoutBody,
                    text: headword,
                    offset: cardOffset,
                ))
            }
            trailingHeadwords = headwords
            headwords.removeAll()
            return nil
        }
        return takeCard()
    }

    /// Returns the line without its indent, or nil if it was not indented.
    ///
    /// All leading horizontal whitespace goes, not just the first character.
    /// DSL carries nesting in `[mN]`, never in indent depth, so a line indented
    /// two spaces means exactly what one indented by one means — and leaving
    /// the extra space in would put it inside the gloss.
    static func stripIndent(_ line: String) -> String? {
        guard let first = line.unicodeScalars.first, first == " " || first == "\t" else {
            return nil
        }
        return String(line.drop { $0 == " " || $0 == "\t" })
    }
}

extension DSLHeader {
    /// Reads just the directive block at the top of a file.
    ///
    /// Stops at the first line that is neither blank nor a directive, so
    /// discovering a file set costs one chunk rather than a pass over 116 MB.
    public static func read(from source: any DSLByteSource) throws -> DSLHeader {
        var reader = try DSLByteReader(source: source)
        var header = DSLHeader()
        while let line = try reader.next() {
            if line.text.isEmpty {
                continue
            }
            guard line.text.hasPrefix("#") else { break }
            header.consume(directive: line.text)
        }
        return header
    }
}
