// HanReader — MIT licensed. See LICENSE.

public import Foundation

/// An encoding a source text might be written in.
///
/// Short list on purpose: these are the encodings Chinese plain text is
/// actually distributed in. `String(contentsOf:encoding: .utf8)` — what the
/// prototype used, and the obvious thing to write — throws on most of them,
/// which makes a failed import the expected outcome for a file downloaded
/// from a Chinese site rather than an unusual one.
public enum SourceTextEncoding: String, CaseIterable, Sendable, Hashable, Codable {
    case utf8
    case utf16LittleEndian
    case utf16BigEndian
    /// The mandatory standard on the mainland, and a superset of GBK and
    /// GB2312 — so a GBK file decodes correctly as this and there is no
    /// reason to offer those separately.
    case gb18030
    /// Traditional Chinese, as used in Taiwan and Hong Kong.
    case big5

    /// A name to show in an encoding picker.
    public var displayName: String {
        switch self {
        case .utf8: "UTF-8"
        case .utf16LittleEndian: "UTF-16 (little-endian)"
        case .utf16BigEndian: "UTF-16 (big-endian)"
        case .gb18030: "GB18030 (Simplified)"
        case .big5: "Big5 (Traditional)"
        }
    }
}

/// Turns bytes into text in a named encoding.
///
/// Injected rather than called directly, for a reason that is structural and
/// not stylistic: GB18030 and Big5 are reachable only through CoreFoundation's
/// encoding tables, which exist on Apple platforms and not on Linux.
/// `HanReaderCore` must compile on Linux — a CI job builds it there precisely
/// to keep that true — so the *policy* lives here and the conversion lives in
/// `HanReaderPlatform`.
///
/// It also means the detection rules below can be tested against a stub, with
/// no dependency on what any particular platform's decoder happens to accept.
public protocol TextDecoding: Sendable {
    /// Decodes `data`, or returns nil if it is not valid in that encoding.
    ///
    /// Must be **strict**: returning mojibake where it should return nil
    /// defeats detection entirely, because an encoding that never fails is
    /// indistinguishable from the right one.
    func decode(_ data: Data, as encoding: SourceTextEncoding) -> String?
}

/// Text, and what it turned out to be written in.
public struct DetectedText: Sendable, Hashable {
    public let text: String
    public let encoding: SourceTextEncoding
    /// How much of the decoded text looks like text, 0...1.
    ///
    /// See `TextPlausibility`. This is a property of the *result*, not a
    /// probability that the encoding is right — nothing here can tell a
    /// GB18030 file decoded as Big5 from one decoded correctly, because both
    /// produce perfectly ordinary Han characters.
    public let plausibility: Double
    /// Whether the encoding was declared by a byte-order mark rather than
    /// guessed. A mark is not a guess, and the UI should not offer to
    /// second-guess one.
    public let fromByteOrderMark: Bool

    public init(
        text: String,
        encoding: SourceTextEncoding,
        plausibility: Double,
        fromByteOrderMark: Bool,
    ) {
        self.text = text
        self.encoding = encoding
        self.plausibility = plausibility
        self.fromByteOrderMark = fromByteOrderMark
    }
}

/// One option to show the reader when detection cannot decide.
public struct EncodingPreview: Sendable, Hashable, Identifiable {
    public let encoding: SourceTextEncoding
    /// The first few hundred characters, so the reader can see at a glance
    /// which option is not mojibake. This is the only reliable way to resolve
    /// the Simplified-versus-Traditional ambiguity, and it takes a person
    /// about a second.
    public let preview: String
    public let plausibility: Double

    public var id: SourceTextEncoding {
        encoding
    }

    public init(encoding: SourceTextEncoding, preview: String, plausibility: Double) {
        self.encoding = encoding
        self.preview = preview
        self.plausibility = plausibility
    }
}

/// Works out what encoding a file is in.
///
/// ### What this can and cannot do
///
/// - **A byte-order mark is conclusive**, and is checked first.
/// - **UTF-8 without a mark is nearly conclusive.** UTF-8 is strictly
///   validated, and a GB18030 or Big5 file almost never forms a valid UTF-8
///   sequence by accident, so a successful strict decode is strong evidence.
/// - **Binary mistaken for text is caught**, because a PDF decoded as GB18030
///   is mostly control characters and scores far below the floor.
/// - **GB18030 and Big5 are usually told apart**, which was not expected and
///   is worth explaining, because the obvious analysis says they cannot be.
///
/// Both are full-coverage double-byte encodings, so GB18030 accepts a Big5
/// file's bytes rather than rejecting them — the reason ordering alone cannot
/// settle it. But it does not map them to ordinary Han characters. A large
/// share land in the **private use area**, which `TextPlausibility` counts
/// against the result, and the score collapses well below the floor. Measured
/// over twenty samples of Traditional and Simplified prose, every one was
/// identified correctly; the Big5 files scored 0.38 to 0.81 when decoded as
/// GB18030, against a floor of 0.9.
///
/// That margin is real but not large, and it is a statistical property of
/// running text. A short enough fragment can land above the floor by luck, so
/// the detection is a strong default rather than a guarantee — which is why
/// `previews(of:using:)` exists and why the UI offers it whenever the reader
/// disagrees with the result.
///
/// The ordering is still Simplified before Traditional, because that is the
/// larger share of what gets imported.
public enum TextEncodingDetector {
    /// Encodings tried, in order, when there is no byte-order mark.
    ///
    /// UTF-16 is deliberately **not** here, which looks like an omission
    /// because the decoder supports it. It was added during review and taken
    /// out again after measuring, and the measurements are the argument:
    ///
    /// - UTF-16 reinterprets any even-length run of bytes as characters, and
    ///   byte-swapped text decodes into perfectly ordinary CJK. So putting
    ///   little-endian in the list means every unmarked **big**-endian file is
    ///   claimed by it and imported as silent mojibake — replacing a case
    ///   that asks the reader with a case that is quietly wrong.
    /// - Putting big-endian first merely swaps which one breaks. Nothing in
    ///   the content distinguishes them without bespoke heuristics about
    ///   where the NUL bytes fall.
    /// - The case it would fix is small to begin with. A UTF-16 file
    ///   essentially always carries a mark — the format all but requires one
    ///   — and `byteOrderMark(in:)` handles those conclusively, before any of
    ///   this. And for CJK-heavy content GB18030 often produces plausible
    ///   mojibake and claims the file anyway, so the fix would not even be
    ///   reliable for the case it targets.
    ///
    /// Trading a rare file that asks a question for a rarer file that is
    /// silently wrong is a bad trade, so an unmarked UTF-16 file goes to the
    /// picker — which offers it, decoded correctly, as one of the choices.
    public static let detectionOrder: [SourceTextEncoding] = [.utf8, .gb18030, .big5]

    /// How many bytes a preview decodes.
    ///
    /// Generous for 400 characters in any encoding here — Chinese costs at
    /// most three bytes a character — and small enough that offering five
    /// candidates for a ten-megabyte novel does not mean decoding it five
    /// times to show a paragraph of each.
    public static let previewByteLimit = 8192

    /// How text-like a decode must look to be accepted without asking.
    ///
    /// Below this the result goes to the reader as a choice rather than being
    /// silently accepted. Set where a decode containing a handful of stray
    /// control characters still passes but a mostly-binary one does not.
    public static let plausibilityFloor = 0.9

    /// Detects and decodes, or returns nil if nothing was convincing.
    ///
    /// Nil means "ask the reader", not "this file is broken".
    public static func detect(_ data: Data, using decoder: some TextDecoding) -> DetectedText? {
        // Empty is not an error and has no encoding to detect. Deciding it is
        // UTF-8 costs nothing and saves every caller a special case.
        guard !data.isEmpty else {
            return DetectedText(
                text: "",
                encoding: .utf8,
                plausibility: 1,
                fromByteOrderMark: false,
            )
        }

        if let marked = byteOrderMark(in: data) {
            // A mark is a declaration, so it is honoured even if what follows
            // scores badly: a file that says it is UTF-16 and then is not is
            // a broken file, and silently reinterpreting it as something else
            // would turn a clear failure into a confusing success.
            guard let text = decoder.decode(data, as: marked) else { return nil }
            return DetectedText(
                text: text,
                encoding: marked,
                plausibility: TextPlausibility.score(text),
                fromByteOrderMark: true,
            )
        }

        for encoding in detectionOrder {
            guard let text = decoder.decode(data, as: encoding) else { continue }
            let score = TextPlausibility.score(text)
            guard score >= plausibilityFloor else { continue }
            return DetectedText(
                text: text,
                encoding: encoding,
                plausibility: score,
                fromByteOrderMark: false,
            )
        }
        return nil
    }

    /// Every candidate that decodes at all, for an encoding picker.
    ///
    /// Ordered by `detectionOrder` rather than by score, so the list does not
    /// reshuffle itself between two files — and because the scores of two
    /// plausible CJK decodes are close enough that ordering by them would be
    /// noise presented as a recommendation.
    ///
    /// Only the first `previewByteLimit` bytes are decoded. The reader is
    /// being shown a paragraph, so decoding a whole novel five times over to
    /// produce it would be work with no visible result. Two consequences
    /// worth knowing: `plausibility` here describes the sample rather than
    /// the file, and an encoding that would fail somewhere in the body can
    /// still appear in the list. Neither matters for choosing — the choice is
    /// made by looking — and the import that follows decodes the whole file
    /// and fails properly if it cannot.
    public static func previews(
        of data: Data,
        using decoder: some TextDecoding,
        limit: Int = 400,
    )
        -> [EncodingPreview]
    {
        var seen: Set<SourceTextEncoding> = []
        var ordered = detectionOrder
        for encoding in SourceTextEncoding.allCases where !ordered.contains(encoding) {
            ordered.append(encoding)
        }

        return ordered.compactMap { encoding in
            guard seen.insert(encoding).inserted,
                  let text = decodeSample(data, as: encoding, using: decoder)
            else { return nil }
            return EncodingPreview(
                encoding: encoding,
                preview: String(text.prefix(limit)),
                plausibility: TextPlausibility.score(text),
            )
        }
    }

    /// Decodes the first `previewByteLimit` bytes.
    ///
    /// A fixed byte count almost always cuts through the middle of
    /// something — a multi-byte UTF-8 sequence, or one half of a UTF-16 code
    /// unit — and a strict decoder rightly refuses the result. So up to three
    /// trailing bytes are dropped until it decodes, three being one less than
    /// the longest UTF-8 sequence and enough to realign UTF-16 either way.
    /// Failing all four attempts means the sample is genuinely not that
    /// encoding.
    ///
    /// The trimming applies to a short file too, not only to a sampled one.
    /// A file truncated mid-character is invalid and `detect` is right to
    /// refuse it — but a reader staring at a half-finished download is
    /// exactly who needs to see what it says, so the picker stays lenient
    /// where the detector is strict.
    private static func decodeSample(
        _ data: Data,
        as encoding: SourceTextEncoding,
        using decoder: some TextDecoding,
    )
        -> String?
    {
        let length = Swift.min(data.count, previewByteLimit)
        for trimmed in 0 ... 3 where length - trimmed > 0 {
            if let text = decoder.decode(data.prefix(length - trimmed), as: encoding) {
                return text
            }
        }
        return nil
    }

    /// The encoding declared by a byte-order mark, if there is one.
    ///
    /// UTF-32 is checked before UTF-16 even though it is not a candidate:
    /// a UTF-32LE mark *begins* with a UTF-16LE mark, so testing UTF-16 first
    /// would confidently mis-identify every UTF-32LE file. Returning nil
    /// sends it to the picker instead of to a wrong answer.
    static func byteOrderMark(in data: Data) -> SourceTextEncoding? {
        let bytes = [UInt8](data.prefix(4))
        if bytes.starts(with: [0xFF, 0xFE, 0x00, 0x00]) {
            return nil
        }
        if bytes.starts(with: [0x00, 0x00, 0xFE, 0xFF]) {
            return nil
        }
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) {
            return .utf8
        }
        if bytes.starts(with: [0xFF, 0xFE]) {
            return .utf16LittleEndian
        }
        if bytes.starts(with: [0xFE, 0xFF]) {
            return .utf16BigEndian
        }
        return nil
    }
}

/// How much of a string looks like text a person wrote.
///
/// Used to reject a decode that technically succeeded. It answers one
/// question — "is this text at all?" — and deliberately does not try to answer
/// "is this the *right* text", which for two CJK encodings it cannot.
public enum TextPlausibility {
    /// The share of scalars that belong in a document, 0...1.
    ///
    /// A replacement character counts several times against the total,
    /// because a decoder that substituted even one has already told us it
    /// could not read the file — and the strict decoders used here should
    /// have returned nil rather than substituting at all.
    public static let replacementPenalty = 8

    public static func score(_ text: String) -> Double {
        var good = 0
        var bad = 0

        for scalar in text.unicodeScalars {
            if scalar == "\u{FFFD}" {
                bad += replacementPenalty
                continue
            }
            if isPlausible(scalar) {
                good += 1
            } else {
                bad += 1
            }
        }

        let total = good + bad
        guard total > 0 else { return 1 }
        return Double(good) / Double(total)
    }

    /// Whether a scalar belongs in a document.
    ///
    /// Everything assigned counts except the categories that mean something
    /// went wrong: unassigned code points, private use, surrogates, and
    /// control characters other than tab, newline and carriage return.
    ///
    /// Two of those carry most of the weight, for different reasons:
    ///
    /// - **Control characters** catch a PDF or a ZIP opened as text, which is
    ///   a real thing readers do and which every other check here passes.
    /// - **Private use** is what separates GB18030 from Big5. Decoding a Big5
    ///   file as GB18030 succeeds, because GB18030 accepts almost any byte
    ///   sequence — but a large share of the result lands in the private use
    ///   area rather than on real characters, and counting that against the
    ///   score is what makes the wrong answer detectably wrong.
    public static func isPlausible(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .unassigned, .privateUse, .surrogate:
            false
        case .control:
            scalar == "\t" || scalar == "\n" || scalar == "\r"
        default:
            true
        }
    }
}
