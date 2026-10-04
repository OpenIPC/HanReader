// HanReader — MIT licensed. See LICENSE.

import Foundation
import Testing
@testable import HanReaderCore

/// Loads the committed slice of real CC-CEDICT data.
///
/// Real data rather than hand-written lines, because the cases that break a
/// parser are the ones nobody thinks to invent. Extracted by
/// `Scripts/extract-cedict-fixture.py`; see that script for why each entry is
/// in there.
private enum Fixture {
    static let text: String = {
        guard let url = Bundle.module.url(
            forResource: "Fixtures/cedict-sample",
            withExtension: "u8",
        ),
            let data = try? Data(contentsOf: url),
            let text = String(data: data, encoding: .utf8)
        else {
            Issue.record("could not load the CC-CEDICT fixture")
            return ""
        }
        return text
    }()

    static let parsed = CEDICTParser.parse(text)

    static func entries(for simplified: String) -> [DictionaryEntry] {
        parsed.entries.filter { $0.headword.simplified == simplified }
    }

    static func entry(_ simplified: String, reading: String) -> DictionaryEntry? {
        entries(for: simplified).first { $0.readingKey == reading }
    }
}

@Suite("CC-CEDICT parsing")
struct CEDICTParserTests {
    /// The headline property: the grammar is exact. Validated separately
    /// against a complete dictionary — 107,619 entries, zero unparsed — and
    /// asserted here so a parser change cannot quietly start dropping lines.
    @Test("Every line in the fixture parses")
    func noUnparsedLines() {
        #expect(
            Fixture.parsed.diagnostics.isEmpty,
            "unparsed: \(Fixture.parsed.diagnostics.map(\.text))",
        )
        #expect(Fixture.parsed.entries.count == 42)
    }

    @Test("Metadata is read from the #! header")
    func metadata() {
        #expect(Fixture.parsed.metadata["format"] == "ts")
        #expect(Fixture.parsed.metadata["charset"] == "UTF-8")
        // The upstream entry count, which the dictionary CI job will compare
        // against the number of rows actually ingested.
        #expect(Fixture.parsed.metadata["entries"] == "107619")
    }

    @Test("A plain entry")
    func plainEntry() throws {
        let entry = try #require(Fixture.entry("你好", reading: "ni3 hao3"))
        #expect(entry.headword.simplified == "你好")
        #expect(entry.readingDisplay == "nǐhǎo")
        // The real entry is /Hello!/Hi!/How are you?/ -- three senses, and the
        // capital matters, which is why this asserts against the actual text
        // rather than a lowercased guess.
        #expect(entry.senses.map(\.gloss.text) == ["Hello!", "Hi!", "How are you?"])
    }

    /// 37% of CC-CEDICT has identical scripts; storing nil rather than a
    /// duplicate is what makes "should I show both?" a model question.
    @Test("Identical scripts collapse to nil")
    func identicalScripts() throws {
        let same = try #require(Fixture.entry("你好", reading: "ni3 hao3"))
        #expect(same.headword.traditional == nil)
        #expect(same.headword.scriptsDiffer == false)

        let differs = try #require(Fixture.entry("中国", reading: "Zhong1 guo2"))
        #expect(differs.headword.traditional == "中國")
        #expect(differs.headword.scriptsDiffer)
    }
}

@Suite("CC-CEDICT homographs")
struct CEDICTHomographTests {
    /// The prototype's `WHERE simplified = ? LIMIT 1` destroyed every one of
    /// these. The parser must surface all of them, keyed by reading.
    @Test("了 has both of its readings")
    func le() {
        let readings = Set(Fixture.entries(for: "了").map(\.readingKey))
        #expect(readings.contains("le5"))
        #expect(readings.contains("liao3"))
    }

    @Test("好 has both of its readings")
    func hao() {
        let readings = Set(Fixture.entries(for: "好").map(\.readingKey))
        #expect(readings == ["hao3", "hao4"])
    }

    @Test("和 keeps all eight entries")
    func he() {
        #expect(Fixture.entries(for: "和").count == 8)
        // Several share a reading but differ in meaning, so deduplicating by
        // reading would lose entries too.
        #expect(Set(Fixture.entries(for: "和").map(\.readingKey)).count >= 6)
    }

    /// Capitalisation distinguishes the surname from the common word, which
    /// is how candidate readings get ranked later.
    @Test("宿 keeps the capitalised surname reading separately")
    func su() {
        let readings = Set(Fixture.entries(for: "宿").map(\.readingKey))
        #expect(readings.contains("su4"))
        #expect(readings.contains("Su4"))
        #expect(readings.contains("xiu3"))
        #expect(readings.contains("xiu4"))
    }
}

@Suite("CC-CEDICT readings")
struct CEDICTReadingTests {
    /// All four `u:` bases in the dictionary, and the one where the tone mark
    /// lands on the `e` rather than the ü.
    @Test("Umlaut readings render correctly", arguments: [
        ("女", "nu:3", "nǚ"),
        ("旅", "lu:3", "lǚ"),
        ("略", "lu:e4", "lüè"), // mark on the e, not the ü
        ("虐", "nu:e4", "nüè"),
    ])
    func umlauts(headword: String, key: String, display: String) throws {
        let entry = try #require(Fixture.entry(headword, reading: key))
        #expect(entry.readingDisplay == display)
    }

    @Test("Tone placement on real entries", arguments: [
        ("六", "liu4", "liù"),
        ("对", "dui4", "duì"),
        ("北京", "Bei3 jing1", "Běijīng"),
    ])
    func tonePlacement(headword: String, key: String, display: String) throws {
        let entry = try #require(Fixture.entry(headword, reading: key))
        #expect(entry.readingDisplay == display)
    }

    /// The reading key is what makes entries from different dictionaries
    /// group under one pronunciation, so it must round-trip exactly.
    @Test("Reading keys round-trip to CC-CEDICT's own spelling")
    func readingKeyRoundTrips() {
        for entry in Fixture.parsed.entries {
            let reparsed = Pinyin.parse(numeric: entry.readingKey)
            #expect(
                Pinyin.display(reparsed, style: .numeric) == entry.readingKey,
                "key did not round-trip for \(entry.headword.simplified)",
            )
        }
    }

    /// The non-syllable forms really do occur, and must survive parsing
    /// rather than being dropped or mistaken for syllables.
    @Test("Non-syllable reading forms survive")
    func nonSyllableForms() {
        let all = Fixture.parsed.entries
        #expect(all.contains { $0.reading.contains(.unknown) }, "no xx5 entry")
        #expect(all.contains { $0.reading.contains(.separator(",")) }, "no comma entry")
        #expect(all.contains { $0.reading.contains(.separator("·")) }, "no interpunct entry")
        #expect(all.contains { entry in
            entry.reading
                .contains {
                    if case let .syllable(found) = $0 {
                        found.base == "m"
                    } else {
                        false
                    }
                }
        }, "no m2 entry")
    }
}

@Suite("CC-CEDICT senses")
struct CEDICTSenseTests {
    /// A sense that only says "variant of X" is a poor one-line summary, so
    /// the UI needs to be able to tell it apart from a real definition.
    @Test("Reference senses are classified")
    func referenceSenses() {
        let all = Fixture.parsed.entries.flatMap(\.senses)
        #expect(all.contains { $0.kind == .reference })
        #expect(all.contains { $0.kind == .label })
        #expect(all.contains { $0.kind == .definition })

        for sense in all where sense.gloss.text.lowercased().hasPrefix("variant of ") {
            #expect(sense.kind == .reference)
        }
        for sense in all where sense.gloss.text.lowercased().hasPrefix("surname ") {
            #expect(sense.kind == .label)
        }
    }

    @Test("Summary prefers a real definition over a cross-reference")
    func summaryPrefersDefinition() {
        let entry = DictionaryEntry(
            headword: Headword(simplified: "x", traditional: nil),
            reading: Pinyin.parse(numeric: "xx5"),
            senses: [
                Sense(id: 0, kind: .reference, gloss: Gloss(text: "variant of 甲")),
                Sense(id: 1, kind: .definition, gloss: Gloss(text: "an actual meaning")),
            ],
        )
        #expect(entry.summarySense?.gloss.text == "an actual meaning")
    }

    /// Senses are not split on `;`. Only about 2% of entries contain one, and
    /// splitting mangles text like `Down's syndrome; trisomy 21`.
    @Test("Semicolons do not split a sense")
    func semicolonsAreKept() {
        let parsed = CEDICTParser.parse("X X [xx5] /first; still first/second/\r\n")
        #expect(parsed.entries.count == 1)
        #expect(parsed.entries[0].senses.count == 2)
        #expect(parsed.entries[0].senses[0].gloss.text == "first; still first")
    }

    @Test("Cross-references inside glosses are extracted and the markup removed")
    func crossReferences() {
        let parsed = CEDICTParser.parse("獅子 狮子 [shi1 zi5] /see 獅子|狮子[shi1 zi5] for details/\r\n")
        let gloss = parsed.entries[0].senses[0].gloss
        #expect(gloss.text == "see 狮子 for details", "got \(gloss.text)")
        #expect(gloss.references.count == 1)
        let reference = gloss.references[0]
        #expect(reference.simplified == "狮子")
        #expect(reference.traditional == "獅子")
        #expect(reference.reading == "shi1 zi5")
        // The range must select exactly the reference in the rewritten text.
        let utf16 = Array(gloss.text.utf16)
        let slice = String(decoding: utf16[reference.range], as: UTF16.self)
        #expect(slice == "狮子")
    }

    @Test("A bare Han run is prose, not a reference")
    func bareHanIsNotAReference() {
        let parsed = CEDICTParser.parse("中國 中国 [Zhong1 guo2] /China/the Middle Kingdom 中国/\r\n")
        let senses = parsed.entries[0].senses
        // Computed outside the macro: #expect wraps the call in a rethrows
        // helper, which then demands a `try` this has no use for.
        let noneHaveReferences = senses.allSatisfy(\.gloss.references.isEmpty)
        #expect(noneHaveReferences)
        #expect(senses[1].gloss.text == "the Middle Kingdom 中国")
    }
}

@Suite("CC-CEDICT malformed input")
struct CEDICTMalformedTests {
    /// A dictionary is third-party data nobody here controls. One bad line
    /// should cost one entry, not the import.
    @Test("Malformed lines are reported and skipped, not fatal", arguments: [
        ("X X xx5] /a/", CEDICTParser.Diagnostic.Kind.missingPinyinBrackets),
        ("X X [xx5] a/", .missingDefinitions),
        ("X X [xx5]", .missingDefinitions),
        ("XX", .tooFewFields),
        ("X X [xx5] //", .missingDefinitions),
    ])
    func malformed(line: String, kind: CEDICTParser.Diagnostic.Kind) {
        let parsed = CEDICTParser.parse(line + "\r\n")
        #expect(parsed.entries.isEmpty)
        #expect(parsed.diagnostics.count == 1)
        #expect(parsed.diagnostics.first?.kind == kind)
    }

    @Test("A bad line does not stop the ones around it")
    func recovery() {
        let text = """
        你好 你好 [ni3 hao3] /hello/\r
        this line is broken\r
        中國 中国 [Zhong1 guo2] /China/\r

        """
        let parsed = CEDICTParser.parse(text)
        #expect(parsed.entries.count == 2)
        #expect(parsed.diagnostics.count == 1)
        // 1-based, so it matches what an editor shows.
        #expect(parsed.diagnostics[0].line == 2)
    }

    @Test("Line-ending and whitespace variations", arguments: [
        "你好 你好 [ni3 hao3] /hello/\r\n", // CRLF, as shipped
        "你好 你好 [ni3 hao3] /hello/\n", // LF
        "你好 你好 [ni3 hao3] /hello/", // no trailing newline
    ])
    func lineEndings(text: String) {
        let parsed = CEDICTParser.parse(text)
        #expect(parsed.entries.count == 1)
        #expect(parsed.diagnostics.isEmpty)
    }

    @Test("Empty and comment-only input")
    func degenerate() {
        #expect(CEDICTParser.parse("").entries.isEmpty)
        #expect(CEDICTParser.parse("\r\n\r\n").entries.isEmpty)
        let commentsOnly = CEDICTParser.parse("# a comment\r\n#! key=value\r\n")
        #expect(commentsOnly.entries.isEmpty)
        #expect(commentsOnly.diagnostics.isEmpty)
        #expect(commentsOnly.metadata["key"] == "value")
    }
}

@Suite("CC-CEDICT regressions")
struct CEDICTRegressionTests {
    /// Blank lines must not shift diagnostics. Dropping them made every
    /// reported line number after a blank one point at the wrong line.
    @Test("Diagnostics survive blank lines with the right line number")
    func blankLinesDoNotShiftLineNumbers() {
        let text = "你好 你好 [ni3 hao3] /hello/\r\n\r\n\r\nbroken line\r\n"
        let parsed = CEDICTParser.parse(text)
        #expect(parsed.entries.count == 1)
        #expect(parsed.diagnostics.map(\.line) == [4])
    }

    /// `xx5` is the merge key for an unknown reading. Rendering it as `?`
    /// collapsed every unknown onto one key, which would let unrelated
    /// entries merge once several dictionaries are installed.
    @Test("An unknown reading keeps its key but still displays as ?")
    func unknownReadingKey() {
        let tokens = Pinyin.parse(numeric: "xx5")
        #expect(Pinyin.display(tokens, style: .numeric) == "xx5")
        #expect(Pinyin.display(tokens, style: .diacritic) == "?")

        let entry = Fixture.parsed.entries.first { $0.reading.contains(.unknown) }
        #expect(entry?.readingKey == "xx5")
    }

    /// A headword containing CJK punctuation is one reference, not two. The
    /// scan used to stop at the comma and resume mid-phrase, recording only
    /// the tail and linking to the wrong entry.
    @Test("A reference containing CJK punctuation is captured whole")
    func punctuatedReference() {
        let line = "一不做，二不休 一不做，二不休 [yi1 bu4 zuo4 , er4 bu4 xiu1] "
            + "/see 一不做，二不休[yi1 bu4 zuo4 , er4 bu4 xiu1]/\r\n"
        let gloss = CEDICTParser.parse(line).entries[0].senses[0].gloss
        #expect(gloss.references.map(\.simplified) == ["一不做，二不休"])
        #expect(gloss.text == "see 一不做，二不休")
    }

    /// ...but ASCII punctuation and spaces separate words in ordinary prose,
    /// so a scan must not run across them and swallow a whole phrase.
    @Test("ASCII punctuation still ends a reference scan")
    func asciiPunctuationStopsScan() {
        let line = "甲 甲 [jia3] /see 甲[jia3], and also 乙[yi3]/\r\n"
        let gloss = CEDICTParser.parse(line).entries[0].senses[0].gloss
        #expect(gloss.references.map(\.simplified) == ["甲", "乙"])
        #expect(gloss.text == "see 甲, and also 乙")
    }
}
