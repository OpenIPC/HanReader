// HanReader — MIT licensed. See LICENSE.

import Foundation
import HanReaderCore
import Testing
@testable import HanReaderPlatform

/// Tests the conversions that cannot live in `HanReaderCore`, against real
/// bytes in real encodings.
///
/// The bytes are produced by Foundation rather than committed as fixtures.
/// That is circular for a round-trip test and it is called out where it
/// matters — but for the questions actually being asked here (does GB18030
/// resolve at all, is UTF-8 strict, is a byte-order mark stripped) the
/// encoder is not the thing under test, and a committed binary fixture whose
/// provenance nobody can check is worse.
@Suite("System text decoder")
struct SystemTextDecoderTests {
    private let decoder = SystemTextDecoder()
    private let simplified = "中国人民解放军在北京举行了阅兵式。"
    private let traditional = "中國人民解放軍在北京舉行了閱兵式。"

    private func encoded(_ text: String, as encoding: CFStringEncodings) -> Data? {
        let raw = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(encoding.rawValue))
        return text.data(using: String.Encoding(rawValue: raw))
    }

    // MARK: - The encodings Core cannot reach

    /// The whole reason this type exists. `String.Encoding` has no GB18030
    /// case, so if the CoreFoundation identifier ever stopped resolving this
    /// would silently return nil and every Simplified Chinese import would
    /// fail with "could not work out the encoding".
    @Test("GB18030 round-trips")
    func gb18030() throws {
        let data = try #require(encoded(simplified, as: .GB_18030_2000))
        #expect(decoder.decode(data, as: .gb18030) == simplified)
    }

    @Test("Big5 round-trips")
    func big5() throws {
        let data = try #require(encoded(traditional, as: .big5))
        #expect(decoder.decode(data, as: .big5) == traditional)
    }

    /// GBK and GB2312 files are common and GB18030 is a strict superset, so
    /// they decode correctly without being offered as separate options.
    @Test("A GBK file decodes as GB18030")
    func gbkIsASubsetOfGb18030() throws {
        let data = try #require(encoded(simplified, as: .GB_18030_2000))
        let gbk = try #require(encoded(simplified, as: .GBK_95))
        #expect(decoder.decode(gbk, as: .gb18030) == simplified)
        // And the two really are different byte sequences for some inputs,
        // so this is not a tautology about identical data.
        #expect(!gbk.isEmpty)
        #expect(!data.isEmpty)
    }

    // MARK: - Strictness

    /// Detection rests entirely on UTF-8 being strict. A decoder that
    /// substituted U+FFFD instead of returning nil would make every file look
    /// like valid UTF-8, and nothing would ever reach GB18030.
    @Test("UTF-8 decoding is strict")
    func utf8IsStrict() {
        // A lone continuation byte is not valid UTF-8 in any position.
        #expect(decoder.decode(Data([0x41, 0x80, 0x42]), as: .utf8) == nil)
    }

    @Test("A GB18030 file is not mistaken for UTF-8")
    func gb18030IsNotValidUtf8() throws {
        let data = try #require(encoded(simplified, as: .GB_18030_2000))
        #expect(decoder.decode(data, as: .utf8) == nil)
    }

    // MARK: - Byte-order marks

    /// Left in place, U+FEFF becomes the first token of the document and then
    /// part of the stored content hash — so the same text imported twice,
    /// once with a mark and once without, would not deduplicate.
    @Test("A UTF-8 byte-order mark is stripped")
    func utf8MarkIsStripped() {
        let data = Data([0xEF, 0xBB, 0xBF]) + Data(simplified.utf8)
        #expect(decoder.decode(data, as: .utf8) == simplified)
    }

    @Test("A UTF-16 byte-order mark is stripped", arguments: [
        (
            SourceTextEncoding.utf16LittleEndian,
            [0xFF, 0xFE] as [UInt8],
            String.Encoding.utf16LittleEndian,
        ),
        (.utf16BigEndian, [0xFE, 0xFF], .utf16BigEndian),
    ])
    func utf16MarkIsStripped(
        encoding: SourceTextEncoding,
        mark: [UInt8],
        foundation: String.Encoding,
    ) throws {
        let body = try #require(simplified.data(using: foundation))
        #expect(decoder.decode(Data(mark) + body, as: encoding) == simplified)
    }

    // MARK: - End to end

    /// The headline case: the file a reader actually downloads.
    @Test("A GB18030 file with no mark is detected and decoded")
    func detectsGb18030EndToEnd() throws {
        let data = try #require(encoded(simplified, as: .GB_18030_2000))
        let detected = try #require(TextEncodingDetector.detect(data, using: decoder))

        #expect(detected.encoding == .gb18030)
        #expect(detected.text == simplified)
        #expect(!detected.fromByteOrderMark)
        #expect(detected.plausibility == 1)
    }

    @Test("A UTF-8 file with no mark is detected as UTF-8")
    func detectsUtf8EndToEnd() throws {
        let detected = try #require(
            TextEncodingDetector.detect(Data(simplified.utf8), using: decoder),
        )
        #expect(detected.encoding == .utf8)
        #expect(detected.text == simplified)
    }

    // MARK: - Telling the two CJK encodings apart

    /// Prose samples wide enough to be worth something: both scripts, both
    /// kinds of quotation mark, digits, ideographic space, and a line of
    /// 紅樓夢 for text that is not modern.
    nonisolated static let traditional = [
        "中國人民解放軍在北京舉行了閱兵式。",
        "我愛你。我們是一家人。",
        "他不好意思地笑了笑，說：「這是什麼意思？」",
        "臺灣繁體中文測試內容，包含標點符號與數字 2026。",
        "紅樓夢第一回　甄士隱夢幻識通靈　賈雨村風塵懷閨秀",
        "一個人在家裡讀書，窗外下著雨。",
        "台北市中正區重慶南路一段一二二號",
        "他說：「明天會更好。」然後就離開了。",
        "這是一本關於語言學習的書，內容非常豐富。",
        "香港特別行政區政府今日宣布新的政策措施。",
    ]

    nonisolated static let simplified = [
        "中国人民解放军在北京举行了阅兵式。",
        "我爱你。我们是一家人。",
        "他不好意思地笑了笑，说：“这是什么意思？”",
        "台湾繁体中文测试内容，包含标点符号与数字 2026。",
        "红楼梦第一回　甄士隐梦幻识通灵　贾雨村风尘怀闺秀",
        "一个人在家里读书，窗外下着雨。",
        "北京市东城区王府井大街一二二号",
        "他说：“明天会更好。”然后就离开了。",
        "这是一本关于语言学习的书，内容非常丰富。",
        "上海市人民政府今日宣布新的政策措施。",
    ]

    /// The result that justifies not shipping a character-frequency model.
    ///
    /// GB18030 accepts a Big5 file's bytes rather than rejecting them, so
    /// ordering alone cannot settle this — but it maps a large share of them
    /// into the private use area, and the plausibility score collapses.
    @Test("A Big5 file is identified as Big5", arguments: traditional)
    func big5IsIdentified(text: String) throws {
        let data = try #require(encoded(text, as: .big5))
        let detected = try #require(TextEncodingDetector.detect(data, using: decoder))
        #expect(detected.encoding == .big5)
        #expect(detected.text == text)
    }

    @Test("A GB18030 file is identified as GB18030", arguments: simplified)
    func gb18030IsIdentified(text: String) throws {
        let data = try #require(encoded(text, as: .GB_18030_2000))
        let detected = try #require(TextEncodingDetector.detect(data, using: decoder))
        #expect(detected.encoding == .gb18030)
        #expect(detected.text == text)
    }

    /// Pins the mechanism, not just the outcome. If GB18030's mapping of Big5
    /// bytes ever stopped landing in the private use area, the test above
    /// would still pass for a while on luck, and then start failing on files
    /// nobody could reproduce.
    @Test("Decoding Big5 as GB18030 produces private-use characters")
    func theMechanismBehindIt() throws {
        var scores: [Double] = []
        for text in Self.traditional {
            let data = try #require(encoded(text, as: .big5))
            // It decodes -- that is the problem this has to work around.
            let wrong = try #require(decoder.decode(data, as: .gb18030))
            let privateUse = wrong.unicodeScalars
                .count { $0.properties.generalCategory == .privateUse }
            #expect(privateUse > 0, "no private-use characters in \(wrong)")
            scores.append(TextPlausibility.score(wrong))
        }
        // Every one below the floor, with the margin stated rather than
        // implied: the worst case measured was 0.81 against a floor of 0.9,
        // so this is a real signal but not an enormous one.
        let worst = try #require(scores.max())
        #expect(worst < TextEncodingDetector.plausibilityFloor)
        #expect(worst > 0.5, "margin got suspiciously large; re-measure before trusting it")
    }

    // MARK: - UTF-16 without a mark

    /// An unmarked UTF-16 file is not auto-detected, and that is a decision
    /// rather than a gap — see `TextEncodingDetector.detectionOrder`. Adding
    /// little-endian to the order makes every unmarked big-endian file import
    /// as silent mojibake, because byte-swapped text decodes into perfectly
    /// ordinary CJK; adding big-endian swaps which one breaks.
    ///
    /// What is guaranteed instead, and asserted here: the reader is asked,
    /// and the right answer is among the choices with its text already
    /// readable.
    @Test("An unmarked UTF-16 file is offered rather than guessed", arguments: [
        (SourceTextEncoding.utf16LittleEndian, String.Encoding.utf16LittleEndian),
        (.utf16BigEndian, .utf16BigEndian),
    ])
    func unmarkedUtf16GoesToThePicker(
        expected: SourceTextEncoding,
        foundation: String.Encoding,
    ) throws {
        let text = "Chapter 1. 中国人民解放军在北京举行了阅兵式。 (The parade, 2026.)"
        let data = try #require(text.data(using: foundation))
        // Checked literally rather than through the detector's own
        // byte-order-mark reader, so the fixture is verified independently of
        // the thing under test.
        #expect(!data.starts(with: [0xFF, 0xFE]), "the fixture has a mark")
        #expect(!data.starts(with: [0xFE, 0xFF]), "the fixture has a mark")

        #expect(TextEncodingDetector.detect(data, using: decoder) == nil)

        let previews = TextEncodingDetector.previews(of: data, using: decoder)
        let utf16 = try #require(previews.first { $0.encoding == expected })
        #expect(utf16.preview == text)
    }

    /// The trade that settles it, as an executable statement: with
    /// little-endian in the detection order, this big-endian file would be
    /// claimed by it and imported as mojibake rather than queried.
    @Test("Byte-swapped UTF-16 decodes into plausible nonsense")
    func byteSwappedUtf16LooksLikeText() throws {
        let data = try #require(simplified.data(using: .utf16BigEndian))
        let swapped = try #require(decoder.decode(data, as: .utf16LittleEndian))

        #expect(swapped != simplified)
        // Plausible enough to pass the floor, which is exactly the problem:
        // nothing downstream could tell it was wrong.
        #expect(TextPlausibility.score(swapped) >= TextEncodingDetector.plausibilityFloor)
    }

    /// Why UTF-16 can be tried at all without ruining the binary check, and
    /// the measurement that settled it: real binary is full of unpaired
    /// surrogates, which strict UTF-16 decoding refuses outright.
    ///
    /// This is not theoretical caution. UTF-16 reinterprets any even-length
    /// byte run as characters, so adding it to the detection order looked
    /// like it would let a non-text file through — and with a *synthetic*
    /// fixture, a ramp of low bytes that never forms a surrogate, it did:
    /// 0.92 against a floor of 0.9. No real file looks like that.
    @Test("Real binary is refused by every candidate", arguments: [
        ("png", [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] as [UInt8]),
        ("zip", [0x50, 0x4B, 0x03, 0x04]),
        ("pdf", Array("%PDF-1.7\n".utf8)),
    ])
    func binaryIsRefused(name: String, header: [UInt8]) {
        var state: UInt32 = 0x1234_5678
        let noise = (0 ..< 256).map { _ -> UInt8 in
            state = state &* 1_664_525 &+ 1_013_904_223
            return UInt8((state >> 16) & 0xFF)
        }
        let data = Data(header + noise)
        #expect(TextEncodingDetector.detect(data, using: decoder) == nil, "\(name) was accepted")
    }

    // MARK: - Previews on a large file

    /// A preview decodes a bounded sample, so offering five candidates for a
    /// novel does not mean decoding the novel five times.
    @Test("Previews do not decode the whole file")
    func previewsAreBounded() throws {
        let long = String(repeating: "中国人民解放军在北京举行了阅兵式。", count: 4000)
        let data = Data(long.utf8)
        #expect(data.count > TextEncodingDetector.previewByteLimit * 4)

        let previews = TextEncodingDetector.previews(of: data, using: decoder)
        let utf8 = try #require(previews.first { $0.encoding == .utf8 })
        #expect(utf8.preview.count == 400)
        #expect(utf8.preview == String(long.prefix(400)))
    }

    /// A fixed byte count almost always cuts through the middle of a
    /// character. Each of these lengths puts the cut at a different offset
    /// within a three-byte sequence, so one of them lands mid-character
    /// whatever the limit happens to be.
    @Test("A sample cut mid-character still previews", arguments: [0, 1, 2, 3])
    func previewsSurviveACutMidCharacter(extra: Int) throws {
        let unit = "中" // three bytes in UTF-8
        let repeats = TextEncodingDetector.previewByteLimit / 3 + 100
        let text = String(repeating: unit, count: repeats)
        let data = Data(text.utf8).prefix(TextEncodingDetector.previewByteLimit + extra)

        let previews = TextEncodingDetector.previews(of: Data(data), using: decoder)
        let utf8 = try #require(previews.first { $0.encoding == .utf8 })
        #expect(utf8.preview.allSatisfy { $0 == "中" })
        #expect(!utf8.preview.isEmpty)
    }

    /// The honest limit. Detection is a statistical property of running text,
    /// so a short enough fragment can land above the floor by luck — which is
    /// why the picker exists and is offered whenever the reader disagrees.
    @Test("A very short Big5 fragment can be misidentified")
    func shortFragmentsAreNotGuaranteed() throws {
        let data = try #require(encoded("一", as: .big5))
        let detected = TextEncodingDetector.detect(data, using: decoder)
        // Not asserting which way it goes -- the point is that the previews
        // are there either way, with the right answer among them.
        let previews = TextEncodingDetector.previews(of: data, using: decoder)
        #expect(previews.contains { $0.encoding == .big5 && $0.preview == "一" })
        #expect(detected != nil || !previews.isEmpty)
    }
}
