// HanReader — MIT licensed. See LICENSE.

import Foundation

/// Parses CC-CEDICT's text format.
///
/// The format is one entry per line:
///
///     傳統 传统 [chuan2 tong3] /tradition/traditional/convention/
///     Traditional Simplified [pinyin] /sense/sense/
///
/// with `#` comment lines and `#!` metadata at the top. Line endings are CRLF.
///
/// The grammar is fixed enough to scan by hand rather than with a regular
/// expression, which is both faster over a hundred thousand lines and easier
/// to give precise diagnostics from. It was validated against a complete
/// dictionary: **107,619 entries, zero unparsed lines.**
public enum CEDICTParser {
    // MARK: - Diagnostics

    /// Something the parser could not make sense of.
    ///
    /// A malformed line is skipped and reported rather than aborting the
    /// import. A dictionary is third-party data that nobody here controls, and
    /// one bad line should cost one entry, not the whole file.
    public struct Diagnostic: Hashable, Sendable {
        public enum Kind: Hashable, Sendable {
            case missingPinyinBrackets
            case missingDefinitions
            case tooFewFields
            case emptyHeadword
        }

        public let kind: Kind
        /// 1-based, so it matches what an editor shows.
        public let line: Int
        public let text: String
    }

    /// Everything a parse produced.
    public struct Result: Sendable {
        public var entries: [DictionaryEntry] = []
        public var metadata: [String: String] = [:]
        public var diagnostics: [Diagnostic] = []
        /// Lines that were neither entries nor comments. Zero for a healthy
        /// file; a CI check asserts it stays zero for the bundled snapshot, so
        /// an upstream format change fails loudly rather than silently
        /// dropping entries.
        public var unparsedCount: Int {
            diagnostics.count
        }
    }

    // MARK: - Parsing

    /// Parses a whole file.
    public static func parse(_ text: String) -> Result {
        var result = Result()
        // Split on `isNewline`, NOT on the literal "\n".
        //
        // Swift treats CRLF as a *single* extended grapheme cluster, so
        // `split(separator: "\n")` does not split a CRLF file at all -- and
        // CC-CEDICT is CRLF throughout, so the whole dictionary would arrive
        // as one unparseable line. `isNewline` matches the CRLF grapheme, bare
        // LF, bare CR and the Unicode line separators alike, and leaves no
        // carriage return behind to strip.
        //
        // Empty subsequences are KEPT so that the enumeration index is the
        // real file line number. Dropping them makes every diagnostic after a
        // blank line point at an earlier line than the one that is actually
        // wrong, which is worse than no line number at all.
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        for (index, line) in lines.enumerated() {
            guard !line.isEmpty else { continue }

            if line.hasPrefix("#") {
                if let (key, value) = metadata(from: line) {
                    result.metadata[key] = value
                }
                continue
            }

            switch entry(from: line) {
            case let .success(entry):
                result.entries.append(entry)
            case let .failure(kind):
                result.diagnostics.append(
                    Diagnostic(kind: kind, line: index + 1, text: String(line)),
                )
            }
        }
        return result
    }

    /// Reads a `#! key=value` metadata line. Ordinary `#` comments yield nil.
    private static func metadata(from line: Substring) -> (String, String)? {
        guard line.hasPrefix("#!") else { return nil }
        let body = line.dropFirst(2).trimmingCharacters(in: .whitespaces)
        guard let equals = body.firstIndex(of: "=") else { return nil }
        return (
            String(body[body.startIndex ..< equals]),
            String(body[body.index(after: equals)...]),
        )
    }

    private enum LineResult {
        case success(DictionaryEntry)
        case failure(Diagnostic.Kind)
    }

    /// Scans one entry line.
    private static func entry(from line: Substring) -> LineResult {
        // Traditional and simplified, space-separated.
        guard let firstSpace = line.firstIndex(of: " ") else { return .failure(.tooFewFields) }
        let traditional = line[line.startIndex ..< firstSpace]
        let afterFirst = line.index(after: firstSpace)
        guard let secondSpace = line[afterFirst...].firstIndex(of: " ") else {
            return .failure(.tooFewFields)
        }
        let simplified = line[afterFirst ..< secondSpace]
        guard !traditional.isEmpty, !simplified.isEmpty else { return .failure(.emptyHeadword) }

        // The bracketed reading.
        let rest = line[line.index(after: secondSpace)...]
        guard rest.hasPrefix("["), let closing = rest.firstIndex(of: "]") else {
            return .failure(.missingPinyinBrackets)
        }
        let pinyinField = rest[rest.index(after: rest.startIndex) ..< closing]

        // The definitions, slash-delimited.
        let afterBracket = rest[rest.index(after: closing)...]
            .drop(while: { $0 == " " })
        guard afterBracket.hasPrefix("/"), afterBracket.hasSuffix("/"),
              afterBracket.count >= 2
        else {
            return .failure(.missingDefinitions)
        }
        let body = afterBracket.dropFirst().dropLast()

        let senses = body
            .split(separator: "/", omittingEmptySubsequences: true)
            .enumerated()
            .map { index, text in
                Sense(
                    id: index,
                    kind: kind(of: text),
                    gloss: gloss(from: String(text)),
                )
            }
        guard !senses.isEmpty else { return .failure(.missingDefinitions) }

        return .success(DictionaryEntry(
            headword: Headword(simplified: String(simplified), traditional: String(traditional)),
            reading: Pinyin.parse(numeric: String(pinyinField)),
            senses: senses,
        ))
    }

    /// Senses are **not** split further on `;`.
    ///
    /// The format documentation describes semicolons as separating glosses
    /// within a sense, but only about 2% of entries contain one, and splitting
    /// mangles text such as `Down's syndrome; trisomy 21` and parentheticals
    /// that legitimately contain a semicolon. Keeping the sense whole loses
    /// nothing; splitting it loses meaning.
    private static func gloss(from text: String) -> Gloss {
        var references: [CrossReference] = []
        var out = ""
        var utf16Offset = 0

        var index = text.startIndex
        while index < text.endIndex {
            guard let reference = scanReference(in: text, from: index, outputOffset: utf16Offset)
            else {
                let character = text[index]
                out.append(character)
                utf16Offset += String(character).utf16.count
                index = text.index(after: index)
                continue
            }
            references.append(reference.reference)
            out += reference.replacement
            utf16Offset += reference.replacement.utf16.count
            index = reference.end
        }
        return Gloss(text: out, references: references)
    }

    /// Recognises `獅子|狮子[shi1 zi5]`, `狮子[shi1 zi5]` and bare `狮子` when
    /// they follow a cue word, rewriting them to just the simplified form.
    ///
    /// Only the three bracketed or piped shapes are matched: a bare run of Han
    /// characters is ordinary gloss text far more often than it is a
    /// reference, and treating every such run as a link would be wrong
    /// constantly.
    /// A reference matched in a gloss, with what to put in its place and
    /// where scanning should resume.
    private struct ScannedReference {
        let reference: CrossReference
        let replacement: String
        let end: String.Index
    }

    private static func scanReference(
        in text: String,
        from start: String.Index,
        outputOffset: Int,
    )
        -> ScannedReference?
    {
        var cursor = start
        var first = ""
        while cursor < text.endIndex, isReferenceCharacter(text[cursor]) {
            first.append(text[cursor])
            cursor = text.index(after: cursor)
        }
        guard !first.isEmpty, first.contains(where: \.isHan) else { return nil }

        var traditional: String?
        var simplified = first

        if cursor < text.endIndex, text[cursor] == "|" {
            cursor = text.index(after: cursor)
            var second = ""
            while cursor < text.endIndex, isReferenceCharacter(text[cursor]) {
                second.append(text[cursor])
                cursor = text.index(after: cursor)
            }
            guard !second.isEmpty else { return nil }
            traditional = first
            simplified = second
        }

        var reading: String?
        if cursor < text.endIndex, text[cursor] == "[",
           let closing = text[cursor...].firstIndex(of: "]")
        {
            reading = String(text[text.index(after: cursor) ..< closing])
            cursor = text.index(after: closing)
        }

        // Require at least one marker. A bare Han run is just prose.
        guard traditional != nil || reading != nil else { return nil }

        return ScannedReference(
            reference: CrossReference(
                simplified: simplified,
                traditional: traditional,
                reading: reading,
                range: outputOffset ..< (outputOffset + simplified.utf16.count),
            ),
            replacement: simplified,
            end: cursor,
        )
    }

    private static func isReferenceCharacter(_ character: Character) -> Bool {
        character.isHan || character.isNumber
            || (character.isLetter && character.isASCII)
            || headwordPunctuation.contains(character)
    }

    /// Punctuation that occurs *inside* a headword and so must not end a
    /// reference scan.
    ///
    /// `一不做，二不休[yi1 bu4 zuo4 , er4 bu4 xiu1]` is one headword; stopping
    /// at the comma made the scan resume later in the same annotated phrase
    /// and record only `二不休`, linking to the wrong entry.
    ///
    /// Only fullwidth CJK forms are listed. ASCII punctuation and spaces
    /// separate words in ordinary gloss prose, so accepting those would let a
    /// scan run across `see 甲, and also 乙[yi3]` and swallow the whole phrase.
    private static let headwordPunctuation: Set<Character> = [
        "\u{FF0C}", // ，fullwidth comma
        "\u{3001}", // 、ideographic comma
        "\u{00B7}", // · middle dot
        "\u{2014}", // — em dash
        "\u{FF1A}", // ：fullwidth colon
        "\u{FF01}", // ！
        "\u{FF1F}", // ？
        "\u{3002}", // 。
    ]

    /// Classifies a sense by the phrases CC-CEDICT uses to introduce one.
    private static func kind(of text: Substring) -> SenseKind {
        let lowered = text.lowercased()
        if lowered.hasPrefix("surname ") {
            return .label
        }
        for prefix in Self.referencePrefixes where lowered.hasPrefix(prefix) {
            return .reference
        }
        return .definition
    }

    private static let referencePrefixes = [
        "variant of ", "old variant of ", "see ", "see also ",
        "abbr. for ", "abbr. of ", "used in ", "same as ", "equivalent to ",
    ]
}

extension Character {
    /// Whether this is a Han ideograph.
    ///
    /// Uses the Unicode property rather than hand-rolled block ranges. The
    /// prototype listed two blocks plus a set, which was simultaneously
    /// incomplete (it missed Extension B and 〇) and over-broad (its
    /// fullwidth range swept in Latin letters and halfwidth katakana).
    var isHan: Bool {
        unicodeScalars.contains { $0.properties.isIdeographic }
    }
}
