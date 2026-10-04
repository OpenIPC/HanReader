// HanReader — MIT licensed. See LICENSE.

import Foundation
import Testing
@testable import HanReaderCore

@Suite("Sense coding")
struct SenseCodingTests {
    private enum CodingTestError: Error { case notUTF8 }

    private func encoded(_ sense: Sense) throws -> String {
        let data = try JSONEncoder().encode(sense)
        // A plain unwrap rather than `#require`: this helper is called from
        // inside `#expect`, and a macro expanded within a macro's argument
        // is a recursive expansion the compiler refuses.
        guard let text = String(bytes: data, encoding: .utf8) else {
            throw CodingTestError.notUTF8
        }
        return text
    }

    /// Writing `"level":0,"partOfSpeech":[],"registers":[],"examples":[]`
    /// for every CC-CEDICT sense added 14 MB to a 35 MB dictionary — 40% of
    /// the file to say "nothing here" 107,619 times.
    @Test("A plain sense encodes none of the fields it does not use")
    func defaultsAreOmitted() throws {
        let json = try encoded(Sense(id: 0, kind: .definition, gloss: Gloss(text: "to love")))
        for absent in [
            "level",
            "parent",
            "label",
            "partOfSpeech",
            "registers",
            "examples",
            "styles",
            "references",
        ] {
            #expect(!json.contains(absent), "\(absent) should not be written")
        }
        #expect(json.contains("to love"))
    }

    @Test("A sense that uses the fields writes them")
    func populatedFieldsAreWritten() throws {
        let sense = Sense(
            id: 1,
            kind: .definition,
            gloss: Gloss(text: "любить", styles: [StyleRun(style: .italic, range: 0 ..< 6)]),
            level: 1,
            parent: 0,
            label: "1)",
            partOfSpeech: ["гл."],
            examples: [UsageExample(chinese: "爱", translation: "любить", raw: "爱 любить")],
        )
        let json = try encoded(sense)
        for present in ["level", "parent", "label", "partOfSpeech", "examples", "styles"] {
            #expect(json.contains(present))
        }
        #expect(!json.contains("registers"), "still omitted when empty")
    }

    @Test("Everything round-trips")
    func roundTrip() throws {
        let sense = Sense(
            id: 3,
            kind: .reference,
            gloss: Gloss(
                text: "см. 磁性碰锁",
                references: [CrossReference(
                    simplified: "磁性碰锁", traditional: nil, reading: nil, range: 4 ..< 9,
                )],
                styles: [StyleRun(style: .bold, range: 0 ..< 3)],
            ),
            level: 2,
            parent: 1,
            label: "а)",
            partOfSpeech: ["сущ."],
            registers: ["бот."],
            examples: [UsageExample(chinese: "锁", translation: "замок", raw: "锁 замок")],
        )
        let data = try JSONEncoder().encode(sense)
        #expect(try JSONDecoder().decode(Sense.self, from: data) == sense)
    }

    /// A container compiled before these fields existed must still open. A
    /// synthesised `init(from:)` fails on any missing key, which would make
    /// a model addition force a re-import of a 3.4-million-entry dictionary.
    @Test("A payload written before these fields existed still decodes")
    func oldPayloadDecodes() throws {
        let old = #"{"id":0,"kind":0,"gloss":{"text":"to love","references":[]}}"#
        let sense = try JSONDecoder().decode(Sense.self, from: Data(old.utf8))
        #expect(sense.gloss.text == "to love")
        #expect(sense.level == 0)
        #expect(sense.examples.isEmpty)
        #expect(sense.label == nil)
    }

    @Test("A gloss written before styles existed still decodes")
    func oldGlossDecodes() throws {
        let old = #"{"text":"to love"}"#
        let gloss = try JSONDecoder().decode(Gloss.self, from: Data(old.utf8))
        #expect(gloss.text == "to love")
        #expect(gloss.styles.isEmpty)
        #expect(gloss.references.isEmpty)
    }
}
