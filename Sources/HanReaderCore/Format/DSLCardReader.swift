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
        // Any horizontal whitespace, not a literal space. `#INCLUDE\t"b.dsl"`
        // is a legal directive, and reading it as an unknown one leaves the
        // include list empty and the other volumes undiscovered.
        let split = rest.firstIndex { $0 == " " || $0 == "\t" }
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
    /// Byte offset of the card's first headword line, or nil when the card has
    /// no resume point in this file.
    ///
    /// The resume point is a card boundary rather than a line or a batch
    /// boundary because that is the only place an importer can restart without
    /// either losing a card or writing one twice.
    ///
    /// Nil for one case: a card whose headword was carried in from the
    /// previous file of the set. No offset in *this* file restarts at it, and
    /// an importer that checkpointed there would resume past the headword and
    /// lose the card. A reader that needs a resume point for such a card wants
    /// the previous file's, which it already has.
    public let offset: Int?

    public init(card: DSLCard, offset: Int?) {
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
    /// Byte offset of each headword line, parallel to `headwords`. Shorter
    /// than it when headwords were carried in from the previous file, which is
    /// how a seam-completed card knows it has no resume point of its own.
    private var headwordOffsets: [Int] = []
    private var body: [String] = []

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
                headwordOffsets = [line.offset]
                return record
            }
            headwords.append(text)
            headwordOffsets.append(line.offset)
        }
        return finalCard()
    }

    // MARK: - Cards

    private mutating func takeCard() -> DSLCardRecord {
        let split = Self.readingLineCount(in: body)
        let record = DSLCardRecord(
            card: DSLCard(
                headwords: headwords,
                pinyin: split == 1 ? body[0] : "",
                body: Array(body.dropFirst(split)),
            ),
            // Nil when the headwords came from the previous file: there is no
            // offset in *this* file that would restart at this card, and
            // offering zero would restart at the file's byte-order mark and
            // lose the headword entirely.
            offset: headwordOffsets.count == headwords.count ? headwordOffsets.first : nil,
        )
        headwords.removeAll(keepingCapacity: true)
        headwordOffsets.removeAll(keepingCapacity: true)
        body.removeAll(keepingCapacity: true)
        return record
    }

    /// Whether the article's first line is a reading, as 1 or 0.
    ///
    /// A reading line is a convention of Chinese dictionaries rather than a
    /// rule of the format, so it is detected rather than assumed. Two
    /// conditions, both measured against all 3,434,224 BKRS cards:
    ///
    /// - **It contains no `[mN]`.** Zero reading lines in the set do, and an
    ///   article's first line effectively always does. 287 reading lines *do*
    ///   carry other markup — `lùzhóu, [i]разг.[/i] liùzhóu` — so the test has
    ///   to be the sense tag specifically and not markup in general.
    /// - **Something follows it.** A card with one indented line and no
    ///   markup is genuinely ambiguous, and the two mistakes are not equal: a
    ///   reading with no definition is not an entry worth having, while a
    ///   definition read as a reading leaves the entry saying nothing at all.
    ///
    /// Without the first condition a dictionary that writes no readings — the
    /// format does not require them — loses its first line of every article.
    static func readingLineCount(in body: [String]) -> Int {
        guard body.count > 1, let first = body.first, !containsSenseTag(first) else { return 0 }
        return 1
    }

    /// Whether a line opens a sense. Scans scalars, as all markup must: `]`
    /// followed by a zero-width non-joiner is a single `Character`.
    private static func containsSenseTag(_ line: String) -> Bool {
        let scalars = Array(line.unicodeScalars)
        guard scalars.count >= 4 else { return false }
        for index in 0 ... (scalars.count - 4) {
            guard scalars[index] == "[", scalars[index + 1] == "m",
                  scalars[index + 2].properties.numericType != nil,
                  scalars[index + 2].isASCII,
                  scalars[index + 3] == "]"
            else { continue }
            // An escaped `\[` is a literal bracket, not a tag.
            if index > 0, scalars[index - 1] == "\\" {
                continue
            }
            return true
        }
        return false
    }

    /// At end of file: a complete card, or a dangling headword reported and
    /// handed to `trailingHeadwords`.
    private mutating func finalCard() -> DSLCardRecord? {
        guard !headwords.isEmpty else { return nil }
        guard !body.isEmpty else {
            // Each headword reports its own line. Sharing the first one's
            // offset across a run of them points every diagnostic but the
            // first at the wrong place in the file.
            let carried = headwords.count - headwordOffsets.count
            for (index, headword) in headwords.enumerated() {
                diagnostics.append(DSLDiagnostic(
                    kind: .headwordWithoutBody,
                    text: headword,
                    offset: index < carried ? nil : headwordOffsets[index - carried],
                ))
            }
            trailingHeadwords = headwords
            headwords.removeAll()
            headwordOffsets.removeAll()
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
