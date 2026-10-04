// HanReader — MIT licensed. See LICENSE.

public import Foundation
public import HanReaderCore

/// Reading files the reader picked, on both platforms.
///
/// One boundary for every file that enters the app, because the prototype had
/// two and got one of them wrong: it called
/// `startAccessingSecurityScopedResource()` for audio and not for text. That
/// worked only because the Mac app was not sandboxed — the first sandboxed
/// build, or the first iOS build, would have failed to read any imported text
/// at all, and the symptom would have been a permission error for a file the
/// reader had just chosen in a picker.
///
/// Everything is copied in at import. No security-scoped bookmarks, no
/// resolving a stale URL later, no "the file has moved" failure mode months
/// after the fact.
public enum FileIngest {
    /// Runs `body` with security-scoped access to `url`.
    ///
    /// `stopAccessing` is called **only** if `startAccessing` returned true.
    /// The calls are reference-counted, so an unbalanced stop revokes access
    /// that something else is relying on — and a URL that needs no scoping
    /// returns false, which is the common case for a file the app itself
    /// wrote and the easiest one to get wrong.
    public static func withAccess<T>(to url: URL, _ body: (URL) throws -> T) rethrows -> T {
        let scoped = url.startAccessingSecurityScopedResource()
        defer {
            if scoped {
                url.stopAccessingSecurityScopedResource()
            }
        }
        return try body(url)
    }

    /// Reads a text file, working out its encoding.
    ///
    /// - Throws: `TextImportError.undeterminedEncoding` when nothing decoded
    ///   convincingly, carrying a preview of each candidate so the caller can
    ///   ask the reader rather than failing.
    public static func readText(
        at url: URL,
        decoder: some TextDecoding = SystemTextDecoder(),
    ) throws
        -> DetectedText
    {
        let data = try withAccess(to: url) { try Data(contentsOf: $0) }
        guard let detected = TextEncodingDetector.detect(data, using: decoder) else {
            let previews = TextEncodingDetector.previews(of: data, using: decoder)
            throw TextImportError.undeterminedEncoding(previews)
        }
        return detected
    }

    /// Reads a text file in an encoding the reader chose.
    ///
    /// Separate from `readText(at:decoder:)` so that a choice made in the
    /// picker is obeyed rather than re-detected — the whole point of asking
    /// is that detection was not trusted.
    public static func readText(
        at url: URL,
        as encoding: SourceTextEncoding,
        decoder: some TextDecoding = SystemTextDecoder(),
    ) throws
        -> DetectedText
    {
        let data = try withAccess(to: url) { try Data(contentsOf: $0) }
        guard let text = decoder.decode(data, as: encoding) else {
            throw TextImportError.cannotDecode(encoding)
        }
        return DetectedText(
            text: text,
            encoding: encoding,
            plausibility: TextPlausibility.score(text),
            fromByteOrderMark: false,
        )
    }

    /// Copies a file into a directory the app owns, and returns its path
    /// **relative** to that directory.
    ///
    /// Relative, never absolute. An absolute path inside the app's container
    /// embeds a UUID that changes on iOS across installs and restores, so the
    /// prototype's stored audio paths broke the first time anyone restored a
    /// backup — on a device, months later, with nothing to point at the
    /// cause.
    public static func copy(
        _ url: URL,
        into directory: URL,
        fileManager: FileManager = .default,
    ) throws
        -> String
    {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = uniqueName(for: url.lastPathComponent, in: directory, fileManager: fileManager)
        let destination = directory.appendingPathComponent(name)

        try withAccess(to: url) { source in
            // Replacing rather than failing would silently discard whatever
            // was there, and `uniqueName` has already guaranteed there is
            // nothing to replace.
            try fileManager.copyItem(at: source, to: destination)
        }
        return name
    }

    /// A name no existing file in `directory` already uses.
    ///
    /// Two texts can perfectly well be given audio files both called
    /// `audio.m4a`; the second must not overwrite the first.
    private static func uniqueName(
        for name: String,
        in directory: URL,
        fileManager: FileManager,
    )
        -> String
    {
        let base = (name as NSString).deletingPathExtension
        let suffix = (name as NSString).pathExtension
        var candidate = name
        var counter = 2

        while fileManager.fileExists(atPath: directory.appendingPathComponent(candidate).path) {
            let numbered = "\(base)-\(counter)"
            candidate = suffix.isEmpty ? numbered : "\(numbered).\(suffix)"
            counter += 1
        }
        return candidate
    }
}

/// Why a text file could not be imported.
public enum TextImportError: Error, Sendable, Equatable, LocalizedError {
    /// Nothing decoded convincingly. Carries a preview of each candidate that
    /// decoded at all, so the caller can show them and let the reader pick.
    case undeterminedEncoding([EncodingPreview])
    /// An encoding the reader chose explicitly could not read the file.
    case cannotDecode(SourceTextEncoding)

    public var errorDescription: String? {
        switch self {
        // Plain strings, matching the rest of the package. The string
        // catalogues and the Russian translation arrive together in M9;
        // scattering half-localized messages before then would leave a
        // catalogue that is neither complete nor obviously incomplete.
        case .undeterminedEncoding:
            "HanReader could not work out this file's text encoding."
        case let .cannotDecode(encoding):
            "This file is not valid \(encoding.displayName) text."
        }
    }
}
