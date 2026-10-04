// HanReader — MIT licensed. See LICENSE.

import Foundation

/// Builds a card's senses from its token stream.
///
/// The predecessor produced **one sense per card** — 3,434,222 rows over
/// 3,434,222 headwords, exactly one each — because it treated a line as a
/// sense and a card's whole sense run arrives on a single physical line. It
/// then tried to recover the structure downstream by splitting the blob on
/// semicolons, which is why the reader showed one unseparated string where
/// the dictionary had a numbered list.
///
/// The structure is in the markup. This reads it.
struct SenseAssembly {
    private var drafts: [Draft] = []
    /// The most recent sense seen at each level, by index into `drafts`.
    ///
    /// Not an open/close stack, and that distinction is the whole of the
    /// nesting logic. `[mN]` is an **indent level**, not a container: a card
    /// writes `[m1]…[/m][m2]…[/m]`, closing each span before opening the
    /// next, so by the time the `[m2]` arrives its `[m1]` parent is already
    /// closed. Hierarchy comes from the levels in document order, not from
    /// which spans happen to be open.
    ///
    /// Opening a sense at level L therefore takes the most recent sense at
    /// the nearest level above it as its parent, and forgets everything
    /// deeper than L — which is what makes `[m1]` after an `[m3]` start a
    /// new branch rather than attaching to the old one.
    private var lastByLevel: [Int: Int] = [:]
    private var current: Int?

    /// Where each emphasis began, as a UTF-16 offset into the sense's text.
    private var styleStarts: [TextStyle: Int] = [:]
    private var referenceStart: Int?
    /// Set while inside `[p]…[/p]`, which is a label rather than prose.
    private var grammar: String?
    /// Set while inside `[ex]…[/ex]`.
    private var example: String?

    private struct Draft {
        var level: Int
        var parent: Int?
        var text = ""
        var styles: [StyleRun] = []
        var references: [CrossReference] = []
        var partOfSpeech: [String] = []
        var registers: [String] = []
        var examples: [UsageExample] = []
    }

    // MARK: - Consuming tokens

    /// Joins the next body line to the one before it.
    ///
    /// A card's article is usually one physical line, but a line break can
    /// fall *inside* an open `[mN]`. 乐芙兰 is the one card in 3,434,224
    /// where it does — `[m1]Ле Блан` on one line, `(чемпион из Лиги
    /// Легенд)[/m]` on the next — and most other DSL dictionaries write one
    /// sense per line, where this matters far more often.
    ///
    /// The break is worth a space. Concatenating gives
    /// `Ле Блан(чемпион из Лиги Легенд)`; inserting one unconditionally would
    /// put a leading space on every sense that *is* closed at the end of its
    /// line, which is the common case. So: a space only where there is
    /// already text to separate.
    mutating func beginLine() {
        guard let tail = openText, !tail.isEmpty, !tail.hasSuffix(" ") else { return }
        append(" ")
    }

    /// The text `append` would currently add to, mirroring its precedence.
    /// Nil when nothing is open, so beginning a line never opens a sense.
    private var openText: String? {
        if let grammar {
            return grammar
        }
        if let example {
            return example
        }
        guard let current else { return nil }
        return drafts[current].text
    }

    mutating func consume(_ tokens: [DSLToken]) {
        for token in tokens {
            switch token {
            case let .text(text): append(text)
            case let .open(tag): open(tag)
            case let .close(kind): close(kind)
            }
        }
    }

    private mutating func open(_ tag: DSLTag) {
        switch tag.kind {
        case .sense:
            openSense(level: max(0, (tag.level ?? 1) - 1))
        case .grammar:
            grammar = ""
        case .example:
            example = ""
        // A decoration can open before any `[mN]` — 479 cards do — and the
        // offset it records is 0 either way, because a sense opened later
        // starts empty. What matters is that `openSense` no longer throws
        // these away, which is what lost the markup on those cards.
        case .bold:
            styleStarts[.bold] = length
        case .italic:
            styleStarts[.italic] = length
        case .colour:
            styleStarts[.highlighted] = length
        case .reference:
            referenceStart = length
        case .exampleBlock:
            // `[*]` is a wrapper, and 62 of them in the set contain no
            // `[ex]` at all. Treating it as transparent means that path
            // needs no special case and loses nothing: the text inside
            // simply joins the gloss.
            break
        }
    }

    private mutating func close(_ kind: DSLTagKind) {
        switch kind {
        case .sense: closeDeepestSense()
        case .grammar: closeGrammar()
        case .example: closeExample()
        case .bold: closeStyle(.bold)
        case .italic: closeStyle(.italic)
        case .colour: closeStyle(.highlighted)
        case .reference: closeReference()
        case .exampleBlock: break
        }
    }

    // MARK: - Senses

    private mutating func openSense(level: Int) {
        // Whatever is still open belongs to the sense being left, so it is
        // settled against that sense before the new one exists. Discarding it
        // here instead is how 241 sense spans lost their emphasis and how an
        // unclosed `[p]` could go on swallowing the *next* sense's prose.
        settleOpenSpans()

        let parent = lastByLevel
            .filter { $0.key < level }
            .max { $0.key < $1.key }?
            .value

        drafts.append(Draft(level: level, parent: parent))
        let index = drafts.count - 1

        // Everything deeper than this belongs to the branch just left.
        for seen in lastByLevel.keys where seen > level {
            lastByLevel.removeValue(forKey: seen)
        }
        lastByLevel[level] = index
        current = index
    }

    /// `[/m]` ends the span, not the level.
    ///
    /// It settles any emphasis left open inside the sense and nothing more.
    /// The level hierarchy outlives it — see `lastByLevel` — and text
    /// between a close and the next open stays with the sense it followed
    /// rather than being dropped.
    private mutating func closeDeepestSense() {
        settleOpenSpans()
    }

    /// Closes everything still open against the sense it was opened in.
    ///
    /// Markup in this set is not reliably balanced — 241 sense spans close
    /// `[/m]` with a style tag still open — and the rule the importer follows
    /// is that nothing is ever deleted. An unclosed `[i]` therefore yields the
    /// italic run it was asking for, up to where the sense ends, rather than
    /// text that silently lost its emphasis.
    private mutating func settleOpenSpans() {
        closeGrammar()
        closeExample()
        // `allCases` rather than the dictionary's own key order, so the runs
        // come out in the same order on every run.
        for style in TextStyle.allCases where styleStarts[style] != nil {
            closeStyle(style)
        }
        closeReference()
    }

    /// Text outside any `[mN]` still belongs to the card, so a sense is
    /// opened for it rather than letting it fall on the floor. Cards whose
    /// article carries no markup at all exist, and dropping them would lose
    /// the entry entirely.
    private mutating func ensureSense() {
        if current == nil {
            openSense(level: 0)
        }
    }

    // MARK: - Text

    private var length: Int {
        guard let current else { return 0 }
        return drafts[current].text.utf16.count
    }

    private mutating func append(_ text: String) {
        if grammar != nil {
            grammar? += text
            return
        }
        if example != nil {
            example? += text
            return
        }
        ensureSense()
        guard let current else { return }
        drafts[current].text += text
    }

    // MARK: - Decorations

    private mutating func closeStyle(_ style: TextStyle) {
        guard let current, let start = styleStarts.removeValue(forKey: style) else { return }
        let end = drafts[current].text.utf16.count
        guard end > start else { return }
        drafts[current].styles.append(StyleRun(style: style, range: start ..< end))
    }

    /// A cross-reference names another headword, so the span is trimmed to
    /// that headword.
    ///
    /// 21 `[ref]` spans in the set close after a space — `[ref]尽管 [/ref]` —
    /// and a headword with a trailing space matches no entry in any
    /// dictionary, so the reference would point nowhere. The span is trimmed
    /// rather than only the string, so the range and the word it names cannot
    /// disagree.
    private mutating func closeReference() {
        guard let current, let start = referenceStart else { return }
        referenceStart = nil
        let text = drafts[current].text
        let end = text.utf16.count
        guard end > start,
              let range = Range(NSRange(location: start, length: end - start), in: text)
        else { return }

        let span = text[range]
        let leading = span.prefix(while: \.isWhitespace).count
        var word = span.dropFirst(leading)
        var trailing = 0
        while let last = word.last, last.isWhitespace {
            word = word.dropLast()
            trailing += 1
        }
        guard !word.isEmpty else { return }

        drafts[current].references.append(CrossReference(
            simplified: String(word),
            traditional: nil,
            reading: nil,
            range: (start + leading) ..< (end - trailing),
        ))
    }

    /// `[p]гл.[/p]` is a category, not prose.
    ///
    /// Unrecognised labels go to `registers` verbatim rather than being
    /// dropped. A field marker this list has not heard of is still
    /// information the dictionary chose to print.
    private mutating func closeGrammar() {
        // Cleared before anything else can run, because `ensureSense` below
        // leads back into `settleOpenSpans`, and a buffer still set at that
        // point is an infinite recursion.
        guard let raw = grammar else { return }
        grammar = nil
        let text = raw.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        ensureSense()
        guard let current else { return }
        if Self.partsOfSpeech.contains(text) {
            drafts[current].partOfSpeech.append(text)
        } else {
            drafts[current].registers.append(text)
        }
    }

    private mutating func closeExample() {
        // Cleared first, for the same reason as `closeGrammar`.
        guard let buffered = example else { return }
        example = nil
        let raw = buffered.trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else { return }
        ensureSense()
        guard let current else { return }
        drafts[current].examples.append(Self.splitExample(raw))
    }

    // MARK: - Finishing

    mutating func finish() -> [Sense] {
        // A card can end with markup still open — the set has two more `[mN]`
        // opens than `[/m]` closes — so the last sense is settled here rather
        // than relying on a close that may never arrive.
        settleOpenSpans()
        lastByLevel.removeAll()
        current = nil
        return drafts.enumerated().map { index, draft in
            let trimmed = Self.trim(
                text: draft.text,
                styles: draft.styles,
                references: draft.references,
            )
            var draft = draft
            draft.text = trimmed.text
            return Sense(
                id: index,
                kind: Self.kind(of: draft),
                gloss: Gloss(
                    text: trimmed.text,
                    references: trimmed.references,
                    styles: trimmed.styles,
                ),
                level: draft.level,
                parent: draft.parent,
                label: trimmed.label,
                partOfSpeech: draft.partOfSpeech,
                registers: draft.registers,
                examples: draft.examples,
            )
        }
    }
}

// MARK: - Text helpers

/// Pure functions over a sense's text, kept out of the state machine above
/// so each can be read — and tested — without the assembly around it.
extension SenseAssembly {
    /// What a draft's text, label and ranges become in the finished sense.
    struct Trimmed {
        var text: String
        var label: String?
        var styles: [StyleRun]
        var references: [CrossReference]
    }

    /// Strips the dictionary's own numbering and the surrounding whitespace,
    /// and moves every recorded range with the text.
    ///
    /// Numbering is lifted because left in place it appears twice — once from
    /// the dictionary and once from whatever numbering the reader's list
    /// applies — and because it stops the gloss reading as a one-line summary.
    ///
    /// **One place, one offset, and that is the point.** Trimming the text in
    /// one function while the ranges were adjusted in another is how every
    /// range in a numbered sense ended up one character to the right: the
    /// space after `1)` was removed from the text by a second trim that the
    /// offset arithmetic knew nothing about. Measured over the whole set,
    /// 16,957 senses with a style run and 3,974 with a cross-reference were
    /// affected, and a reference reaching the end of its gloss was not merely
    /// shifted but dropped. A further 85,395 unnumbered senses — anything
    /// whose prose follows a `[p]…[/p]`, which leaves a leading space — had
    /// the same fault from the final trim alone.
    ///
    /// So the prefix is measured here, once, as it is removed: leading
    /// whitespace, then the label, then the whitespace after the label. Every
    /// range moves by that one number and is clamped to the result, because a
    /// range is clamped rather than discarded — a run that overshoots by a
    /// trimmed space is still the run the dictionary asked for.
    static func trim(
        text rawText: String,
        styles: [StyleRun] = [],
        references: [CrossReference] = [],
    )
        -> Trimmed
    {
        var removed = 0
        var body = Substring(rawText)

        let afterLeading = body.drop(while: \.isWhitespace)
        removed += body.utf16.count - afterLeading.utf16.count
        body = afterLeading

        var label: String?
        if let match = labelPrefix(of: String(body)) {
            body = body.dropFirst(match.count)
            removed += match.utf16.count
            let afterLabel = body.drop(while: \.isWhitespace)
            removed += body.utf16.count - afterLabel.utf16.count
            body = afterLabel
            label = match.trimmingCharacters(in: .whitespaces)
        }

        while let last = body.last, last.isWhitespace {
            body = body.dropLast()
        }

        let text = String(body)
        let limit = text.utf16.count
        return Trimmed(
            text: text,
            label: label,
            styles: styles.compactMap { run in
                guard let range = clamp(run.range, by: removed, limit: limit) else { return nil }
                return StyleRun(style: run.style, range: range)
            },
            references: references.compactMap { reference in
                guard let range = clamp(reference.range, by: removed, limit: limit) else {
                    return nil
                }
                return CrossReference(
                    simplified: reference.simplified,
                    traditional: reference.traditional,
                    reading: reference.reading,
                    range: range,
                )
            },
        )
    }

    /// Moves a range back by `offset` and clips it to `0..<limit`. Nil when
    /// nothing of it survives, which is the case for a span that sat entirely
    /// inside the lifted label.
    private static func clamp(
        _ range: Range<Int>,
        by offset: Int,
        limit: Int,
    )
        -> Range<Int>?
    {
        let lower = max(0, range.lowerBound - offset)
        let upper = min(limit, range.upperBound - offset)
        guard lower < upper else { return nil }
        return lower ..< upper
    }

    /// `I`, `II`, `1)`, `а)` — the forms BKRS numbers senses with.
    static func labelPrefix(of text: String) -> String? {
        var scalars = Substring(text)

        // A Roman numeral division heading, alone at the front.
        let roman = scalars.prefix { $0 == "I" || $0 == "V" || $0 == "X" }
        if !roman.isEmpty {
            let rest = scalars.dropFirst(roman.count)
            if rest.isEmpty || rest.first == " " {
                return String(roman)
            }
        }

        // `12)` or `а)` — a number or a single letter, then a bracket.
        let digits = scalars.prefix(while: \.isNumber)
        if !digits.isEmpty, scalars.dropFirst(digits.count).first == ")" {
            return String(scalars.prefix(digits.count + 1))
        }
        if let first = scalars.first, first.isLetter,
           scalars.dropFirst().first == ")"
        {
            scalars = scalars.dropFirst(2)
            return String(text.prefix(2))
        }
        return nil
    }

    /// Splits an example into its Chinese and its translation.
    ///
    /// At the end of the leading run of Han characters and the punctuation
    /// and spacing that belongs with them. A heuristic, which is why `raw`
    /// is always kept: an example that splits badly has to stay readable in
    /// full rather than be truncated to whichever half the heuristic liked.
    static func splitExample(_ raw: String) -> UsageExample {
        var end = raw.startIndex
        var index = raw.startIndex
        while index < raw.endIndex {
            let character = raw[index]
            let scalars = character.unicodeScalars
            let isHan = scalars.allSatisfy(ScalarClass.isHan)
            let isCJKPunctuation = scalars.allSatisfy(isChinesePunctuation)
            if isHan || isCJKPunctuation {
                index = raw.index(after: index)
                end = index
                continue
            }
            if character == " " {
                index = raw.index(after: index)
                continue
            }
            break
        }

        let chinese = String(raw[raw.startIndex ..< end]).trimmingCharacters(in: .whitespaces)
        let translation = String(raw[end...]).trimmingCharacters(in: .whitespaces)
        return UsageExample(chinese: chinese, translation: translation, raw: raw)
    }

    /// Punctuation that belongs with Chinese text.
    ///
    /// The CJK blocks are not enough: the quotation marks Chinese actually
    /// uses — “ ” ‘ ’ — live in General Punctuation alongside the dash and
    /// the ellipsis, so a block test alone stops the split at the first
    /// opening quote and hands half the sentence to the translation.
    private static func isChinesePunctuation(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3000 ... 0x303F: true // CJK symbols and punctuation
        case 0xFF00 ... 0xFF65: true // fullwidth forms
        case 0x2018, 0x2019, 0x201C, 0x201D: true // the quotation marks
        case 0x2014, 0x2026, 0x00B7: true // dash, ellipsis, interpunct
        default: false
        }
    }

    private static func kind(of draft: Draft) -> SenseKind {
        if !draft.references.isEmpty, draft.text.count <= 24 {
            return .reference
        }
        if draft.text.isEmpty, !draft.partOfSpeech.isEmpty || !draft.registers.isEmpty {
            return .label
        }
        return .definition
    }

    /// Grammatical categories, as BKRS abbreviates them. Anything else is
    /// treated as a register or field marker.
    static let partsOfSpeech: Set = [
        "гл.", "сущ.", "прил.", "нареч.", "мест.", "числ.", "предлог",
        "союз", "частица", "межд.", "служ. сл.", "счётн. сл.", "собств.",
        "гл. А", "гл. Б", "гл. В", "усл.", "вспом. гл.", "послелог",
    ]
}
