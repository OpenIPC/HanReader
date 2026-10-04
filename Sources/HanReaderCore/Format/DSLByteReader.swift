// HanReader — MIT licensed. See LICENSE.

public import Foundation

/// How a DSL file's bytes spell its characters.
///
/// ABBYY's own tools write UTF-16 with a byte-order mark, and all three files
/// of the BKRS set are UTF-16LE+BOM. Dictionaries assembled by hand are
/// routinely UTF-8, so both are first-class rather than one being a fallback.
public enum DSLByteEncoding: Hashable, Sendable {
    case utf16LittleEndian
    case utf16BigEndian
    case utf8

    /// Bytes per code unit. Line scanning, offset validation and
    /// carriage-return stripping all turn on this.
    var codeUnitWidth: Int {
        self == .utf8 ? 1 : 2
    }
}

/// One line of a DSL file, with where it started.
public struct DSLLine: Hashable, Sendable {
    /// The line's text, with the line terminator and any carriage return
    /// removed.
    public let text: String
    /// Byte offset of the line's first byte from the start of the file.
    ///
    /// A byte offset, not a line number, because this is what a resumed
    /// import seeks to. It is also stable under a parser change in a way a
    /// line count is not.
    public let offset: Int

    public init(text: String, offset: Int) {
        self.text = text
        self.offset = offset
    }
}

/// Something that cannot be read as a DSL file at all.
///
/// All three cases are about the file's shape rather than its content. A line
/// the parser dislikes is a diagnostic; a file whose bytes cannot form whole
/// characters is an error, because every offset derived from it would be a
/// guess.
public enum DSLByteError: Error, Hashable, Sendable, CustomStringConvertible {
    /// A UTF-16 file whose length is not a whole number of code units, so its
    /// last character is cut in half.
    case oddByteLength(byteCount: Int)
    /// A resume offset that does not sit on a code-unit boundary.
    case misalignedOffset(Int)
    /// A resume offset past the end of the file, which is what a stale
    /// checkpoint against a replaced file looks like.
    case offsetOutOfRange(offset: Int, byteCount: Int)
    /// The file could not be opened or measured.
    case cannotOpen(path: String, code: Int32)
    /// A read failed part-way through the file.
    case readFailed(offset: Int, code: Int32)

    public var description: String {
        switch self {
        case let .oddByteLength(byteCount):
            "the file is \(byteCount) bytes long, which is not a whole number of "
                + "UTF-16 code units — it is truncated or not UTF-16"
        case let .misalignedOffset(offset):
            "byte offset \(offset) is odd, so it falls inside a UTF-16 code unit"
        case let .offsetOutOfRange(offset, byteCount):
            "byte offset \(offset) is past the end of a \(byteCount)-byte file"
        case let .cannotOpen(path, code):
            "cannot open \(path): \(String(cString: strerror(code)))"
        case let .readFailed(offset, code):
            "read at byte \(offset) failed: \(String(cString: strerror(code)))"
        }
    }
}

// MARK: - Byte sources

/// Random-access bytes for `DSLByteReader`.
///
/// Random access rather than a stream, because resuming an interrupted import
/// means starting at a recorded byte offset, and because it keeps the source
/// free of a read position that would have to be kept in step with the
/// reader's own.
public protocol DSLByteSource {
    /// Total length of the file. Needed before reading in order to reject an
    /// odd-length UTF-16 file rather than discovering it 300 MB in.
    var byteCount: Int { get }

    /// Reads from `offset` into `buffer` starting at index `destination`,
    /// filling at most to the end of `buffer`.
    ///
    /// Returns the number of bytes written, or 0 at end of file. A short read
    /// is allowed: the reader loops until the buffer is full, so a source need
    /// not return everything asked for.
    func read(at offset: Int, into buffer: inout [UInt8], from destination: Int) throws -> Int
}

/// Bytes already in memory, for fixtures and tests.
public struct DSLMemoryBytes: DSLByteSource, Sendable {
    private let bytes: [UInt8]

    public init(_ bytes: [UInt8]) {
        self.bytes = bytes
    }

    public init(_ data: Data) {
        bytes = [UInt8](data)
    }

    public var byteCount: Int {
        bytes.count
    }

    public func read(
        at offset: Int,
        into buffer: inout [UInt8],
        from destination: Int,
    ) throws
        -> Int
    {
        guard offset >= 0, offset < bytes.count, destination < buffer.count else { return 0 }
        let count = min(buffer.count - destination, bytes.count - offset)
        buffer.replaceSubrange(
            destination ..< (destination + count),
            with: bytes[offset ..< (offset + count)],
        )
        return count
    }
}

/// Bytes read from a file a chunk at a time.
///
/// `pread` rather than `FileHandle`, for a measured reason. The import has a
/// 60 MB ceiling over baseline, and reading 116 MB through
/// `FileHandle.read(upToCount:)` took peak resident size to 124 MB — the size
/// of the file — because Foundation maps a large read instead of copying it,
/// so resident size follows the input. The same read through `pread` into a
/// reusable buffer costs 1 MiB regardless of file size, which is the whole
/// point of reading in chunks.
///
/// `pread` also takes the offset as an argument rather than as file state, so
/// there is no seek position to keep in step with the reader's own.
public final class DSLFileBytes: DSLByteSource {
    private let descriptor: Int32
    public let byteCount: Int

    public init(url: URL) throws {
        descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else {
            throw DSLByteError.cannotOpen(path: url.path, code: errno)
        }
        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            let code = errno
            close(descriptor)
            throw DSLByteError.cannotOpen(path: url.path, code: code)
        }
        byteCount = Int(status.st_size)
    }

    deinit {
        close(descriptor)
    }

    public func read(
        at offset: Int,
        into buffer: inout [UInt8],
        from destination: Int,
    ) throws
        -> Int
    {
        guard offset >= 0, offset < byteCount, destination < buffer.count else { return 0 }
        let wanted = buffer.count - destination
        return try buffer.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return 0 }
            let count = pread(descriptor, base.advanced(by: destination), wanted, off_t(offset))
            guard count >= 0 else { throw DSLByteError.readFailed(offset: offset, code: errno) }
            return count
        }
    }
}

// MARK: - The reader

/// Reads a DSL file as lines, each with its byte offset.
///
/// ### The line terminator is a code unit, not a byte pair
///
/// In UTF-16LE a line feed is the code unit `0x000A`, which is the bytes
/// `0A 00` **at an even offset**. Scanning the raw bytes for that pair
/// without checking alignment is a latent corruption: a character in
/// `U+0A00`–`U+0AFF` puts `0A` at an odd offset, and if the next character's
/// low byte is zero the pair appears across the two of them. `ਅ昀` —
/// `U+0A05` then `U+6600` — is `05 0A 00 66`, and a byte scanner breaks the
/// line between the two bytes of a single character.
///
/// The predecessor prototype scanned for `0A 00` with no alignment check. It
/// got away with it: across all three BKRS files there are 10,302,687 aligned
/// line feeds and **zero** misaligned occurrences of the pair, because a
/// Chinese-Russian dictionary contains no Gurmukhi. So this is not a bug fix
/// for an observed failure — it is the difference between code that is
/// correct and code that happens to work on one input, and the aligned scan
/// costs nothing.
///
/// ### Line endings are mixed within a single file
///
/// Each BKRS file has exactly two CRLF lines — `#NAME` and `#INDEX_LANGUAGE`
/// — and three million LF ones. A reader that splits on CRLF leaves a stray
/// carriage return on the dictionary's own name; one that splits on LF and
/// forgets to strip CR does the same. Both terminators are handled on every
/// line.
///
/// ### A trailing newline does not make a final empty line
///
/// All three files end with a line feed, so splitting the text yields an
/// empty final element. That empty string is not a line — and at the card
/// level an unindented empty line looks exactly like a headword, which is a
/// headword this dictionary does not contain.
public struct DSLByteReader {
    /// 1 MiB. Large enough that a 350 MB file costs ~350 reads, small enough
    /// to be irrelevant against the memory ceiling.
    public static let defaultChunkSize = 1 << 20

    /// How the file spells its characters, from its BOM or from a sniff.
    public let encoding: DSLByteEncoding
    /// Total file length.
    public let byteCount: Int

    private let source: any DSLByteSource
    /// The read buffer, allocated once and reused for the whole file.
    private var chunk: [UInt8]
    /// Absolute offset of `chunk[0]`. Always even for UTF-16, which is what
    /// makes an index's parity within the chunk equal its parity in the file.
    private var chunkStart = 0
    /// Index into `chunk` of the next unexamined byte.
    private var cursor = 0
    /// Valid bytes in `chunk`.
    private var available = 0
    /// Absolute offset of the next byte to read from the source.
    private var nextOffset: Int
    /// Bytes of the line being assembled, which may span chunks.
    private var pending: [UInt8] = []
    /// Absolute offset of `pending`'s first byte.
    private var pendingStart: Int
    /// UTF-8 scratch for decoding, reused rather than allocated per line.
    private var scratch: [UInt8] = []
    private var reachedEnd = false

    /// Opens a source for reading.
    ///
    /// - Parameters:
    ///   - source: the bytes to read.
    ///   - offset: where to start, for resuming an interrupted import. Nil
    ///     starts at the beginning, skipping the byte-order mark. A supplied
    ///     offset is taken literally — a resume point recorded by this reader
    ///     is already past the BOM.
    ///   - chunkSize: read-buffer size, rounded up to a whole number of
    ///     UTF-16 code units.
    public init(
        source: any DSLByteSource,
        resumingAt offset: Int? = nil,
        chunkSize: Int = Self.defaultChunkSize,
    ) throws {
        self.source = source
        byteCount = source.byteCount

        var prefix = [UInt8](repeating: 0, count: min(64, max(byteCount, 0)))
        if !prefix.isEmpty {
            var filled = 0
            while filled < prefix.count {
                let read = try source.read(at: filled, into: &prefix, from: filled)
                guard read > 0 else { break }
                filled += read
            }
            prefix.removeLast(prefix.count - filled)
        }
        let detected = Self.detectEncoding(prefix: prefix)
        encoding = detected.encoding

        if encoding.codeUnitWidth == 2, !byteCount.isMultiple(of: 2) {
            throw DSLByteError.oddByteLength(byteCount: byteCount)
        }

        let start = offset ?? detected.bomLength
        guard start >= 0, start <= byteCount else {
            throw DSLByteError.offsetOutOfRange(offset: start, byteCount: byteCount)
        }
        guard start.isMultiple(of: encoding.codeUnitWidth) else {
            throw DSLByteError.misalignedOffset(start)
        }

        // Even, so a UTF-16 code unit never straddles two chunks.
        chunk = [UInt8](repeating: 0, count: max(2, chunkSize + chunkSize % 2))
        nextOffset = start
        pendingStart = start
        pending.reserveCapacity(4096)
        scratch.reserveCapacity(4096)
    }

    public init(
        url: URL,
        resumingAt offset: Int? = nil,
        chunkSize: Int = Self.defaultChunkSize,
    ) throws {
        try self.init(
            source: DSLFileBytes(url: url),
            resumingAt: offset,
            chunkSize: chunkSize,
        )
    }

    /// The next line, or nil at end of file.
    public mutating func next() throws -> DSLLine? {
        while true {
            if cursor == available {
                guard try fill() else { return finalLine() }
            }
            if let terminator = terminatorIndex(from: cursor) {
                pending.append(contentsOf: chunk[cursor ..< terminator])
                cursor = terminator + encoding.codeUnitWidth
                let line = takeLine()
                pendingStart = chunkStart + cursor
                return line
            }
            pending.append(contentsOf: chunk[cursor ..< available])
            cursor = available
        }
    }

    // MARK: - Reading

    /// Refills the chunk. Returns false at end of file.
    ///
    /// Loops until the buffer is full so that a source returning a short read
    /// cannot leave half a UTF-16 code unit at the end of the chunk — which
    /// would be the same misalignment bug arriving by a different route.
    private mutating func fill() throws -> Bool {
        guard !reachedEnd else { return false }
        chunkStart = nextOffset
        cursor = 0
        available = 0
        while available < chunk.count {
            let read = try source.read(at: nextOffset, into: &chunk, from: available)
            guard read > 0 else {
                reachedEnd = true
                break
            }
            available += read
            nextOffset += read
        }
        return available > 0
    }

    /// Index within the chunk of the line terminator's first byte, if the
    /// current chunk holds one.
    ///
    /// For UTF-16 the scan steps two bytes at a time from an even index, so
    /// it can only ever match a whole code unit. `cursor` is even throughout:
    /// `chunkStart` is even, a chunk holds whole code units, and the cursor
    /// advances by the code-unit width or to the end of the chunk.
    private func terminatorIndex(from start: Int) -> Int? {
        switch encoding {
        case .utf8:
            var index = start
            while index < available {
                if chunk[index] == 0x0A {
                    return index
                }
                index += 1
            }
        case .utf16LittleEndian:
            var index = start
            while index + 1 < available {
                if chunk[index] == 0x0A, chunk[index + 1] == 0x00 {
                    return index
                }
                index += 2
            }
        case .utf16BigEndian:
            var index = start
            while index + 1 < available {
                if chunk[index] == 0x00, chunk[index + 1] == 0x0A {
                    return index
                }
                index += 2
            }
        }
        return nil
    }

    private mutating func finalLine() -> DSLLine? {
        guard !pending.isEmpty else { return nil }
        return takeLine()
    }

    private mutating func takeLine() -> DSLLine {
        stripCarriageReturn()
        let line = DSLLine(text: decodePending(), offset: pendingStart)
        pending.removeAll(keepingCapacity: true)
        return line
    }

    private mutating func stripCarriageReturn() {
        let width = encoding.codeUnitWidth
        guard pending.count >= width else { return }
        let last = pending.count - width
        switch encoding {
        case .utf8:
            if pending[last] == 0x0D {
                pending.removeLast(width)
            }
        case .utf16LittleEndian:
            if pending[last] == 0x0D, pending[last + 1] == 0x00 {
                pending.removeLast(width)
            }
        case .utf16BigEndian:
            if pending[last] == 0x00, pending[last + 1] == 0x0D {
                pending.removeLast(width)
            }
        }
    }

    // The lint rule against a lossy decode is suppressed rather than obeyed,
    // and only here. It is right in general — a silent U+FFFD hides a real
    // encoding problem — but lossy is the specification at this one point:
    // `String(bytes:encoding:)` returns nil for a line holding one bad code
    // unit, which would cost the whole card.
    // swiftlint:disable optional_data_string_conversion

    /// Decodes the pending bytes.
    ///
    /// Malformed input costs the character it mangles and nothing more: an
    /// unpaired surrogate or a bad byte sequence becomes U+FFFD rather than
    /// failing the line, the card around it or the import. That is the same
    /// bargain the lexer makes with a tag it cannot read.
    private mutating func decodePending() -> String {
        guard encoding != .utf8 else { return String(decoding: pending, as: UTF8.self) }
        transcodeUTF16ToUTF8()
        return String(decoding: scratch, as: UTF8.self)
    }

    // swiftlint:enable optional_data_string_conversion

    /// Rewrites the pending UTF-16 bytes into `scratch` as UTF-8.
    ///
    /// Hand-rolled for a measured reason. Over this dictionary's 3.4 million
    /// lines, gathering the code units into a `[UInt16]` costs 0.13 s and
    /// handing them to `String(decoding:as: UTF16.self)` costs a further
    /// 3.05 s; writing UTF-8 directly, so that `String` is handed its own
    /// native storage, costs 0.43 s in total. Byte-identical output, 7× the
    /// speed, and it is the difference between a 10-second and a 2-second
    /// read of the whole set.
    private mutating func transcodeUTF16ToUTF8() {
        let low = encoding == .utf16LittleEndian ? 0 : 1
        let high = 1 - low
        scratch.removeAll(keepingCapacity: true)
        var index = 0
        let end = pending.count
        while index + 1 < end {
            var scalar = UInt32(pending[index + low]) | (UInt32(pending[index + high]) << 8)
            index += 2
            if scalar < 0x80 {
                scratch.append(UInt8(scalar))
                continue
            }
            // A high surrogate followed by a low one is a single character
            // above the basic plane.
            if scalar >= 0xD800, scalar < 0xDC00, index + 1 < end {
                let next = UInt32(pending[index + low]) | (UInt32(pending[index + high]) << 8)
                if next >= 0xDC00, next < 0xE000 {
                    scalar = 0x10000 + ((scalar - 0xD800) << 10) + (next - 0xDC00)
                    index += 2
                }
            }
            switch scalar {
            case ..<0x800:
                scratch.append(UInt8(0xC0 | (scalar >> 6)))
                scratch.append(UInt8(0x80 | (scalar & 0x3F)))
            case ..<0x10000:
                // A surrogate still standing alone here is not a character.
                let value = scalar >= 0xD800 && scalar < 0xE000 ? 0xFFFD : scalar
                scratch.append(UInt8(0xE0 | (value >> 12)))
                scratch.append(UInt8(0x80 | ((value >> 6) & 0x3F)))
                scratch.append(UInt8(0x80 | (value & 0x3F)))
            default:
                scratch.append(UInt8(0xF0 | (scalar >> 18)))
                scratch.append(UInt8(0x80 | ((scalar >> 12) & 0x3F)))
                scratch.append(UInt8(0x80 | ((scalar >> 6) & 0x3F)))
                scratch.append(UInt8(0x80 | (scalar & 0x3F)))
            }
        }
    }

    // MARK: - Encoding detection

    /// Picks an encoding from the start of the file.
    ///
    /// A byte-order mark settles it. Without one the rule is UTF-8, with one
    /// exception: UTF-8 text cannot contain a NUL byte, so NUL bytes all on
    /// odd offsets mean UTF-16LE and all on even offsets mean UTF-16BE. The
    /// sniff needs one character below U+0100 in the first 64 bytes, which
    /// the format guarantees — a DSL file opens with `#NAME`.
    ///
    /// Defaulting the no-BOM case to UTF-8 rather than refusing is deliberate:
    /// hand-made DSL dictionaries are commonly UTF-8 with no mark.
    static func detectEncoding(prefix: [UInt8]) -> (encoding: DSLByteEncoding, bomLength: Int) {
        if prefix.count >= 3, prefix[0] == 0xEF, prefix[1] == 0xBB, prefix[2] == 0xBF {
            return (.utf8, 3)
        }
        if prefix.count >= 2, prefix[0] == 0xFF, prefix[1] == 0xFE {
            return (.utf16LittleEndian, 2)
        }
        if prefix.count >= 2, prefix[0] == 0xFE, prefix[1] == 0xFF {
            return (.utf16BigEndian, 2)
        }

        var evenZeros = 0
        var oddZeros = 0
        for (index, byte) in prefix.enumerated() where byte == 0 {
            if index.isMultiple(of: 2) {
                evenZeros += 1
            } else {
                oddZeros += 1
            }
        }
        if oddZeros > 0, evenZeros == 0 {
            return (.utf16LittleEndian, 0)
        }
        if evenZeros > 0, oddZeros == 0 {
            return (.utf16BigEndian, 0)
        }
        return (.utf8, 0)
    }
}
