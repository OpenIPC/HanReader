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
        styleStarts.removeAll()
        referenceStart = nil
    }

    /// `[/m]` ends the span, not the level.
    ///
    /// It closes any emphasis left open inside the sense and nothing more.
    /// The level hierarchy outlives it — see `lastByLevel` — and text
    /// between a close and the next open stays with the sense it followed
    /// rather than being dropped.
    private mutating func closeDeepestSense() {
        styleStarts.removeAll()
        referenceStart = nil
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
        // Text outside any `[mN]` still belongs to the card; a sense is
        // opened for it rather than letting it fall on the floor. Cards
        // whose body carries no markup at all exist, and dropping them
        // would lose the entry entirely.
        if current == nil {
            openSense(level: 0)
        }
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

    private mutating func closeReference() {
        guard let current, let start = referenceStart else { return }
        referenceStart = nil
        let text = drafts[current].text
        let end = text.utf16.count
        guard end > start,
              let range = Range(NSRange(location: start, length: end - start), in: text)
        else { return }
        drafts[current].references.append(CrossReference(
            simplified: String(text[range]),
            traditional: nil,
            reading: nil,
            range: start ..< end,
        ))
    }

    /// `[p]гл.[/p]` is a category, not prose.
    ///
    /// Unrecognised labels go to `registers` verbatim rather than being
    /// dropped. A field marker this list has not heard of is still
    /// information the dictionary chose to print.
    private mutating func closeGrammar() {
        defer { grammar = nil }
        guard let text = grammar?.trimmingCharacters(in: .whitespaces), !text.isEmpty else {
            return
        }
        if current == nil {
            openSense(level: 0)
        }
        guard let current else { return }
        if Self.partsOfSpeech.contains(text) {
            drafts[current].partOfSpeech.append(text)
        } else {
            drafts[current].registers.append(text)
        }
    }

    private mutating func closeExample() {
        defer { example = nil }
        guard let raw = example?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return }
        if current == nil {
            openSense(level: 0)
        }
        guard let current else { return }
        drafts[current].examples.append(Self.splitExample(raw))
    }

    // MARK: - Finishing

    mutating func finish() -> [Sense] {
        lastByLevel.removeAll()
        current = nil
        return drafts.enumerated().map { index, draft in
            var draft = draft
            let label = Self.liftLabel(from: &draft)
            return Sense(
                id: index,
                kind: Self.kind(of: draft),
                gloss: Gloss(
                    text: draft.text.trimmingCharacters(in: .whitespaces),
                    references: draft.references,
                    styles: draft.styles,
                ),
                level: draft.level,
                parent: draft.parent,
                label: label,
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
    /// Takes the dictionary's own numbering out of the gloss.
    ///
    /// Left in place it appears twice — once from the dictionary and once
    /// from whatever numbering the reader's list applies — and it stops the
    /// gloss being usable as a one-line summary.
    private static func liftLabel(from draft: inout Draft) -> String? {
        let text = draft.text.trimmingCharacters(in: .whitespaces)
        guard let match = labelPrefix(of: text) else { return nil }

        let removed = draft.text.utf16.count - text.utf16.count
            + match.utf16.count
        draft.text = String(text.dropFirst(match.count))
            .trimmingCharacters(in: .whitespaces)
        draft.styles = shift(draft.styles, by: removed, limit: draft.text.utf16.count)
        draft.references = draft.references.compactMap { reference in
            let lower = reference.range.lowerBound - removed
            let upper = reference.range.upperBound - removed
            guard lower >= 0, upper <= draft.text.utf16.count, lower < upper else { return nil }
            return CrossReference(
                simplified: reference.simplified,
                traditional: reference.traditional,
                reading: reference.reading,
                range: lower ..< upper,
            )
        }
        return match.trimmingCharacters(in: .whitespaces)
    }

    private static func shift(_ styles: [StyleRun], by offset: Int, limit: Int) -> [StyleRun] {
        styles.compactMap { run in
            let lower = max(0, run.range.lowerBound - offset)
            let upper = min(limit, run.range.upperBound - offset)
            guard lower < upper else { return nil }
            return StyleRun(style: run.style, range: lower ..< upper)
        }
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
