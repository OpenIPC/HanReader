// HanReader — MIT licensed. See LICENSE.

import Foundation
import Testing
@testable import HanReaderCore

// MARK: - Helpers

private func utf16(_ text: String) -> [UInt8] {
    var bytes: [UInt8] = [0xFF, 0xFE]
    for unit in Array(text.utf16) {
        bytes += [UInt8(unit & 0xFF), UInt8(unit >> 8)]
    }
    return bytes
}

private func read(
    _ text: String,
    leadingHeadwords: [String] = [],
) throws
    -> (records: [DSLCardRecord], reader: DSLCardReader)
{
    var reader = try DSLCardReader(
        source: DSLMemoryBytes(utf16(text)),
        leadingHeadwords: leadingHeadwords,
    )
    var records: [DSLCardRecord] = []
    while let record = try reader.next() {
        records.append(record)
    }
    return (records, reader)
}

private func cards(_ text: String) throws -> [DSLCard] {
    try read(text).records.map(\.card)
}

/// A file shaped like a real one: CRLF header lines, a blank separator, then
/// three-line cards.
private let file = """
#NAME "大БКРС - 250920 ( 1 / 3 )"\r
#INDEX_LANGUAGE "Chinese"\r
#CONTENTS_LANGUAGE "Russian"
#INCLUDE "dabkrs_2.dsl"
#INCLUDE "dabkrs_3.dsl"

爱
 ài
 [m1]любить[/m]
了
 le, liǎo
 [m1]частица[/m]

"""

@Suite("DSL card reader")
struct DSLCardReaderTests {
    // MARK: - Card shape

    @Test("A file becomes its cards")
    func wholeFile() throws {
        let result = try cards(file)
        #expect(result.count == 2)
        #expect(result.map(\.headwords) == [["爱"], ["了"]])
        #expect(result.map(\.pinyin) == ["ài", "le, liǎo"])
        #expect(result.map(\.body) == [["[m1]любить[/m]"], ["[m1]частица[/m]"]])
    }

    // MARK: - Telling a reading line from an article line

    /// A reading line is a convention of Chinese dictionaries, not a rule of
    /// the format, so it is detected rather than assumed. A dictionary that
    /// writes no readings — which DSL permits — would otherwise lose the first
    /// line of every article to a reading field.
    @Test("A card whose article opens with a sense tag has no reading")
    func articleWithoutReading() throws {
        let result = try cards("dog\n [m1]animal[/m]\n [m1]пёс[/m]\n")
        #expect(result[0].pinyin.isEmpty)
        #expect(result[0].body == ["[m1]animal[/m]", "[m1]пёс[/m]"])
    }

    /// 287 reading lines in the set carry markup — an italic register note
    /// between two readings — so the test has to be the sense tag
    /// specifically, not markup in general.
    @Test("A reading line carrying other markup is still a reading")
    func readingWithMarkup() throws {
        let result = try cards("陆轴\n lùzhóu, [i]разг.[/i] liùzhóu\n [m1]каток[/m]\n")
        #expect(result[0].pinyin == "lùzhóu, [i]разг.[/i] liùzhóu")
        #expect(result[0].body == ["[m1]каток[/m]"])
    }

    /// One indented line with no markup is genuinely ambiguous, and the two
    /// mistakes are not equal: a reading with no definition is not an entry
    /// worth having, while a definition read as a reading leaves the entry
    /// saying nothing at all.
    @Test("A single indented line is article text, not a reading")
    func singleLineIsArticle() throws {
        let result = try cards("爱\n любить\n")
        #expect(result[0].pinyin.isEmpty)
        #expect(result[0].body == ["любить"])
    }

    @Test("An escaped bracket does not look like a sense tag")
    func escapedBracketIsNotATag() throws {
        let result = try cards("爱\n \\[m1\\] ài\n [m1]любить[/m]\n")
        #expect(result[0].pinyin == "\\[m1\\] ài")
    }

    /// Exactly one card in the set — 乐芙兰 — breaks a line inside an open
    /// `[m1]`, and most other DSL dictionaries write one sense per line. The
    /// article is a list of lines; the structure comes from the markup.
    @Test("An article spread over several lines keeps all of them")
    func multiLineArticle() throws {
        let result = try cards("乐芙兰\n _\n [m1]Ле Блан\n (чемпион из Лиги Легенд)[/m]\n")
        #expect(result[0].body == ["[m1]Ле Блан", "(чемпион из Лиги Легенд)[/m]"])
    }

    /// And the sense that article belongs to comes out as one gloss with the
    /// line break rendered as a space, not as `Ле Блан(чемпион…)`.
    @Test("A sense broken across lines reads as one sentence")
    func multiLineSense() throws {
        let card = try #require(
            try cards("乐芙兰\n _\n [m1]Ле Блан\n (чемпион из Лиги Легенд)[/m]\n").first,
        )
        let built = DSLCardBuilder(syllableBases: []).entries(from: card)
        let senses = try #require(built.entries.first?.senses)
        #expect(senses.count == 1)
        #expect(senses[0].gloss.text == "Ле Блан (чемпион из Лиги Легенд)")
    }

    /// The DSL spec lets several spellings share one article. BKRS never does
    /// — all 3,434,224 cards have one headword — but refusing it would be a
    /// parser bug waiting for the next dictionary.
    @Test("Consecutive unindented lines are one card")
    func sharedArticle() throws {
        let result = try cards("爱\n愛\n ài\n [m1]любить[/m]\n")
        #expect(result.count == 1)
        #expect(result[0].headwords == ["爱", "愛"])
    }

    @Test("A blank line between cards is not a headword")
    func blankLineBetweenCards() throws {
        let result = try cards("爱\n ài\n [m1]x[/m]\n\n了\n le\n [m1]y[/m]\n")
        #expect(result.map(\.headwords) == [["爱"], ["了"]])
    }

    @Test("A file with no trailing newline still yields its last card")
    func noTrailingNewline() throws {
        #expect(try cards("爱\n ài\n [m1]любить[/m]").count == 1)
    }

    @Test("A file of nothing but a header yields no cards")
    func headerOnly() throws {
        let result = try read("#NAME \"x\"\n#INDEX_LANGUAGE \"Chinese\"\n\n")
        #expect(result.records.isEmpty)
        #expect(result.reader.header.name == "x")
    }

    // MARK: - Line kinds

    /// Indentation is tested before the `#`, so an indented line beginning
    /// with `#` is article text. The format escapes a literal leading `#`
    /// only where it would be ambiguous, which is on an unindented line.
    @Test("An indented line starting with a hash is article text")
    func indentedHash() throws {
        let result = try cards("爱\n ài\n #1 значение\n")
        #expect(result[0].body == ["#1 значение"])
    }

    /// Nesting is carried by `[mN]`, never by indent depth, so a line
    /// indented by two spaces means what one indented by one means — and
    /// leaving the extra space in would put it inside the gloss.
    @Test("Indent depth carries no meaning", arguments: [" ", "  ", "\t", " \t "])
    func indentDepth(indent: String) throws {
        let result = try cards("爱\n\(indent)ài\n\(indent)[m1]любить[/m]\n")
        #expect(result[0].pinyin == "ài")
        #expect(result[0].body == ["[m1]любить[/m]"])
    }

    @Test("stripIndent reports an unindented line as unindented")
    func stripIndentOnUnindented() {
        #expect(DSLCardReader.stripIndent("爱") == nil)
        #expect(DSLCardReader.stripIndent(" ài") == "ài")
        #expect(DSLCardReader.stripIndent("") == nil)
    }

    // MARK: - Offsets

    /// Byte offset of the headword line, because a card boundary is the only
    /// place an interrupted import can restart without losing a card or
    /// writing one twice.
    @Test("Each card records the byte offset of its headword line")
    func offsets() throws {
        let result = try read(file).records
        let bytes = utf16(file)
        for record in result {
            let headword = record.card.headwords[0]
            let expected = Array(headword.utf16).flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }
            let offset = try #require(record.offset)
            #expect(Array(bytes[offset ..< (offset + expected.count)]) == expected)
        }
    }

    /// The resume contract, end to end: an offset this reader reported, handed
    /// back to a new reader, yields exactly the cards from there on.
    @Test("Resuming at a card's offset continues from that card")
    func resume() throws {
        let all = try read(file).records
        let second = try #require(all.last)
        var reader = try DSLCardReader(
            source: DSLMemoryBytes(utf16(file)),
            resumingAt: second.offset,
        )
        var resumed: [DSLCardRecord] = []
        while let record = try reader.next() {
            resumed.append(record)
        }
        #expect(resumed == [second])
    }

    // MARK: - Header

    @Test("Directives are read from the file, never assumed")
    func header() throws {
        let reader = try read(file).reader
        #expect(reader.header.name == "大БКРС - 250920 ( 1 / 3 )")
        #expect(reader.header.indexLanguage == "Chinese")
        #expect(reader.header.contentsLanguage == "Russian")
        #expect(reader.header.includes == ["dabkrs_2.dsl", "dabkrs_3.dsl"])
    }

    /// A directive this version has not heard of is still something the
    /// dictionary chose to state.
    @Test("An unrecognised directive is kept rather than dropped")
    func unknownDirective() throws {
        let reader = try read("#ICON_FILE \"x.bmp\"\n#SOUND_DICTIONARY\n\n").reader
        #expect(reader.header.other == ["ICON_FILE": "x.bmp", "SOUND_DICTIONARY": ""])
    }

    /// The format separates a directive from its value with whitespace, not
    /// with a space specifically. Read as an unknown directive, a
    /// tab-separated `#INCLUDE` leaves the include list empty and the other
    /// volumes undiscovered.
    @Test("A directive separated by a tab is still a directive")
    func tabSeparatedDirective() throws {
        let reader = try read("#INCLUDE\t\"b.dsl\"\n#NAME\t\"A\"\n\n").reader
        #expect(reader.header.includes == ["b.dsl"])
        #expect(reader.header.name == "A")
        #expect(reader.header.other.isEmpty)
    }

    @Test("Reading only the header stops at the first card")
    func headerOnlyRead() throws {
        let header = try DSLHeader.read(from: DSLMemoryBytes(utf16(file)))
        #expect(header.includes.count == 2)
        #expect(header.other.isEmpty)
    }

    // MARK: - A seam split on the wrong boundary

    /// The BKRS files are include-linked volumes, each beginning and ending on
    /// a complete card, so none of this fires for them. It is insurance
    /// against a set someone split with `split(1)`.
    @Test("An article with no headword above it is reported, not dropped")
    func bodyWithoutHeadword() throws {
        let result = try read(" ài\n [m1]любить[/m]\n了\n le\n [m1]x[/m]\n")
        #expect(result.records.count == 1)
        #expect(result.reader.diagnostics.count == 2)
        #expect(result.reader.diagnostics.allSatisfy { $0.kind == .bodyWithoutHeadword })
        #expect(result.reader.diagnostics[0].text == " ài")
        #expect(result.reader.diagnostics[0].offset == 2)
    }

    @Test("A headword with no article is reported and handed on")
    func headwordWithoutBody() throws {
        let result = try read("爱\n ài\n [m1]x[/m]\n了\n")
        #expect(result.records.count == 1)
        #expect(result.reader.trailingHeadwords == ["了"])
        #expect(result.reader.diagnostics.map(\.kind) == [.headwordWithoutBody])
    }

    /// Each headword reports its own line. Sharing the first one's offset
    /// across a run of them points every diagnostic but the first at the wrong
    /// place in the file, which is worse than no offset at all.
    @Test("Each dangling headword reports its own line")
    func danglingHeadwordOffsets() throws {
        let text = "爱\n ài\n [m1]x[/m]\n了\n一\n"
        let result = try read(text)
        let bytes = utf16(text)
        let offsets = result.reader.diagnostics.compactMap(\.offset)
        #expect(offsets.count == 2)
        #expect(offsets[0] != offsets[1])
        for (offset, headword) in zip(offsets, ["了", "一"]) {
            let expected = Array(headword.utf16).flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }
            #expect(Array(bytes[offset ..< (offset + expected.count)]) == expected)
        }
    }

    /// A card completed across a file seam has no resume point in the file it
    /// was completed in: offset zero there restarts at the byte-order mark and
    /// loses the carried headword entirely.
    @Test("A card completed across a seam offers no resume point")
    func seamCardHasNoOffset() throws {
        let result = try read(
            " le\n [m1]частица[/m]\n一\n yī\n [m1]один[/m]\n",
            leadingHeadwords: ["了"],
        )
        #expect(result.records.count == 2)
        #expect(result.records[0].card.headwords == ["了"])
        #expect(result.records[0].offset == nil)
        // The card that does start in this file keeps its offset.
        #expect(result.records[1].offset != nil)
    }

    /// The repair: the headword left over from the previous file is passed in,
    /// and the article that opens this one completes its card.
    @Test("A headword carried in from the previous file completes its card")
    func leadingHeadwords() throws {
        let result = try read(" le\n [m1]частица[/m]\n", leadingHeadwords: ["了"])
        #expect(result.records.count == 1)
        #expect(result.records[0].card.headwords == ["了"])
        #expect(result.records[0].card.pinyin == "le")
        #expect(result.reader.diagnostics.isEmpty)
    }
}

// MARK: - File-set discovery

@Suite("DSL file-set discovery")
struct DSLFileSetTests {
    /// Writes a throwaway directory of DSL files.
    func directory(
        _ files: [String: String],
        _ body: (URL) throws -> Void,
    ) throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("hanreader-dsl-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for (name, text) in files {
            try Data(utf16(text)).write(to: root.appendingPathComponent(name))
        }
        try body(root)
    }

    /// The master file names its volumes, so the set is read out of the file
    /// rather than out of a hardcoded list of names — which is what makes the
    /// importer work on a second dictionary, and on a renamed copy of this
    /// one.
    @Test("The set comes from the master file's include directives")
    func includeDirectives() throws {
        try directory([
            "a.dsl": "#NAME \"A\"\n#INCLUDE \"b.dsl\"\n#INCLUDE \"c.dsl\"\n\n爱\n ài\n [m1]x[/m]\n",
            "b.dsl": "#NAME \"B\"\n\n了\n le\n [m1]y[/m]\n",
            "c.dsl": "#NAME \"C\"\n\n一\n yī\n [m1]z[/m]\n",
        ]) { root in
            let set = try DSLFileSet.discover(from: root.appendingPathComponent("a.dsl"))
            #expect(set.discovery == .includeDirectives)
            #expect(set.files.map(\.lastPathComponent) == ["a.dsl", "b.dsl", "c.dsl"])
            #expect(set.header.name == "A")
            #expect(set.diagnostics.isEmpty)
        }
    }

    @Test("An include naming a file that is not there is reported")
    func missingInclude() throws {
        try directory([
            "a.dsl": "#NAME \"A\"\n#INCLUDE \"gone.dsl\"\n\n爱\n ài\n [m1]x[/m]\n",
        ]) { root in
            let set = try DSLFileSet.discover(from: root.appendingPathComponent("a.dsl"))
            #expect(set.files.count == 1)
            #expect(set.diagnostics.map(\.kind) == [.missingInclude("gone.dsl")])
        }
    }

    @Test("An include cycle does not loop")
    func includeCycle() throws {
        try directory([
            "a.dsl": "#NAME \"A\"\n#INCLUDE \"b.dsl\"\n\n爱\n ài\n [m1]x[/m]\n",
            "b.dsl": "#NAME \"B\"\n#INCLUDE \"a.dsl\"\n\n了\n le\n [m1]y[/m]\n",
        ]) { root in
            let set = try DSLFileSet.discover(from: root.appendingPathComponent("a.dsl"))
            #expect(set.files.map(\.lastPathComponent) == ["a.dsl", "b.dsl"])
        }
    }

    /// Only when there are no directives at all.
    @Test("Numbered siblings are found when nothing is declared")
    func numberedSiblings() throws {
        try directory([
            "dict_1.dsl": "#NAME \"1\"\n\n爱\n ài\n [m1]x[/m]\n",
            "dict_2.dsl": "#NAME \"2\"\n\n了\n le\n [m1]y[/m]\n",
            "dict_3.dsl": "#NAME \"3\"\n\n一\n yī\n [m1]z[/m]\n",
        ]) { root in
            let set = try DSLFileSet.discover(from: root.appendingPathComponent("dict_1.dsl"))
            #expect(set.discovery == .numberedSiblings)
            #expect(set.files.map(\.lastPathComponent) == [
                "dict_1.dsl",
                "dict_2.dsl",
                "dict_3.dsl",
            ])
        }
    }

    /// Picking volume two has to find volume one, because that is where the
    /// directives and the dictionary's own name live.
    @Test("Picking a later volume restarts discovery from the first")
    func picksLowestSibling() throws {
        try directory([
            "dict_1.dsl": "#NAME \"whole thing\"\n#INCLUDE \"dict_2.dsl\"\n\n爱\n ài\n [m1]x[/m]\n",
            "dict_2.dsl": "#NAME \"volume 2\"\n\n了\n le\n [m1]y[/m]\n",
        ]) { root in
            let set = try DSLFileSet.discover(from: root.appendingPathComponent("dict_2.dsl"))
            #expect(set.discovery == .includeDirectives)
            #expect(set.header.name == "whole thing")
            #expect(set.files.map(\.lastPathComponent) == ["dict_1.dsl", "dict_2.dsl"])
        }
    }

    /// A set missing its second volume is a set of one, not a set of two with
    /// a hole in it.
    @Test("A gap in the numbering ends the run")
    func gapEndsTheRun() throws {
        try directory([
            "dict_1.dsl": "#NAME \"1\"\n\n爱\n ài\n [m1]x[/m]\n",
            "dict_3.dsl": "#NAME \"3\"\n\n一\n yī\n [m1]z[/m]\n",
        ]) { root in
            let set = try DSLFileSet.discover(from: root.appendingPathComponent("dict_1.dsl"))
            #expect(set.files.map(\.lastPathComponent) == ["dict_1.dsl"])
            #expect(set.discovery == .single)
        }
    }

    @Test("Zero padding in the numbering is preserved")
    func zeroPadding() throws {
        try directory([
            "vol_01.dsl": "#NAME \"1\"\n\n爱\n ài\n [m1]x[/m]\n",
            "vol_02.dsl": "#NAME \"2\"\n\n了\n le\n [m1]y[/m]\n",
        ]) { root in
            let set = try DSLFileSet.discover(from: root.appendingPathComponent("vol_01.dsl"))
            #expect(set.files.map(\.lastPathComponent) == ["vol_01.dsl", "vol_02.dsl"])
        }
    }

    /// A file whose name happens to end in a digit is not part of a run it is
    /// not in; importing files the reader did not pick needs a better reason
    /// than a coincidence of naming.
    @Test("A file outside the numbered run is imported alone")
    func unrelatedNumbering() throws {
        try directory([
            "dict_1.dsl": "#NAME \"1\"\n\n爱\n ài\n [m1]x[/m]\n",
            "dict_9.dsl": "#NAME \"9\"\n\n了\n le\n [m1]y[/m]\n",
        ]) { root in
            let set = try DSLFileSet.discover(from: root.appendingPathComponent("dict_9.dsl"))
            #expect(set.files.map(\.lastPathComponent) == ["dict_9.dsl"])
            #expect(set.discovery == .single)
        }
    }

    /// Returning 64 volumes of a 65-volume dictionary as though it were
    /// complete is the worst of the three possible behaviours: it imports, it
    /// looks right, and the missing volume's words simply cannot be found.
    @Test("Discovery says so when it stops at its file limit")
    func tooManyIncludes() throws {
        var files: [String: String] = [:]
        let includes = (1 ... DSLFileSet.fileLimit + 2)
            .map { "#INCLUDE \"v\($0).dsl\"\n" }
            .joined()
        files["a.dsl"] = "#NAME \"A\"\n" + includes + "\n爱\n ài\n [m1]x[/m]\n"
        for index in 1 ... DSLFileSet.fileLimit + 2 {
            files["v\(index).dsl"] = "#NAME \"\(index)\"\n\n了\n le\n [m1]y[/m]\n"
        }
        try directory(files) { root in
            let set = try DSLFileSet.discover(from: root.appendingPathComponent("a.dsl"))
            #expect(set.files.count == DSLFileSet.fileLimit)
            #expect(set.diagnostics.contains {
                $0.kind == .tooManyFiles(limit: DSLFileSet.fileLimit)
            })
        }
    }

    @Test("A numbered run that hits the limit says so too")
    func tooManySiblings() throws {
        var files: [String: String] = [:]
        for index in 1 ... DSLFileSet.fileLimit + 2 {
            files["vol_\(index).dsl"] = "#NAME \"\(index)\"\n\n了\n le\n [m1]y[/m]\n"
        }
        try directory(files) { root in
            let set = try DSLFileSet.discover(from: root.appendingPathComponent("vol_1.dsl"))
            #expect(set.files.count == DSLFileSet.fileLimit)
            #expect(set.diagnostics.contains {
                $0.kind == .tooManyFiles(limit: DSLFileSet.fileLimit)
            })
        }
    }

    @Test("A name with no trailing number stands alone")
    func noNumber() throws {
        try directory([
            "dict.dsl": "#NAME \"d\"\n\n爱\n ài\n [m1]x[/m]\n",
        ]) { root in
            let set = try DSLFileSet.discover(from: root.appendingPathComponent("dict.dsl"))
            #expect(set.discovery == .single)
            #expect(set.files.map(\.lastPathComponent) == ["dict.dsl"])
        }
    }
}
