// HanReader — MIT licensed. See LICENSE.

import Foundation

/// What a DSL markup tag means.
///
/// The complete set, not a guess at one. A full scan of the 3,434,224-card
/// BKRS set finds exactly these and nothing else once escapes are handled
/// first — so an unknown tag is a real anomaly worth a diagnostic rather
/// than the routine occurrence a looser parser would treat it as.
///
/// Counts from that scan, which are the reason each case exists:
///
/// | tag | occurrences |
/// |---|---|
/// | `[m1]`…`[m4]` | 3,690,060 opens |
/// | `[i]` | 631,732 |
/// | `[p]` | 395,878 |
/// | `[ref]` | 192,496 |
/// | `[*]` | 175,480 |
/// | `[ex]` | 175,356 |
/// | `[c]` | 123,968 |
/// | `[b]` | 51,342 |
public enum DSLTagKind: String, Hashable, Sendable, CaseIterable {
    /// `[mN]` — a sense at nesting level N. Closed by a bare `[/m]`.
    case sense
    /// `[b]` — bold, used for the Roman numeral heading a division.
    case bold
    /// `[i]` — italic. 631,732 of them, nearly all parenthetical
    /// grammatical notes, which read far better italicised than flattened.
    case italic
    /// `[p]` — a part-of-speech or register label: гл., сущ., бот., уст.
    case grammar
    /// `[c]` — colour, with an optional argument such as `brown`.
    case colour
    /// `[ex]` — a usage example.
    case example
    /// `[*]` — a block that usually wraps an example.
    case exampleBlock
    /// `[ref]` — a cross-reference to another headword.
    case reference

    /// The spelling that opens this tag, ignoring `[mN]`'s level.
    var openingName: String {
        switch self {
        case .sense: "m"
        case .bold: "b"
        case .italic: "i"
        case .grammar: "p"
        case .colour: "c"
        case .example: "ex"
        case .exampleBlock: "*"
        case .reference: "ref"
        }
    }
}

/// One opening tag, with whatever it carried.
public struct DSLTag: Hashable, Sendable {
    public let kind: DSLTagKind
    /// The N in `[mN]`. Nil for every other tag.
    ///
    /// Levels observed: 1 (3,563,809), 2 (87,076), 3 (38,831), 4 (344). Most
    /// cards are flat — a single `[m1]` — so nesting depth alone is not a
    /// reliable signal of how deep a sense is.
    public let level: Int?
    /// `brown` in `[c brown]`.
    public let argument: String?

    public init(kind: DSLTagKind, level: Int? = nil, argument: String? = nil) {
        self.kind = kind
        self.level = level
        self.argument = argument
    }
}

/// One piece of a lexed DSL line.
public enum DSLToken: Hashable, Sendable {
    case text(String)
    case open(DSLTag)
    /// `[/m]` carries no level — it closes whichever sense is open — so a
    /// close is identified by kind alone.
    case close(DSLTagKind)
}

/// Something the lexer could not make sense of, reported rather than hidden.
public struct DSLDiagnostic: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        /// A bracketed span whose name is not in `DSLTagKind`.
        case unknownTag(String)
        /// A `[` with no matching `]` before the end of the line.
        case unterminatedTag
    }

    public let kind: Kind
    /// The text as it appeared, which is also what was emitted. Nothing is
    /// dropped on the way to a diagnostic.
    public let text: String

    public init(kind: Kind, text: String) {
        self.kind = kind
        self.text = text
    }
}

/// Splits a line of DSL body text into text and markup.
///
/// ### Escapes are handled before tags, and that ordering is the whole thing
///
/// DSL escapes a literal bracket as `\[` or `\]`, and the BKRS set contains
/// 55,414 of them — a dictionary of Chinese grammar is full of bracketed
/// glosses. A parser that recognises tags first and unescapes afterwards
/// sees `\[обладать\]` as an unknown tag and throws the word away. The
/// predecessor prototype's `stripDSL` did exactly that: every `[` began a
/// tag and everything to the next `]` was deleted, so the escaped brackets
/// and their contents vanished from the definition.
///
/// Every "unknown tag" found while investigating that prototype turned out
/// to be an escape artefact. Handling the backslash first makes the whole
/// category disappear: across all three files, after unescaping, there are
/// **zero** tags outside the set above.
///
/// ### Nothing is ever deleted
///
/// A span the lexer cannot identify is emitted as literal text *and*
/// reported. A dictionary that silently drops what it does not understand
/// is worse than one that shows a stray bracket, because the reader cannot
/// tell the difference between "the dictionary says nothing here" and "the
/// importer ate it".
public enum DSLLexer {
    /// Lexes one line of card body.
    ///
    /// Scans **unicode scalars**, not characters. A `Character` in Swift is
    /// an extended grapheme cluster, and a zero-width non-joiner binds to
    /// the character before it — so `]` followed by U+200C is a single
    /// `Character` that does not compare equal to `"]"`. Five tags in the
    /// BKRS set are written that way, and a character-based scanner walks
    /// straight past their closing bracket, swallowing the rest of the line
    /// into one unknown tag.
    ///
    /// This is the same trap as CRLF being one grapheme cluster, which is
    /// what makes `split(separator: "\n")` fail to split a CRLF file at
    /// all. Markup is made of scalars; only text is made of characters.
    public static func tokens(in line: String)
        -> (tokens: [DSLToken], diagnostics: [DSLDiagnostic])
    {
        var scan = Scan(line)
        scan.run()
        return (scan.tokens, scan.diagnostics)
    }

    /// One pass over a line, as a value so each step can be its own method.
    private struct Scan {
        let scalars: String.UnicodeScalarView
        var index: String.UnicodeScalarView.Index
        var tokens: [DSLToken] = []
        var diagnostics: [DSLDiagnostic] = []
        var pending = String.UnicodeScalarView()

        init(_ line: String) {
            scalars = line.unicodeScalars
            index = scalars.startIndex
            pending.reserveCapacity(scalars.count)
        }

        mutating func run() {
            while index < scalars.endIndex {
                switch scalars[index] {
                case "\\": takeEscape()
                case "[": if takeTag() {
                        return
                    }
                default:
                    pending.append(scalars[index])
                    index = scalars.index(after: index)
                }
            }
            flushText()
        }

        mutating func flushText() {
            guard !pending.isEmpty else { return }
            tokens.append(.text(String(pending)))
            pending.removeAll(keepingCapacity: true)
        }

        /// A backslash takes the next scalar literally, whatever it is. A
        /// trailing backslash is just a backslash.
        mutating func takeEscape() {
            let next = scalars.index(after: index)
            guard next < scalars.endIndex else {
                pending.append(scalars[index])
                index = next
                return
            }
            pending.append(scalars[next])
            index = scalars.index(after: next)
        }

        /// Handles a `[`. Returns true when the line is finished.
        mutating func takeTag() -> Bool {
            guard let end = unescapedClosingBracket(in: scalars, after: index) else {
                let rest = String(scalars[index...])
                diagnostics.append(DSLDiagnostic(kind: .unterminatedTag, text: rest))
                pending.append(contentsOf: scalars[index...])
                flushText()
                return true
            }

            let span = index ... end
            let body = String(scalars[scalars.index(after: index) ..< end])
            index = scalars.index(after: end)

            switch parse(body) {
            case let .open(tag):
                flushText()
                tokens.append(.open(tag))
            case let .close(kind):
                flushText()
                tokens.append(.close(kind))
            case .unknown:
                diagnostics.append(
                    DSLDiagnostic(kind: .unknownTag(body), text: String(scalars[span])),
                )
                pending.append(contentsOf: scalars[span])
            }
            return false
        }
    }

    // MARK: - Tag parsing

    private enum Parsed {
        case open(DSLTag)
        case close(DSLTagKind)
        case unknown
    }

    /// Interprets the inside of a `[...]`.
    ///
    /// Strict on purpose, in all three directions a looser reading would be
    /// tempting. A sense closes with a bare `[/m]` and nothing else; a level
    /// is an ASCII digit and nothing else; and only `[c]` carries an
    /// argument. Anything outside that is not quietly reinterpreted — it is
    /// kept as text and reported, which is the same rule the lexer applies
    /// to a tag it has never heard of.
    ///
    /// The alternative is guessing, and a guess here is invisible: `[b bold]`
    /// read as bold-with-an-argument produces markup that looks right and
    /// has silently dropped whatever `bold` was meant to say.
    private static func parse(_ body: String) -> Parsed {
        guard !body.isEmpty else { return .unknown }

        if body.hasPrefix("/") {
            // `[/m1]` is not a close. A sense ends with `[/m]`, and treating
            // a levelled close as valid would accept markup this format does
            // not produce while hiding it from the diagnostics.
            guard let kind = closingKind(forName: String(body.dropFirst())) else {
                return .unknown
            }
            return .close(kind)
        }

        // `[c brown]` — the name runs to the first space, the rest is the
        // argument.
        let parts = body.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
        let name = String(parts[0])
        let argument = parts.count > 1 ? String(parts[1]) : nil

        if let level = senseLevel(forName: name) {
            // `[m1 extra]` means nothing in this format.
            guard argument == nil else { return .unknown }
            return .open(DSLTag(kind: .sense, level: level, argument: nil))
        }

        guard let kind = openingKind(forName: name) else { return .unknown }
        // Colour is the only tag that takes an argument. Accepting one
        // elsewhere would turn an unparsed fragment into valid-looking
        // markup.
        guard argument == nil || kind == .colour else { return .unknown }
        return .open(DSLTag(kind: kind, level: nil, argument: argument))
    }

    /// `m3` → 3.
    ///
    /// ASCII digits only. `Character.wholeNumberValue` also answers for
    /// `٥` and `Ⅻ`, so a bare `wholeNumberValue` check turns `[m٥]` into a
    /// sense at level five — markup invented from a character this format
    /// never uses.
    ///
    /// The range is the format's 1–9, not the 1–4 that happen to occur in
    /// BKRS. The lexer implements DSL; what a particular dictionary uses is
    /// the card builder's business.
    private static func senseLevel(forName name: String) -> Int? {
        guard name.count == 2, name.hasPrefix("m"),
              let digit = name.last, digit.isASCII, digit.isNumber,
              let level = digit.wholeNumberValue, level > 0
        else { return nil }
        return level
    }

    /// The kind a name opens, or nil if it opens nothing.
    private static func openingKind(forName name: String) -> DSLTagKind? {
        // A bare `m` only ever closes; there is no level to give it.
        guard name != "m" else { return nil }
        return DSLTagKind.allCases.first { $0.openingName == name }
    }

    /// The kind a name closes, or nil if it closes nothing.
    private static func closingKind(forName name: String) -> DSLTagKind? {
        DSLTagKind.allCases.first { $0.openingName == name }
    }

    /// The next `]` that is not itself escaped.
    private static func unescapedClosingBracket(
        in scalars: String.UnicodeScalarView,
        after start: String.UnicodeScalarView.Index,
    )
        -> String.UnicodeScalarView.Index?
    {
        var index = scalars.index(after: start)
        while index < scalars.endIndex {
            let scalar = scalars[index]
            if scalar == "\\" {
                // Skip the escaped scalar, whatever it is.
                index = scalars.index(index, offsetBy: 2, limitedBy: scalars.endIndex)
                    ?? scalars.endIndex
                continue
            }
            if scalar == "]" {
                return index
            }
            index = scalars.index(after: index)
        }
        return nil
    }
}
