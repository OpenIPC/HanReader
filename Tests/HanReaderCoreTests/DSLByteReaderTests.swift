// HanReader — MIT licensed. See LICENSE.

import Foundation
import Testing
@testable import HanReaderCore

// MARK: - Helpers

/// Encodes text the way ABBYY writes a DSL file.
private func utf16(_ text: String, bigEndian: Bool = false, bom: Bool = true) -> [UInt8] {
    var bytes: [UInt8] = []
    if bom {
        bytes += bigEndian ? [0xFE, 0xFF] : [0xFF, 0xFE]
    }
    for unit in Array(text.utf16) {
        let low = UInt8(unit & 0xFF)
        let high = UInt8(unit >> 8)
        bytes += bigEndian ? [high, low] : [low, high]
    }
    return bytes
}

private func lines(
    _ bytes: [UInt8],
    chunkSize: Int = DSLByteReader.defaultChunkSize,
    resumingAt offset: Int? = nil,
) throws
    -> [DSLLine]
{
    var reader = try DSLByteReader(
        source: DSLMemoryBytes(bytes),
        resumingAt: offset,
        chunkSize: chunkSize,
    )
    var result: [DSLLine] = []
    while let line = try reader.next() {
        result.append(line)
    }
    return result
}

/// The real shape of a BKRS file: two CRLF header lines, a blank line, then
/// LF-terminated cards, ending with a line feed.
private let header = "#NAME \"大БКРС\"\r\n#INDEX_LANGUAGE \"Chinese\"\r\n"
    + "#CONTENTS_LANGUAGE \"Russian\"\n#INCLUDE \"dabkrs_2.dsl\"\n\n"
private let cards = "爱\n ài\n [m1]любить[/m]\n了\n le, liǎo\n [m1]частица[/m]\n"

@Suite("DSL byte reader")
struct DSLByteReaderTests {
    // MARK: - The alignment trap

    /// In UTF-16LE a line feed is the code unit `0x000A` — the bytes `0A 00`
    /// **at an even offset**. `ਅ` is U+0A05 and `昀` is U+6600, so the two
    /// together are `05 0A 00 66`: the pair appears at an odd offset, inside
    /// a character. A scanner that searches the raw bytes breaks the line
    /// there and splits one character in half.
    @Test("A misaligned line-feed byte pair is not a line break")
    func misalignedPairIsNotABreak() throws {
        let bytes = utf16("x\u{0A05}\u{6600}y\nz\n")

        // The trap is actually present in this input, so the assertion below
        // is not vacuous.
        let pair = (0 ..< (bytes.count - 1)).first { bytes[$0] == 0x0A && bytes[$0 + 1] == 0x00 }
        let trap = try #require(pair)
        #expect(!trap.isMultiple(of: 2))

        let result = try lines(bytes)
        #expect(result.map(\.text) == ["x\u{0A05}\u{6600}y", "z"])
    }

    /// Reading the same bytes two at a time puts the trap at the very end of
    /// a chunk, which is where a scanner that forgets to realign after a
    /// refill goes wrong.
    @Test("The alignment holds across chunk boundaries", arguments: [2, 4, 6, 8, 16])
    func misalignedPairAcrossChunks(chunkSize: Int) throws {
        let result = try lines(utf16("x\u{0A05}\u{6600}y\nz\n"), chunkSize: chunkSize)
        #expect(result.map(\.text) == ["x\u{0A05}\u{6600}y", "z"])
    }

    // MARK: - Line endings

    /// Each BKRS file mixes exactly two CRLF lines in among three million LF
    /// ones, so neither terminator is the one to split on.
    @Test("Both line endings are handled in the same file")
    func mixedLineEndings() throws {
        let result = try lines(utf16(header + cards))
        #expect(result.map(\.text) == [
            "#NAME \"大БКРС\"",
            "#INDEX_LANGUAGE \"Chinese\"",
            "#CONTENTS_LANGUAGE \"Russian\"",
            "#INCLUDE \"dabkrs_2.dsl\"",
            "",
            "爱", " ài", " [m1]любить[/m]",
            "了", " le, liǎo", " [m1]частица[/m]",
        ])
    }

    /// All three files end with a line feed. Splitting the text yields an
    /// empty final element, and at the card level an unindented empty line is
    /// indistinguishable from a headword.
    @Test("A trailing newline does not produce an empty final line")
    func trailingNewline() throws {
        #expect(try lines(utf16("a\nb\n")).map(\.text) == ["a", "b"])
    }

    @Test("A file with no trailing newline still yields its last line")
    func noTrailingNewline() throws {
        #expect(try lines(utf16("a\nb")).map(\.text) == ["a", "b"])
    }

    /// A blank line inside the file is a line, not nothing — the header is
    /// separated from the body by one, and the card reader needs to see it.
    @Test("A blank line is reported")
    func blankLine() throws {
        #expect(try lines(utf16("a\n\nb\n")).map(\.text) == ["a", "", "b"])
    }

    @Test("An empty file yields no lines")
    func emptyFile() throws {
        #expect(try lines([]).isEmpty)
    }

    @Test("A file that is nothing but a byte-order mark yields no lines")
    func bomOnly() throws {
        #expect(try lines(utf16("")).isEmpty)
    }

    // MARK: - Offsets

    /// Byte offsets, because that is what a resumed import seeks to.
    @Test("Each line carries the byte offset it started at")
    func offsets() throws {
        // BOM (2) + "a\n" (4) + "bb\n" (6).
        let result = try lines(utf16("a\nbb\nc\n"))
        #expect(result.map(\.offset) == [2, 6, 12])
    }

    @Test("Offsets are unaffected by the chunk size", arguments: [2, 4, 6, 10, 4096])
    func offsetsAcrossChunks(chunkSize: Int) throws {
        let result = try lines(utf16(header + cards), chunkSize: chunkSize)
        #expect(try result == lines(utf16(header + cards)))
    }

    /// The resume contract: an offset this reader reported, handed back to a
    /// new reader, continues from exactly that line.
    @Test("Resuming at a reported offset continues from that line")
    func resume() throws {
        let bytes = utf16(header + cards)
        let all = try lines(bytes)
        let start = try #require(all.indices.last.map { $0 - 3 })
        let resumed = try lines(bytes, resumingAt: all[start].offset)
        #expect(resumed == Array(all[start...]))
    }

    /// A resume offset is taken literally rather than being re-sniffed for a
    /// byte-order mark, so the first character after a checkpoint is not
    /// mistaken for one.
    @Test("A resume offset is not re-interpreted as a byte-order mark")
    func resumeDoesNotSkipABOM() throws {
        let bytes = utf16("\u{FEFF}a\nb\n")
        let result = try lines(bytes, resumingAt: 2)
        #expect(result.map(\.text) == ["\u{FEFF}a", "b"])
    }

    // MARK: - Malformed files

    /// The last character is cut in half, so every offset past it would be a
    /// guess. This is the `kill -9`-during-a-copy case.
    @Test("An odd-length UTF-16 file is refused")
    func oddByteLength() throws {
        var bytes = utf16("a\nb\n")
        bytes.removeLast()
        #expect(throws: DSLByteError.oddByteLength(byteCount: bytes.count)) {
            _ = try lines(bytes)
        }
    }

    @Test("A resume offset inside a code unit is refused")
    func misalignedOffset() throws {
        #expect(throws: DSLByteError.misalignedOffset(5)) {
            _ = try lines(utf16("a\nb\n"), resumingAt: 5)
        }
    }

    @Test("A resume offset past the end is refused")
    func offsetOutOfRange() throws {
        let bytes = utf16("a\n")
        #expect(throws: DSLByteError.offsetOutOfRange(offset: 100, byteCount: bytes.count)) {
            _ = try lines(bytes, resumingAt: 100)
        }
    }

    /// Nothing is dropped and nothing throws: one mangled character costs
    /// that character, not the card around it.
    @Test("An unpaired surrogate becomes a replacement character")
    func unpairedSurrogate() throws {
        var bytes = utf16("a")
        bytes += [0x00, 0xD8] // U+D800, a high surrogate with no low one
        bytes += utf16("b\n", bom: false)
        #expect(try lines(bytes).map(\.text) == ["a\u{FFFD}b"])
    }

    // MARK: - Encoding detection

    @Test("A UTF-16LE byte-order mark is detected and skipped")
    func littleEndianBOM() throws {
        var reader = try DSLByteReader(source: DSLMemoryBytes(utf16("爱\n")))
        #expect(reader.encoding == .utf16LittleEndian)
        #expect(try reader.next()?.text == "爱")
    }

    @Test("A UTF-16BE byte-order mark is detected and skipped")
    func bigEndianBOM() throws {
        let bytes = utf16("#NAME\n爱\n", bigEndian: true)
        var reader = try DSLByteReader(source: DSLMemoryBytes(bytes))
        #expect(reader.encoding == .utf16BigEndian)
        #expect(try reader.next()?.text == "#NAME")
        #expect(try reader.next()?.text == "爱")
    }

    @Test("A UTF-8 byte-order mark is detected and skipped")
    func utf8BOM() throws {
        var bytes: [UInt8] = [0xEF, 0xBB, 0xBF]
        bytes += Array("爱\n ài\n".utf8)
        var reader = try DSLByteReader(source: DSLMemoryBytes(bytes))
        #expect(reader.encoding == .utf8)
        #expect(try reader.next()?.text == "爱")
        #expect(try reader.next()?.text == " ài")
    }

    /// Hand-made DSL dictionaries are commonly UTF-8 with no mark, so that is
    /// the default rather than a refusal.
    @Test("A file with no mark is read as UTF-8")
    func bomlessUTF8() throws {
        let bytes = Array("爱\n ài\n [m1]любить[/m]\n".utf8)
        var reader = try DSLByteReader(source: DSLMemoryBytes(bytes))
        #expect(reader.encoding == .utf8)
        #expect(try reader.next()?.text == "爱")
    }

    /// UTF-8 text cannot contain a NUL byte, so NUL bytes all at odd offsets
    /// can only be the high halves of UTF-16LE code units. Without this a
    /// mark-less UTF-16 file decodes to mojibake with no error at all.
    @Test("A mark-less UTF-16 file is detected from its NUL bytes", arguments: [false, true])
    func bomlessUTF16(bigEndian: Bool) throws {
        let bytes = utf16("#NAME \"x\"\n爱\n", bigEndian: bigEndian, bom: false)
        var reader = try DSLByteReader(source: DSLMemoryBytes(bytes))
        #expect(reader.encoding == (bigEndian ? .utf16BigEndian : .utf16LittleEndian))
        #expect(try reader.next()?.text == "#NAME \"x\"")
        #expect(try reader.next()?.text == "爱")
    }

    /// Chinese characters have no zero byte in either half, so a mark-less
    /// UTF-16 file that opens with one cannot be told from UTF-8. The format
    /// rules it out — a DSL file opens with `#NAME` — and the sniff is
    /// documented as needing that.
    @Test("Detection reports where it cannot tell")
    func detectionLimits() {
        #expect(DSLByteReader.detectEncoding(prefix: []) == (.utf8, 0))
        #expect(DSLByteReader.detectEncoding(prefix: Array("爱 ài".utf8)) == (.utf8, 0))
        // 爱 in UTF-16LE is 1B 72 — no zero byte to sniff.
        #expect(DSLByteReader.detectEncoding(prefix: [0x1B, 0x72]) == (.utf8, 0))
        // A zero byte in each half is not a byte order.
        #expect(DSLByteReader.detectEncoding(prefix: [0x00, 0x00]) == (.utf8, 0))
    }
}
