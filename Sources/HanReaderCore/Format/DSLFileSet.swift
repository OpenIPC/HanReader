// HanReader — MIT licensed. See LICENSE.

public import Foundation

/// The files one DSL dictionary is spread across.
///
/// The BKRS set is three files, and `dabkrs_1.dsl` names the other two in its
/// own header:
///
/// ```
/// #NAME "大БКРС - 250920 ( 1 / 3 )"
/// #INCLUDE "dabkrs_2.dsl"
/// #INCLUDE "dabkrs_3.dsl"
/// ```
///
/// So the set is discovered by reading the file the reader picked, never by
/// knowing those names. The predecessor prototype hardcoded all three, which
/// means it imports this one dictionary and no other, and stops working if the
/// user renames a file.
///
/// The three files are include-linked volumes rather than byte chunks: each
/// begins and ends on a complete card. They are parsed one at a time and never
/// concatenated, so a failure in the third volume leaves the first two
/// imported.
public struct DSLFileSet: Hashable, Sendable {
    /// How the set was found, which the import screen reports so that
    /// "importing 3 files when I picked 1" is explained rather than
    /// surprising.
    public enum Discovery: Hashable, Sendable {
        /// The picked file named the others in `#INCLUDE` directives.
        case includeDirectives
        /// The picked file named nothing, but numbered siblings sit beside it.
        case numberedSiblings
        /// One file, standing alone.
        case single
    }

    /// The files to parse, in order, the one holding the directives first.
    public let files: [URL]
    /// The master file's header.
    public let header: DSLHeader
    public let discovery: Discovery
    public let diagnostics: [DSLDiagnostic]

    public init(
        files: [URL],
        header: DSLHeader,
        discovery: Discovery,
        diagnostics: [DSLDiagnostic] = [],
    ) {
        self.files = files
        self.header = header
        self.discovery = discovery
        self.diagnostics = diagnostics
    }

    /// Follows at most this many `#INCLUDE` hops. A visited set already stops
    /// a cycle; this stops a pathological file from being a denial of service.
    public static let fileLimit = 64

    /// Works out which files belong with the one the reader picked.
    ///
    /// `#INCLUDE` first, and it is authoritative: a master file that names two
    /// volumes gets exactly those two, in that order, and no directory scan
    /// happens at all. An included file may include further files, which is
    /// followed with a visited set so a cycle cannot loop.
    ///
    /// Only when there are no directives does it look at the directory, and
    /// then only for files whose names differ from the picked one by a trailing
    /// number. If that turns up a lower-numbered sibling — the reader picked
    /// volume 2 of 3 — discovery restarts from the lowest, because that is
    /// where the directives live. The restart terminates: the lowest file of a
    /// numbered run either has directives or is its own lowest sibling.
    public static func discover(
        from url: URL,
        fileManager: FileManager = .default,
    ) throws
        -> Self
    {
        let header = try DSLHeader.read(from: DSLFileBytes(url: url))

        if !header.includes.isEmpty {
            return try following(
                header.includes,
                from: url,
                header: header,
                fileManager: fileManager,
            )
        }

        var truncated = false
        let siblings = numberedSiblings(of: url, fileManager: fileManager, truncated: &truncated)
        guard siblings.count > 1 else {
            return Self(files: [url.standardizedFileURL], header: header, discovery: .single)
        }
        if siblings[0] != url.standardizedFileURL {
            return try discover(from: siblings[0], fileManager: fileManager)
        }
        return Self(
            files: siblings,
            header: header,
            discovery: .numberedSiblings,
            diagnostics: truncated
                ? [DSLDiagnostic(
                    kind: .tooManyFiles(limit: fileLimit),
                    text: url.lastPathComponent,
                )]
                : [],
        )
    }

    /// Walks the `#INCLUDE` graph breadth-first from the master file.
    ///
    /// A visited set rather than a depth limit, so a cycle cannot loop; the
    /// file limit is a separate guard against a pathological file, and
    /// reaching it is reported rather than hidden.
    private static func following(
        _ includes: [String],
        from url: URL,
        header: DSLHeader,
        fileManager: FileManager,
    ) throws
        -> Self
    {
        var files = [url.standardizedFileURL]
        var visited: Set<URL> = [url.standardizedFileURL]
        var diagnostics: [DSLDiagnostic] = []
        var queue = includes.map { (parent: url, name: $0) }

        while !queue.isEmpty {
            guard files.count < fileLimit else {
                // Returning 64 volumes of a 65-volume dictionary as though it
                // were complete is the worst of the three possible
                // behaviours: it imports, it looks right, and the missing
                // volume's words simply cannot be found.
                diagnostics.append(DSLDiagnostic(
                    kind: .tooManyFiles(limit: fileLimit),
                    text: queue.map(\.name).joined(separator: ", "),
                ))
                break
            }
            let (parent, name) = queue.removeFirst()
            let target = parent.deletingLastPathComponent()
                .appendingPathComponent(name)
                .standardizedFileURL
            guard fileManager.fileExists(atPath: target.path) else {
                diagnostics.append(DSLDiagnostic(kind: .missingInclude(name), text: name))
                continue
            }
            guard visited.insert(target).inserted else { continue }
            files.append(target)
            let nested = try DSLHeader.read(from: DSLFileBytes(url: target))
            queue += nested.includes.map { (parent: target, name: $0) }
        }
        return Self(
            files: files,
            header: header,
            discovery: .includeDirectives,
            diagnostics: diagnostics,
        )
    }

    /// Files beside `url` whose names differ only in a trailing number.
    ///
    /// `dabkrs_1.dsl` → `dabkrs_2.dsl`, `dabkrs_3.dsl`. The run is contiguous
    /// from 1: a gap ends it, because a set missing its second volume is a set
    /// of one, not a set of two with a hole. Zero padding is preserved, so
    /// `vol_01` looks for `vol_02` and not `vol_2`.
    static func numberedSiblings(
        of url: URL,
        fileManager: FileManager,
        truncated: inout Bool,
    )
        -> [URL]
    {
        let stem = url.deletingPathExtension().lastPathComponent
        let digits = stem.reversed().prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty else { return [url.standardizedFileURL] }

        let prefix = String(stem.dropLast(digits.count))
        let width = digits.count
        let directory = url.deletingLastPathComponent()
        let suffix = url.pathExtension.isEmpty ? "" : ".\(url.pathExtension)"

        var found: [URL] = []
        var number = 1
        while true {
            let padded = String(number).count >= width
                ? String(number)
                : String(repeating: "0", count: width - String(number).count) + String(number)
            let candidate = directory
                .appendingPathComponent(prefix + padded + suffix)
                .standardizedFileURL
            guard fileManager.fileExists(atPath: candidate.path) else { break }
            found.append(candidate)
            number += 1
            // The run is capped for the same reason the include walk is, and
            // reported the same way: the caller is told the set is longer than
            // this rather than handed a silently short one.
            if found.count >= fileLimit {
                truncated = true
                break
            }
        }
        // The picked file must be in the run; otherwise the names matched by
        // accident and it is safer to import only what was asked for.
        guard found.contains(url.standardizedFileURL) else { return [url.standardizedFileURL] }
        return found
    }
}
