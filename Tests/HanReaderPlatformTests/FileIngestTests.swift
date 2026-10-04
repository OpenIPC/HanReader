// HanReader — MIT licensed. See LICENSE.

import Foundation
import HanReaderCore
import Testing
@testable import HanReaderPlatform

@Suite("File ingest")
struct FileIngestTests {
    private let simplified = "中国人民解放军在北京举行了阅兵式。"

    /// A PNG header followed by deterministic pseudo-random bytes.
    ///
    /// Realistic on purpose, and the realism is the point. An earlier version
    /// of this used a ramp of low bytes, which is not what any file looks
    /// like: it never produces an unpaired surrogate, so it decoded cleanly
    /// as UTF-16 and scored 0.92 — above the floor. Actual binary (PNG, ZIP,
    /// PDF, random bytes) is full of unpaired surrogates and fails UTF-16
    /// outright, which is most of why UTF-16 is safe to try as a last resort.
    ///
    /// Pseudo-random rather than random, so a failure here is reproducible
    /// instead of appearing once a month in CI.
    nonisolated static let pngLikeBytes: Data = {
        var state: UInt32 = 0x1234_5678
        let noise = (0 ..< 256).map { _ -> UInt8 in
            state = state &* 1_664_525 &+ 1_013_904_223
            return UInt8((state >> 16) & 0xFF)
        }
        return Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] + noise)
    }()

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("hanreader-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ data: Data, named name: String, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    private func encoded(_ text: String, as encoding: CFStringEncodings) throws -> Data {
        let raw = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(encoding.rawValue))
        return try #require(text.data(using: String.Encoding(rawValue: raw)))
    }

    // MARK: - Reading text

    /// The manual end-to-end case the plan calls for, as a test: a real
    /// GB18030 file, imported without the reader being asked anything.
    @Test("A GB18030 file imports with no questions asked")
    func readsGb18030() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let data = try encoded(simplified, as: .GB_18030_2000)
        let url = try write(data, named: "text.txt", in: directory)
        let detected = try FileIngest.readText(at: url)

        #expect(detected.text == simplified)
        #expect(detected.encoding == .gb18030)
    }

    /// Unreadable bytes become a choice rather than a dead end, and the error
    /// carries what the picker needs to present it.
    @Test("An undetectable file offers the reader its candidates")
    func undetectableFileOffersChoices() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = try write(Self.pngLikeBytes, named: "binary.png", in: directory)

        #expect(throws: TextImportError.self) {
            try FileIngest.readText(at: url)
        }
        do {
            _ = try FileIngest.readText(at: url)
        } catch let TextImportError.undeterminedEncoding(previews) {
            // Nothing decoded it at all, so there is nothing to offer -- and
            // an empty picker is the honest answer for a PNG. The populated
            // case is covered by the detector's own tests.
            #expect(previews.isEmpty)
        }
    }

    /// A choice made in the picker must be obeyed, not re-detected — the
    /// whole reason for asking is that detection was not trusted.
    @Test("An explicit encoding is used rather than detected")
    func explicitEncodingWins() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let traditional = "中國人民解放軍在北京舉行了閱兵式。"
        let url = try write(encoded(traditional, as: .big5), named: "t.txt", in: directory)

        let forced = try FileIngest.readText(at: url, as: .gb18030)
        #expect(forced.encoding == .gb18030)
        #expect(forced.text != traditional)
        #expect(forced.plausibility < 1, "the reader chose badly, and is told so by the score")
    }

    @Test("An encoding the file is not produces a clear error")
    func wrongExplicitEncodingThrows() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = try write(encoded(simplified, as: .GB_18030_2000), named: "g", in: directory)
        #expect(throws: TextImportError.cannotDecode(.utf8)) {
            try FileIngest.readText(at: url, as: .utf8)
        }
    }

    @Test("Every import error says something a reader can act on")
    func errorsAreDescribed() {
        let errors: [TextImportError] = [.undeterminedEncoding([]), .cannotDecode(.big5)]
        for error in errors {
            #expect(error.errorDescription?.isEmpty == false)
        }
    }

    // MARK: - Copying

    @Test("A copied file is reported by a path relative to its directory")
    func copyReturnsARelativePath() throws {
        let source = try temporaryDirectory()
        let destination = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: destination)
        }

        let url = try write(Data("audio".utf8), named: "chapter.m4a", in: source)
        let name = try FileIngest.copy(url, into: destination)

        // Relative, never absolute. An absolute path embeds the container's
        // UUID, which changes on iOS across installs and restores -- so the
        // prototype's audio attachments broke on the first backup restore,
        // months after the mistake and far from it.
        #expect(name == "chapter.m4a")
        #expect(!name.hasPrefix("/"))
        #expect(FileManager.default.fileExists(
            atPath: destination.appendingPathComponent(name).path,
        ))
    }

    /// Two texts can perfectly well have audio files both called `audio.m4a`.
    /// The second must not overwrite the first, and must not fail either.
    @Test("A second file with the same name does not overwrite the first")
    func copyDoesNotOverwrite() throws {
        let source = try temporaryDirectory()
        let other = try temporaryDirectory()
        let destination = try temporaryDirectory()
        defer {
            for url in [source, other, destination] {
                try? FileManager.default.removeItem(at: url)
            }
        }

        let first = try write(Data("first".utf8), named: "audio.m4a", in: source)
        let second = try write(Data("second".utf8), named: "audio.m4a", in: other)

        let firstName = try FileIngest.copy(first, into: destination)
        let secondName = try FileIngest.copy(second, into: destination)

        #expect(firstName == "audio.m4a")
        #expect(secondName == "audio-2.m4a")
        let contents = try String(
            contentsOf: destination.appendingPathComponent(firstName),
            encoding: .utf8,
        )
        #expect(contents == "first", "the first file was overwritten")
    }

    @Test("A file with no extension still gets a unique name")
    func copyHandlesNamesWithoutExtensions() throws {
        let source = try temporaryDirectory()
        let destination = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: destination)
        }

        let url = try write(Data("x".utf8), named: "recording", in: source)
        #expect(try FileIngest.copy(url, into: destination) == "recording")
        #expect(try FileIngest.copy(url, into: destination) == "recording-2")
    }

    @Test("Copying creates the destination directory")
    func copyCreatesTheDirectory() throws {
        let source = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: source) }
        let destination = source.appendingPathComponent("audio", isDirectory: true)

        let url = try write(Data("x".utf8), named: "a.m4a", in: source)
        _ = try FileIngest.copy(url, into: destination)
        #expect(FileManager.default.fileExists(atPath: destination.path))
    }

    /// The collision is detected by the file system rather than by checking
    /// first, so there is no window between the check and the copy for
    /// another import to take the name. Hard to provoke deterministically —
    /// what is checked here is that an already-taken name is stepped over
    /// rather than failing, which is the behaviour the race would otherwise
    /// break.
    @Test("A name taken between the check and the copy is stepped over")
    func copyStepsOverAnExistingName() throws {
        let source = try temporaryDirectory()
        let destination = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: destination)
        }

        let url = try write(Data("new".utf8), named: "audio.m4a", in: source)
        // Both names already taken, as if two other imports had just won.
        _ = try write(Data("other".utf8), named: "audio.m4a", in: destination)
        _ = try write(Data("other".utf8), named: "audio-2.m4a", in: destination)

        #expect(try FileIngest.copy(url, into: destination) == "audio-3.m4a")
    }

    // MARK: - Security scope

    /// A URL the app itself wrote needs no scoping and returns false from
    /// `startAccessingSecurityScopedResource`. The calls are reference
    /// counted, so stopping anyway would revoke access something else holds —
    /// which is why the wrapper exists rather than two bare calls at each
    /// call site.
    @Test("Access is balanced for a URL that needs no scoping")
    func unscopedAccessStillWorks() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try write(Data("x".utf8), named: "a.txt", in: directory)

        let read = try FileIngest.withAccess(to: url) { try Data(contentsOf: $0) }
        #expect(read == Data("x".utf8))
        // Still readable afterwards: nothing was revoked on the way out.
        #expect(try FileIngest.withAccess(to: url) { try Data(contentsOf: $0) } == read)
    }

    @Test("An error inside the access block propagates")
    func accessPropagatesErrors() {
        let missing = URL(filePath: "/nonexistent/\(UUID().uuidString)")
        #expect(throws: (any Error).self) {
            try FileIngest.withAccess(to: missing) { try Data(contentsOf: $0) }
        }
    }
}
