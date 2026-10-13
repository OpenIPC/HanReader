// HanReader — MIT licensed. See LICENSE.

public import Foundation

/// How a container's sense payloads are encoded.
///
/// A seam rather than a single implementation, because the choice is a
/// measured trade and will be made again. A container records which codec
/// wrote it, so adding one does not invalidate the dictionaries already on
/// disk — and so a future block-compressing codec is a drop-in rather than a
/// migration.
public protocol SensePayloadCodec: Sendable {
    /// Written into the container's `meta` table, so a reader can pick the
    /// codec the writer used rather than assuming the current one.
    static var identifier: String { get }

    func encode(_ senses: [Sense]) throws -> Data
    func decode(_ data: Data) throws -> [Sense]
}

/// Something that cannot be read as a sense payload.
public enum SensePayloadError: Error, Hashable, Sendable, CustomStringConvertible {
    case truncated(offset: Int)
    case unknownVersion(UInt8)
    case unknownCodec(String)

    public var description: String {
        switch self {
        case let .truncated(offset):
            "the payload ends part way through a field, at byte \(offset)"
        case let .unknownVersion(version):
            "payload format version \(version) is newer than this build understands"
        case let .unknownCodec(identifier):
            "this container's senses were written by the '\(identifier)' codec, "
                + "which this build does not have"
        }
    }
}

// MARK: - JSON, as the first milestones wrote it

/// JSON, kept so a container compiled before the compact codec still opens.
///
/// It is not what new containers use. Measured over the BKRS set, only
/// **40.7%** of a JSON payload is text; the rest is syntax and key names,
/// written out once per sense across 3,691,468 of them.
public struct JSONSenseCodec: SensePayloadCodec {
    public static let identifier = "json"

    public init() {}

    public func encode(_ senses: [Sense]) throws -> Data {
        try JSONEncoder().encode(senses)
    }

    public func decode(_ data: Data) throws -> [Sense] {
        try JSONDecoder().decode([Sense].self, from: data)
    }
}

// MARK: - The packed encoding

/// A packed binary encoding of a sense run.
///
/// ### Why
///
/// Measured over the 3,442,623-entry BKRS container: the `entry` table was
/// 625 MB, its sense payloads 327 MB of that, and **only 40.7% of a payload
/// was text**. The rest was `{"gloss":{"text":…},"level":0,"kind":…}` written
/// out once per sense. Payload size is also most of the import's wall-clock,
/// since every byte is one SQLite has to write.
///
/// ### How
///
/// Three ideas, each worth its complexity:
///
/// - **A presence byte.** The overwhelmingly common sense is a gloss, a level
///   and nothing else — 3,318,399 of 3,434,224 cards carry a single sense — so
///   every field it lacks costs one bit instead of a key and a literal.
/// - **Varints.** Levels are 0–3, parents and offsets are small, counts are
///   usually one. A varint spends a byte on each where JSON spends a decimal
///   rendering plus punctuation.
/// - **An example is stored once.** `UsageExample` keeps `chinese`,
///   `translation` *and* `raw`, where `raw` is the example as written and the
///   other two are a heuristic split of it; measured, the halves cost as much
///   again as `raw` itself. Here `raw` is stored with the two boundaries
///   inside it, reproducing both halves exactly — including a split that
///   trimmed whitespace — from one copy of the text.
///
/// `Sense.id` is not stored at all: it is the index in the run.
///
/// ### Compatibility
///
/// The leading version byte is checked, and a payload claiming a newer version
/// is refused rather than misread. Adding a field means a new presence bit and
/// a version bump; `meta` says which codec wrote a container, so an older one
/// stays readable.
public struct CompactSenseCodec: SensePayloadCodec {
    public static let identifier = "compact-v1"

    /// Bumped when the layout changes. A payload is refused rather than
    /// guessed at, because a misread sense is worse than an error.
    static let version: UInt8 = 1

    enum Field: UInt8 {
        case parent = 0x01
        case label = 0x02
        case styles = 0x04
        case references = 0x08
        case partOfSpeech = 0x10
        case registers = 0x20
        case examples = 0x40
        /// Set when the kind is not `.definition`, which almost every sense is.
        case kind = 0x80
    }

    public init() {}

    public func encode(_ senses: [Sense]) throws -> Data {
        var bytes: [UInt8] = [Self.version]
        // A rough guess at the common case, to avoid a handful of growths per
        // entry across three and a half million of them.
        bytes.reserveCapacity(64 * senses.count + 8)
        Self.appendVarint(senses.count, to: &bytes)
        for sense in senses {
            Self.append(sense, to: &bytes)
        }
        return Data(bytes)
    }

    public func decode(_ data: Data) throws -> [Sense] {
        var reader = Reader(data)
        let version = try reader.byte()
        guard version == Self.version else { throw SensePayloadError.unknownVersion(version) }

        let count = try reader.varint()
        var senses: [Sense] = []
        senses.reserveCapacity(count)
        for index in 0 ..< count {
            try senses.append(Self.decodeSense(at: index, from: &reader))
        }
        return senses
    }
}

// MARK: - Writing

extension CompactSenseCodec {
    static func append(_ sense: Sense, to bytes: inout [UInt8]) {
        bytes.append(presence(of: sense))

        if sense.kind != .definition {
            bytes.append(sense.kind.rawValue)
        }
        appendVarint(sense.level, to: &bytes)
        if let parent = sense.parent {
            appendVarint(parent, to: &bytes)
        }
        if let label = sense.label {
            appendText(label, to: &bytes)
        }
        appendText(sense.gloss.text, to: &bytes)

        if !sense.gloss.styles.isEmpty {
            append(styles: sense.gloss.styles, to: &bytes)
        }
        if !sense.gloss.references.isEmpty {
            append(references: sense.gloss.references, to: &bytes)
        }
        if !sense.partOfSpeech.isEmpty {
            appendTexts(sense.partOfSpeech, to: &bytes)
        }
        if !sense.registers.isEmpty {
            appendTexts(sense.registers, to: &bytes)
        }
        if !sense.examples.isEmpty {
            appendVarint(sense.examples.count, to: &bytes)
            for example in sense.examples {
                appendExample(example, to: &bytes)
            }
        }
    }

    private static func append(styles: [StyleRun], to bytes: inout [UInt8]) {
        appendVarint(styles.count, to: &bytes)
        for run in styles {
            bytes.append(run.style.encoded)
            appendVarint(run.range.lowerBound, to: &bytes)
            appendVarint(run.range.count, to: &bytes)
        }
    }

    private static func append(references: [CrossReference], to bytes: inout [UInt8]) {
        appendVarint(references.count, to: &bytes)
        for reference in references {
            appendText(reference.simplified, to: &bytes)
            appendOptionalText(reference.traditional, to: &bytes)
            appendOptionalText(reference.reading, to: &bytes)
            appendVarint(reference.range.lowerBound, to: &bytes)
            appendVarint(reference.range.count, to: &bytes)
        }
    }

    /// One bit per optional field.
    static func presence(of sense: Sense) -> UInt8 {
        var flags: UInt8 = 0
        if sense.parent != nil {
            flags |= Field.parent.rawValue
        }
        if sense.label != nil {
            flags |= Field.label.rawValue
        }
        if !sense.gloss.styles.isEmpty {
            flags |= Field.styles.rawValue
        }
        if !sense.gloss.references.isEmpty {
            flags |= Field.references.rawValue
        }
        if !sense.partOfSpeech.isEmpty {
            flags |= Field.partOfSpeech.rawValue
        }
        if !sense.registers.isEmpty {
            flags |= Field.registers.rawValue
        }
        if !sense.examples.isEmpty {
            flags |= Field.examples.rawValue
        }
        if sense.kind != .definition {
            flags |= Field.kind.rawValue
        }
        return flags
    }

    /// Writes an example as its raw text plus where the two halves sit in it.
    ///
    /// The split is a heuristic over where the Han characters stop, and the
    /// translation side is trimmed, so neither half is a plain suffix of the
    /// raw text. Two offsets reproduce both exactly from one copy.
    ///
    /// When a half is not a slice of the raw text at all — which a different
    /// splitter could produce — it is written out in full and marked, so this
    /// stays an optimisation rather than an invariant the model must keep.
    static func appendExample(_ example: UsageExample, to bytes: inout [UInt8]) {
        let raw = Array(example.raw.utf8)
        let chinese = Array(example.chinese.utf8)
        let translation = Array(example.translation.utf8)

        // One-based, so zero can mean "this half is empty" — which is how an
        // example with no Chinese at all is told from one whose Chinese starts
        // at offset zero, the ordinary case.
        let chineseStart = chinese.isEmpty
            ? 0
            : (raw.firstRange(of: chinese)?.lowerBound).map { $0 + 1 }
        let translationStart = translation.isEmpty
            ? 0
            : (raw.lastRange(of: translation)?.lowerBound).map { $0 + 1 }

        guard let chineseStart, let translationStart else {
            bytes.append(1)
            appendText(example.raw, to: &bytes)
            appendText(example.chinese, to: &bytes)
            appendText(example.translation, to: &bytes)
            return
        }
        bytes.append(0)
        appendText(example.raw, to: &bytes)
        appendVarint(chineseStart, to: &bytes)
        appendVarint(chinese.count, to: &bytes)
        appendVarint(translationStart, to: &bytes)
        appendVarint(translation.count, to: &bytes)
    }

    /// LEB128, unsigned. Every integer in this format is small and
    /// non-negative — levels, parents, offsets, counts — so a fixed width
    /// would spend seven bytes saying nothing.
    static func appendVarint(_ value: Int, to bytes: inout [UInt8]) {
        var remaining = UInt(bitPattern: value)
        while true {
            let byte = UInt8(remaining & 0x7F)
            remaining >>= 7
            if remaining == 0 {
                bytes.append(byte)
                return
            }
            bytes.append(byte | 0x80)
        }
    }

    static func appendText(_ text: String, to bytes: inout [UInt8]) {
        let utf8 = text.utf8
        appendVarint(utf8.count, to: &bytes)
        bytes.append(contentsOf: utf8)
    }

    /// A length of zero means the empty string; nil is one less than that, so
    /// an absent traditional spelling costs one byte and an empty one is still
    /// distinguishable from it.
    static func appendOptionalText(_ text: String?, to bytes: inout [UInt8]) {
        guard let text else {
            appendVarint(0, to: &bytes)
            return
        }
        let utf8 = text.utf8
        appendVarint(utf8.count + 1, to: &bytes)
        bytes.append(contentsOf: utf8)
    }

    static func appendTexts(_ texts: [String], to bytes: inout [UInt8]) {
        appendVarint(texts.count, to: &bytes)
        for text in texts {
            appendText(text, to: &bytes)
        }
    }
}

// MARK: - Reading

extension CompactSenseCodec {
    static func decodeSense(at index: Int, from reader: inout Reader) throws -> Sense {
        let flags = try reader.byte()
        let kind = try flags & Field.kind.rawValue != 0
            ? SenseKind(rawValue: reader.byte()) ?? .definition
            : .definition
        let level = try reader.varint()
        let parent = flags & Field.parent.rawValue != 0 ? try reader.varint() : nil
        let label = flags & Field.label.rawValue != 0 ? try reader.text() : nil
        let text = try reader.text()
        let styles = flags & Field.styles.rawValue != 0 ? try decodeStyles(from: &reader) : []
        let references = flags & Field.references.rawValue != 0
            ? try decodeReferences(from: &reader)
            : []
        let partOfSpeech = flags & Field.partOfSpeech.rawValue != 0 ? try reader.texts() : []
        let registers = flags & Field.registers.rawValue != 0 ? try reader.texts() : []
        var examples: [UsageExample] = []
        if flags & Field.examples.rawValue != 0 {
            for _ in try 0 ..< (reader.varint()) {
                try examples.append(decodeExample(from: &reader))
            }
        }

        return Sense(
            id: index,
            kind: kind,
            gloss: Gloss(text: text, references: references, styles: styles),
            level: level,
            parent: parent,
            label: label,
            partOfSpeech: partOfSpeech,
            registers: registers,
            examples: examples,
        )
    }

    private static func decodeStyles(from reader: inout Reader) throws -> [StyleRun] {
        var styles: [StyleRun] = []
        for _ in try 0 ..< (reader.varint()) {
            let style = try TextStyle(encoded: reader.byte())
            let start = try reader.varint()
            let length = try reader.varint()
            styles.append(StyleRun(style: style, range: start ..< (start + length)))
        }
        return styles
    }

    private static func decodeReferences(from reader: inout Reader) throws -> [CrossReference] {
        var references: [CrossReference] = []
        for _ in try 0 ..< (reader.varint()) {
            let simplified = try reader.text()
            let traditional = try reader.optionalText()
            let reading = try reader.optionalText()
            let start = try reader.varint()
            let length = try reader.varint()
            references.append(CrossReference(
                simplified: simplified,
                traditional: traditional,
                reading: reading,
                range: start ..< (start + length),
            ))
        }
        return references
    }

    private static func decodeExample(from reader: inout Reader) throws -> UsageExample {
        let form = try reader.byte()
        let raw = try reader.text()
        guard form == 0 else {
            return try UsageExample(
                chinese: reader.text(),
                translation: reader.text(),
                raw: raw,
            )
        }
        let chineseStart = try reader.varint()
        let chineseLength = try reader.varint()
        let translationStart = try reader.varint()
        let translationLength = try reader.varint()
        let bytes = Array(raw.utf8)
        return UsageExample(
            chinese: slice(bytes, start: chineseStart, length: chineseLength),
            translation: slice(bytes, start: translationStart, length: translationLength),
            raw: raw,
        )
    }

    // A payload is derived data in a file on disk. Where it is damaged, a
    // replacement character costs the characters it replaces and leaves the
    // entry readable, which beats an error costing the whole entry — and
    // structural damage is already an error, from the bounds checks below.
    // The same bargain the byte reader makes with a malformed source.
    // swiftlint:disable optional_data_string_conversion

    /// A half of an example, by its one-based start. Zero means empty, which
    /// is how "no Chinese at all" is told from "the Chinese starts at zero".
    private static func slice(_ bytes: [UInt8], start: Int, length: Int) -> String {
        guard start > 0, length > 0 else { return "" }
        let from = start - 1
        guard from + length <= bytes.count else { return "" }
        return String(decoding: bytes[from ..< (from + length)], as: UTF8.self)
    }

    /// A cursor over the payload that refuses to read past the end.
    ///
    /// Every read is bounds-checked and throws rather than trapping: a payload
    /// is data from a file on disk, and a corrupt one should cost that entry,
    /// not the process.
    struct Reader {
        private let bytes: [UInt8]
        private var offset = 0

        init(_ data: Data) {
            bytes = [UInt8](data)
        }

        mutating func byte() throws -> UInt8 {
            guard offset < bytes.count else { throw SensePayloadError.truncated(offset: offset) }
            defer { offset += 1 }
            return bytes[offset]
        }

        mutating func varint() throws -> Int {
            var result = 0
            var shift = 0
            while true {
                let byte = try byte()
                result |= Int(byte & 0x7F) << shift
                if byte & 0x80 == 0 {
                    return result
                }
                shift += 7
                guard shift < 64 else { throw SensePayloadError.truncated(offset: offset) }
            }
        }

        mutating func text() throws -> String {
            try take(count: varint())
        }

        mutating func optionalText() throws -> String? {
            let length = try varint()
            guard length > 0 else { return nil }
            return try take(count: length - 1)
        }

        mutating func texts() throws -> [String] {
            let count = try varint()
            var result: [String] = []
            result.reserveCapacity(count)
            for _ in 0 ..< count {
                try result.append(text())
            }
            return result
        }

        private mutating func take(count: Int) throws -> String {
            guard count >= 0, offset + count <= bytes.count else {
                throw SensePayloadError.truncated(offset: offset)
            }
            defer { offset += count }
            return String(decoding: bytes[offset ..< (offset + count)], as: UTF8.self)
        }
    }

    // swiftlint:enable optional_data_string_conversion
}

// MARK: - Enumerations on the wire

extension TextStyle {
    /// A fixed byte per case, chosen here rather than taken from the case
    /// order: reordering the enum must not change what is already on disk.
    var encoded: UInt8 {
        switch self {
        case .bold: 1
        case .italic: 2
        case .highlighted: 3
        }
    }

    init(encoded: UInt8) {
        switch encoded {
        case 1: self = .bold
        case 3: self = .highlighted
        default: self = .italic
        }
    }
}

// MARK: - Choosing a codec

/// Which codec reads or writes a container.
public enum SensePayloadCodecs {
    /// What a writer should use now.
    public static let current: any SensePayloadCodec = CompactSenseCodec()

    /// Resolves a recorded identifier.
    ///
    /// An unrecognised one is an error rather than a fallback to the current
    /// codec: misreading a payload produces plausible nonsense, and a
    /// container written by a newer build should say so plainly.
    public static func named(_ identifier: String?) throws -> any SensePayloadCodec {
        switch identifier {
        // A container from before the codec was recorded is JSON, because that
        // is what the only writer there was then used.
        case nil, JSONSenseCodec.identifier: JSONSenseCodec()
        case CompactSenseCodec.identifier: CompactSenseCodec()
        case let other: throw SensePayloadError.unknownCodec(other ?? "")
        }
    }
}
