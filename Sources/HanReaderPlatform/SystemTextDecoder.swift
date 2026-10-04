// HanReader — MIT licensed. See LICENSE.

public import Foundation
public import HanReaderCore

/// Decodes bytes using the system's encoding tables.
///
/// This exists as a separate type in the platform shim for one reason:
/// GB18030 and Big5 have no `String.Encoding` case and are reachable only
/// through CoreFoundation's encoding identifiers, which Apple platforms have
/// and Linux does not. `HanReaderCore` is compiled on Linux by a CI job to
/// keep it portable, so the detection *policy* lives there and this conversion
/// lives here.
public nonisolated struct SystemTextDecoder: TextDecoding {
    public init() {}

    public func decode(_ data: Data, as encoding: SourceTextEncoding) -> String? {
        switch encoding {
        case .utf8:
            // Strict by construction: `String(data:encoding: .utf8)` returns
            // nil on an invalid sequence rather than substituting U+FFFD.
            // That strictness is exactly what makes a successful UTF-8 decode
            // strong evidence, so it must not be traded for leniency.
            String(data: stripped(data, of: Self.utf8ByteOrderMark), encoding: .utf8)
        case .utf16LittleEndian:
            String(data: data, encoding: .utf16LittleEndian).map(stripMark)
        case .utf16BigEndian:
            String(data: data, encoding: .utf16BigEndian).map(stripMark)
        case .gb18030:
            decode(data, as: CFStringEncodings.GB_18030_2000)
        case .big5:
            decode(data, as: CFStringEncodings.big5)
        }
    }

    /// Decodes through a CoreFoundation encoding identifier.
    private func decode(_ data: Data, as encoding: CFStringEncodings) -> String? {
        let raw = CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(encoding.rawValue),
        )
        return String(data: data, encoding: String.Encoding(rawValue: raw))
    }

    private static let utf8ByteOrderMark = Data([0xEF, 0xBB, 0xBF])

    private func stripped(_ data: Data, of prefix: Data) -> Data {
        data.starts(with: prefix) ? data.dropFirst(prefix.count) : data
    }

    /// Removes a decoded byte-order mark.
    ///
    /// `String(data:encoding: .utf16LittleEndian)` names the byte order
    /// explicitly, so it treats a leading `FF FE` as content and hands back a
    /// string beginning with U+FEFF. Left in place that invisible character
    /// becomes the first token of the document, and then part of the stored
    /// content hash — so the same text imported twice, once with a mark and
    /// once without, would not deduplicate.
    private func stripMark(_ text: String) -> String {
        text.first == "\u{FEFF}" ? String(text.dropFirst()) : text
    }
}
