// HanReader — MIT licensed. See LICENSE.

import Testing
@testable import HanReaderCore

/// Shorthands so a test reads as the markup it is about.
private func lex(_ line: String) -> [DSLToken] {
    DSLLexer.tokens(in: line).tokens
}

private func diagnostics(_ line: String) -> [DSLDiagnostic] {
    DSLLexer.tokens(in: line).diagnostics
}

/// Everything the tokens contain, concatenated. The lexer must never lose a
/// character: whatever it cannot identify comes back as text.
private func visibleText(_ line: String) -> String {
    lex(line).reduce(into: "") { out, token in
        if case let .text(text) = token {
            out += text
        }
    }
}

@Suite("DSL lexer")
struct DSLLexerTests {
    // MARK: - Escapes come first

    /// The rule the whole lexer is arranged around, and the one the
    /// predecessor's `stripDSL` got wrong: it treated every `[` as a tag and
    /// deleted to the next `]`, so an escaped bracket took the word inside
    /// it with it. There are 55,414 escaped brackets in the BKRS set.
    @Test("An escaped bracket is literal text, not a tag")
    func escapedBracketsSurvive() {
        #expect(visibleText(#"\[обладать\]"#) == "[обладать]")
        #expect(lex(#"\[обладать\]"#) == [.text("[обладать]")])
        #expect(diagnostics(#"\[обладать\]"#).isEmpty)
    }

    @Test("An escaped bracket beside a real tag confuses neither")
    func escapesAndTagsTogether() {
        let tokens = lex(#"[i]\[книжн.\][/i]"#)
        #expect(tokens == [
            .open(DSLTag(kind: .italic)),
            .text("[книжн.]"),
            .close(.italic),
        ])
    }

    @Test("A closing bracket inside a tag does not end it early")
    func escapedBracketInsideTag() {
        // The `]` is escaped, so the tag runs on to the real one.
        let (tokens, found) = DSLLexer.tokens(in: #"[c br\]own]x"#)
        #expect(found.isEmpty, "the span should parse, not be reported")
        #expect(tokens.first == .open(DSLTag(kind: .colour, argument: #"br\]own"#)))
    }

    @Test("A backslash escapes any character, not only brackets")
    func backslashEscapesAnything() {
        #expect(visibleText(#"a\\b"#) == #"a\b"#)
        #expect(visibleText(#"\x"#) == "x")
    }

    @Test("A trailing backslash is just a backslash")
    func trailingBackslash() {
        #expect(visibleText(#"abc\"#) == #"abc\"#)
    }

    // MARK: - Tags

    @Test("A sense tag carries its level, and its close does not")
    func senseLevels() {
        #expect(lex("[m1]") == [.open(DSLTag(kind: .sense, level: 1))])
        #expect(lex("[m4]") == [.open(DSLTag(kind: .sense, level: 4))])
        // `[/m]` ends whichever sense is open, so there is no level to carry.
        #expect(lex("[/m]") == [.close(.sense)])
    }

    /// The prototype's central bug: a card's whole sense run arrives on one
    /// physical line, so a parser that treats a line as a sense produces one
    /// blob per entry. Two spans on one line must come out as two.
    @Test("Two sense spans on one line are two spans")
    func twoSensesOneLine() {
        let tokens = lex("[m1]один[/m][m2]два[/m]")
        #expect(tokens == [
            .open(DSLTag(kind: .sense, level: 1)),
            .text("один"),
            .close(.sense),
            .open(DSLTag(kind: .sense, level: 2)),
            .text("два"),
            .close(.sense),
        ])
    }

    @Test("Every tag in the data is recognised", arguments: [
        ("[b]", DSLTagKind.bold), ("[i]", .italic), ("[p]", .grammar),
        ("[c]", .colour), ("[ex]", .example), ("[*]", .exampleBlock),
        ("[ref]", .reference),
    ])
    func knownTags(markup: String, kind: DSLTagKind) {
        #expect(lex(markup) == [.open(DSLTag(kind: kind))])
        #expect(lex("[/\(markup.dropFirst().dropLast())]") == [.close(kind)])
    }

    @Test("A colour argument is kept", arguments: ["brown", "red", "violet", "green", "crimson"])
    func colourArgument(colour: String) {
        #expect(lex("[c \(colour)]") == [.open(DSLTag(kind: .colour, argument: colour))])
    }

    @Test("A tag with no argument has none")
    func noArgument() {
        #expect(lex("[c]") == [.open(DSLTag(kind: .colour, argument: nil))])
    }

    // MARK: - Strictness

    /// A sense ends with a bare `[/m]`. Accepting `[/m1]` would admit markup
    /// this format does not produce while hiding it from the diagnostics.
    @Test("A levelled close is not a close")
    func levelledCloseIsRejected() {
        #expect(visibleText("[/m1]текст") == "[/m1]текст")
        #expect(diagnostics("[/m1]").map(\.kind) == [.unknownTag("/m1")])
    }

    /// `Character.wholeNumberValue` answers for `٥` and `Ⅻ` too, so a bare
    /// check turns `[m٥]` into a sense at level five — markup invented from
    /// a character the format never uses.
    @Test("A sense level must be an ASCII digit", arguments: ["[m٥]", "[mⅫ]", "[m一]"])
    func nonAsciiLevelsRejected(markup: String) {
        #expect(visibleText(markup) == markup)
        #expect(diagnostics(markup).count == 1)
    }

    /// The format's range, not the 1–4 that BKRS happens to use. The lexer
    /// implements DSL; which levels a dictionary uses is the builder's
    /// business.
    @Test("Levels 1 to 9 open a sense", arguments: Array(1 ... 9))
    func asciiLevelsAccepted(level: Int) {
        #expect(lex("[m\(level)]") == [.open(DSLTag(kind: .sense, level: level))])
    }

    /// Colour is the only tag that takes an argument. Accepting one
    /// elsewhere turns an unparsed fragment into valid-looking markup and
    /// silently drops whatever it said.
    @Test("An argument on a tag that takes none is reported", arguments: [
        "[b extra]", "[i extra]", "[ex extra]", "[m1 extra]", "[ref extra]",
    ])
    func unexpectedArgumentRejected(markup: String) {
        #expect(visibleText(markup) == markup)
        #expect(diagnostics(markup).count == 1)
    }

    @Test("Colour still takes its argument")
    func colourKeepsArgument() {
        #expect(lex("[c brown]") == [.open(DSLTag(kind: .colour, argument: "brown"))])
    }

    // MARK: - Nothing is lost

    /// A dictionary that silently drops what it does not understand is worse
    /// than one that shows a stray bracket: the reader cannot tell "no entry
    /// here" from "the importer ate it".
    @Test("An unknown tag is kept as text and reported")
    func unknownTagIsKept() {
        let line = "пример [zzz] текст"
        #expect(visibleText(line) == line)
        #expect(diagnostics(line) == [
            DSLDiagnostic(kind: .unknownTag("zzz"), text: "[zzz]"),
        ])
    }

    @Test("An unterminated bracket is kept as text and reported")
    func unterminatedTag() {
        let line = "текст [m1 без конца"
        #expect(visibleText(line) == line)
        #expect(diagnostics(line).map(\.kind) == [.unterminatedTag])
    }

    @Test("An empty bracket pair is unknown, not a tag")
    func emptyBrackets() {
        #expect(visibleText("[]") == "[]")
        #expect(diagnostics("[]").count == 1)
    }

    /// `[m]` with no digit only ever appears as a close. Across all three
    /// files every one of the 3,690,058 bare `m` tokens is a `[/m]`, and
    /// the 3,690,060 opens all carry a level — so an opening bare `[m]` is
    /// an anomaly, and the lexer reports it instead of inventing a level
    /// for it.
    @Test("A bare opening sense tag is reported, not given a level")
    func bareSenseOpen() {
        #expect(visibleText("[m]") == "[m]")
        #expect(diagnostics("[m]").map(\.kind) == [.unknownTag("m")])
    }

    @Test("A sense level of zero is not a sense")
    func zeroLevel() {
        #expect(visibleText("[m0]") == "[m0]")
        #expect(diagnostics("[m0]").count == 1)
    }

    // MARK: - Scalars, not characters

    /// The bug this found in the real data, and the reason the lexer scans
    /// unicode scalars rather than characters.
    ///
    /// A zero-width non-joiner binds to the character before it, so `]`
    /// followed by U+200C is a *single* Swift `Character` that does not
    /// compare equal to `"]"`. A character-based scanner walks past the
    /// closing bracket and swallows the rest of the line into one unknown
    /// tag. Five tags in the BKRS set are written this way — five in
    /// 13,739,066 tokens, which is exactly the frequency that never shows
    /// up in a hand-written fixture.
    ///
    /// Same trap as CRLF being one grapheme cluster, which is why
    /// `split(separator: "\n")` does not split a CRLF file.
    @Test("A zero-width joiner after a bracket does not hide it")
    func zeroWidthAfterBracket() {
        let line = "[ref]\u{200C}磁性碰锁[/ref]"
        #expect(lex(line) == [
            .open(DSLTag(kind: .reference)),
            .text("\u{200C}磁性碰锁"),
            .close(.reference),
        ])
        #expect(diagnostics(line).isEmpty)
    }

    @Test("A zero-width joiner is content, and is kept")
    func zeroWidthIsContent() {
        #expect(visibleText("[m1]\u{200C}\u{200C}текст[/m]") == "\u{200C}\u{200C}текст")
    }

    /// Proof the distinction is real rather than theoretical: these two
    /// strings differ by one scalar and a `Character` scan cannot tell
    /// their brackets apart.
    @Test("A bracket and a bracket-plus-joiner are one Character but two scalars")
    func graphemeClusterTrap() {
        let joined = "]\u{200C}"
        #expect(joined.count == 1, "one grapheme cluster")
        #expect(joined.unicodeScalars.count == 2, "two scalars")
        #expect(Array(joined)[0] != "]", "which is why a Character scan misses it")
    }

    // MARK: - Ordinary text

    @Test("Text with no markup is one token")
    func plainText() {
        #expect(lex("любить, быть влюблённым") == [.text("любить, быть влюблённым")])
    }

    @Test("An empty line produces nothing")
    func emptyLine() {
        #expect(lex("").isEmpty)
        #expect(diagnostics("").isEmpty)
    }

    @Test("Chinese, Russian and punctuation all pass through")
    func mixedScripts() {
        let line = "爱儿童 любить ребёнка (детей)"
        #expect(visibleText(line) == line)
    }

    /// The property that matters across the whole file: for any input, the
    /// text the lexer emits plus the markup it recognised accounts for every
    /// character it was given.
    @Test("Nothing is dropped, whatever the input", arguments: [
        "[m1][b]I[/b] [p]гл.[/p][/m]",
        #"[m2]1) любить ([i]кого-л.[/i])[/m]"#,
        #"[m3][*][ex]爱儿童 любить ребёнка[/ex][/*][/m]"#,
        #"\[方\] диалектное"#,
        "[c brown]красный[/c]",
        "[zzz]неизвестно[/zzz]",
        "обычный текст",
        "",
    ])
    func nothingIsDropped(line: String) {
        let (tokens, _) = DSLLexer.tokens(in: line)
        let recovered = tokens.reduce(into: "") { out, token in
            switch token {
            case let .text(text): out += text
            case let .open(tag):
                let level = tag.level.map(String.init) ?? ""
                let argument = tag.argument.map { " \($0)" } ?? ""
                out += "[\(tag.kind.openingName)\(level)\(argument)]"
            case let .close(kind): out += "[/\(kind.openingName)]"
            }
        }
        // Escapes are resolved, so compare against the unescaped original.
        let unescaped = line
            .replacingOccurrences(of: #"\["#, with: "[")
            .replacingOccurrences(of: #"\]"#, with: "]")
        #expect(recovered == unescaped)
    }
}
