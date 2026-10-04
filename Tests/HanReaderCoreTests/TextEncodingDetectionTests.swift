// HanReader — MIT licensed. See LICENSE.

import Foundation
import Testing
@testable import HanReaderCore

/// A decoder that answers from a script, so the detection *rules* can be
/// tested without depending on what any platform's encoding tables accept.
///
/// This is the reason `TextDecoding` is injected rather than called directly,
/// and it is worth stating: with the real decoder, a test for "falls through
/// to the next candidate" would depend on CoreFoundation rejecting a
/// particular byte sequence, which is a fact about macOS rather than about
/// this code.
private struct ScriptedDecoder: TextDecoding {
    var results: [SourceTextEncoding: String?] = [:]
    /// Encodings asked about, in order, so a test can assert that a later
    /// candidate was never reached.
    final class Log: @unchecked Sendable {
        var asked: [SourceTextEncoding] = []
    }

    let log = Log()

    func decode(_: Data, as encoding: SourceTextEncoding) -> String? {
        log.asked.append(encoding)
        // Double optional: a key present with a nil value means "this
        // encoding was tried and refused", which is different from a key
        // that is absent. `flatMap` flattens both to nil.
        return results[encoding].flatMap(\.self)
    }
}

private let sample = Data("ignored by the scripted decoder".utf8)

@Suite("Text encoding detection")
struct TextEncodingDetectionTests {
    // MARK: - Byte-order marks

    @Test("A byte-order mark is conclusive", arguments: [
        ([0xEF, 0xBB, 0xBF] as [UInt8], SourceTextEncoding.utf8),
        ([0xFF, 0xFE], .utf16LittleEndian),
        ([0xFE, 0xFF], .utf16BigEndian),
    ])
    func marksAreHonoured(bytes: [UInt8], expected: SourceTextEncoding) throws {
        let decoder = ScriptedDecoder(results: [expected: "中文"])
        let detected = try #require(
            TextEncodingDetector.detect(Data(bytes + [0x41]), using: decoder),
        )
        #expect(detected.encoding == expected)
        #expect(detected.fromByteOrderMark)
        // Nothing else was even tried: a declaration is not a guess.
        #expect(decoder.log.asked == [expected])
    }

    /// A UTF-32LE mark *begins* with a UTF-16LE mark, so a detector that
    /// checks UTF-16 first identifies every UTF-32 file as UTF-16 and decodes
    /// it into interleaved nulls — confidently, and with a mark to point at
    /// as justification.
    @Test("A UTF-32 mark is not mistaken for UTF-16", arguments: [
        [0xFF, 0xFE, 0x00, 0x00] as [UInt8],
        [0x00, 0x00, 0xFE, 0xFF],
    ])
    func utf32MarksAreNotUtf16(bytes: [UInt8]) {
        #expect(TextEncodingDetector.byteOrderMark(in: Data(bytes)) == nil)
    }

    /// A file that declares an encoding and then is not it is a broken file.
    /// Reinterpreting it as something else would turn a clear failure into a
    /// confusing success.
    @Test("A marked file that will not decode is a failure, not a fallback")
    func markedButUndecodableFails() {
        let decoder = ScriptedDecoder(results: [.gb18030: "中文"])
        let data = Data([0xFF, 0xFE] + Array("x".utf8))
        #expect(TextEncodingDetector.detect(data, using: decoder) == nil)
        #expect(decoder.log.asked == [.utf16LittleEndian])
    }

    // MARK: - Ordering

    @Test("Without a mark, UTF-8 is tried first and wins outright")
    func utf8First() throws {
        let decoder = ScriptedDecoder(results: [.utf8: "中文很好", .gb18030: "中文很好"])
        let detected = try #require(TextEncodingDetector.detect(sample, using: decoder))
        #expect(detected.encoding == .utf8)
        #expect(!detected.fromByteOrderMark)
        #expect(decoder.log.asked == [.utf8])
    }

    @Test("A file that is not UTF-8 falls through to GB18030")
    func fallsThroughToGb18030() throws {
        let decoder = ScriptedDecoder(results: [.utf8: nil, .gb18030: "中文很好"])
        let detected = try #require(TextEncodingDetector.detect(sample, using: decoder))
        #expect(detected.encoding == .gb18030)
        #expect(decoder.log.asked == [.utf8, .gb18030])
    }

    /// Simplified before Traditional, because that is the larger share of
    /// what gets imported — and because nothing here can tell the two apart
    /// on content, so the order *is* the decision.
    @Test("Big5 is tried after GB18030")
    func big5Last() throws {
        let decoder = ScriptedDecoder(results: [.utf8: nil, .gb18030: nil, .big5: "中文很好"])
        let detected = try #require(TextEncodingDetector.detect(sample, using: decoder))
        #expect(detected.encoding == .big5)
        #expect(decoder.log.asked == [.utf8, .gb18030, .big5])
    }

    @Test("Nothing convincing means ask the reader, not guess")
    func nothingDecodes() {
        let decoder = ScriptedDecoder(results: [:])
        #expect(TextEncodingDetector.detect(sample, using: decoder) == nil)
    }

    @Test("An empty file is not an error")
    func emptyData() throws {
        let decoder = ScriptedDecoder(results: [:])
        let detected = try #require(TextEncodingDetector.detect(Data(), using: decoder))
        #expect(detected.text.isEmpty)
        #expect(decoder.log.asked.isEmpty)
    }

    // MARK: - Plausibility

    /// The case that matters: a PDF or a ZIP opened as text. GB18030 maps
    /// almost any byte sequence, so it decodes happily and every other check
    /// here passes — the control characters are the only tell.
    @Test("A decode full of control characters is rejected")
    func binaryIsRejected() {
        let bytes = (0 ..< 40).map { UInt8($0 % 20) }
        let binary = String(bytes: bytes, encoding: .utf8) ?? ""
        let decoder = ScriptedDecoder(results: [.utf8: nil, .gb18030: binary])
        #expect(TextEncodingDetector.detect(sample, using: decoder) == nil)
    }

    @Test("Real prose scores above the floor")
    func proseIsPlausible() {
        let prose = "中国人民解放军在北京举行了阅兵式。\niPhone 15 在 2026 年发布。"
        #expect(TextPlausibility.score(prose) >= TextEncodingDetector.plausibilityFloor)
    }

    @Test("Tabs and newlines are text; other control characters are not")
    func whichControlsCount() {
        #expect(TextPlausibility.score("a\tb\nc\r\n") == 1)
        #expect(TextPlausibility.score("\u{0000}\u{0007}\u{001B}") == 0)
    }

    /// A strict decoder should return nil rather than substitute, so a
    /// replacement character means something already went wrong — it counts
    /// several times over so that a handful of them sinks the result.
    @Test("Replacement characters weigh heavily")
    func replacementCharactersAreCostly() {
        let mostlyFine = String(repeating: "中", count: 50) + "\u{FFFD}\u{FFFD}"
        #expect(TextPlausibility.score(mostlyFine) < TextEncodingDetector.plausibilityFloor)
        #expect(TextPlausibility.score(String(repeating: "中", count: 50)) == 1)
    }

    @Test("An empty string is vacuously plausible")
    func emptyIsPlausible() {
        #expect(TextPlausibility.score("") == 1)
    }

    // MARK: - Previews

    @Test("Every candidate that decodes is offered, in a stable order")
    func previewsAreOffered() {
        let decoder = ScriptedDecoder(results: [
            .utf8: nil,
            .gb18030: "简体中文",
            .big5: "繁體中文",
            .utf16LittleEndian: "mojibake",
        ])
        let previews = TextEncodingDetector.previews(of: sample, using: decoder)

        #expect(previews.map(\.encoding) == [.gb18030, .big5, .utf16LittleEndian])
        #expect(previews.first?.preview == "简体中文")
    }

    /// Ordered by `detectionOrder`, never by score. Two plausible CJK decodes
    /// score within noise of each other, so sorting by score would reshuffle
    /// the list between files and present that noise as a recommendation.
    @Test("Previews are not reordered by score")
    func previewsIgnoreScore() {
        let decoder = ScriptedDecoder(results: [
            .utf8: "中\u{0007}文",
            .gb18030: "完全正常的中文",
        ])
        let previews = TextEncodingDetector.previews(of: sample, using: decoder)
        #expect(previews.map(\.encoding) == [.utf8, .gb18030])
        #expect(previews[0].plausibility < previews[1].plausibility)
    }

    @Test("A preview is clipped to its limit")
    func previewsAreClipped() {
        let long = String(repeating: "中", count: 1000)
        let decoder = ScriptedDecoder(results: [.utf8: long])
        let previews = TextEncodingDetector.previews(of: sample, using: decoder, limit: 400)
        #expect(previews.first?.preview.count == 400)
    }

    @Test("Every encoding has a name to show in a picker")
    func everyEncodingIsNameable() {
        for encoding in SourceTextEncoding.allCases {
            #expect(!encoding.displayName.isEmpty)
        }
    }
}
