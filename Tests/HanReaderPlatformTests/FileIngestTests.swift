// HanReader — MIT licensed. See LICENSE.

import Foundation
import HanReaderCore
import Testing
@testable import HanReaderPlatform

@Suite("File ingest")
struct FileIngestTests {
    private let simplified = "中国人民解放军在北京举行了阅兵式。"

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

        // A run of control bytes: GB18030 decodes it, and the result is
        // obviously not text.
        let url = try write(
            Data((0 ..< 64).map { UInt8($0 % 24) }),
            named: "binary.txt",
            in: directory,
        )

        #expect(throws: TextImportError.self) {
            try FileIngest.readText(at: url)
        }
        do {
            _ = try FileIngest.readText(at: url)
        } catch let TextImportError.undeterminedEncoding(previews) {
            #expect(!previews.isEmpty)
            #expect(previews.allSatisfy { $0.plausibility < 1 })
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
