// HanReader — MIT licensed. See LICENSE.

import Foundation
import Testing
@testable import HanReaderCore

/// Encodes text the way ABBYY writes a DSL file.
private func utf16(_ text: String) -> [UInt8] {
    var bytes: [UInt8] = [0xFF, 0xFE]
    for unit in Array(text.utf16) {
        bytes += [UInt8(unit & 0xFF), UInt8(unit >> 8)]
    }
    return bytes
}

@Suite("DSL file-set discovery")
struct DSLFileSetTests {
    /// Writes a throwaway directory of DSL files.
    func directory(
        _ files: [String: String],
        _ body: (URL) throws -> Void,
    ) throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("hanreader-dsl-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for (name, text) in files {
            try Data(utf16(text)).write(to: root.appendingPathComponent(name))
        }
        try body(root)
    }

    /// The master file names its volumes, so the set is read out of the file
    /// rather than out of a hardcoded list of names — which is what makes the
    /// importer work on a second dictionary, and on a renamed copy of this
    /// one.
    @Test("The set comes from the master file's include directives")
    func includeDirectives() throws {
        try directory([
            "a.dsl": "#NAME \"A\"\n#INCLUDE \"b.dsl\"\n#INCLUDE \"c.dsl\"\n\n爱\n ài\n [m1]x[/m]\n",
            "b.dsl": "#NAME \"B\"\n\n了\n le\n [m1]y[/m]\n",
            "c.dsl": "#NAME \"C\"\n\n一\n yī\n [m1]z[/m]\n",
        ]) { root in
            let set = try DSLFileSet.discover(from: root.appendingPathComponent("a.dsl"))
            #expect(set.discovery == .includeDirectives)
            #expect(set.files.map(\.lastPathComponent) == ["a.dsl", "b.dsl", "c.dsl"])
            #expect(set.header.name == "A")
            #expect(set.diagnostics.isEmpty)
        }
    }

    @Test("An include naming a file that is not there is reported")
    func missingInclude() throws {
        try directory([
            "a.dsl": "#NAME \"A\"\n#INCLUDE \"gone.dsl\"\n\n爱\n ài\n [m1]x[/m]\n",
        ]) { root in
            let set = try DSLFileSet.discover(from: root.appendingPathComponent("a.dsl"))
            #expect(set.files.count == 1)
            #expect(set.diagnostics.map(\.kind) == [.missingInclude("gone.dsl")])
        }
    }

    @Test("An include cycle does not loop")
    func includeCycle() throws {
        try directory([
            "a.dsl": "#NAME \"A\"\n#INCLUDE \"b.dsl\"\n\n爱\n ài\n [m1]x[/m]\n",
            "b.dsl": "#NAME \"B\"\n#INCLUDE \"a.dsl\"\n\n了\n le\n [m1]y[/m]\n",
        ]) { root in
            let set = try DSLFileSet.discover(from: root.appendingPathComponent("a.dsl"))
            #expect(set.files.map(\.lastPathComponent) == ["a.dsl", "b.dsl"])
        }
    }

    /// Only when there are no directives at all.
    @Test("Numbered siblings are found when nothing is declared")
    func numberedSiblings() throws {
        try directory([
            "dict_1.dsl": "#NAME \"1\"\n\n爱\n ài\n [m1]x[/m]\n",
            "dict_2.dsl": "#NAME \"2\"\n\n了\n le\n [m1]y[/m]\n",
            "dict_3.dsl": "#NAME \"3\"\n\n一\n yī\n [m1]z[/m]\n",
        ]) { root in
            let set = try DSLFileSet.discover(from: root.appendingPathComponent("dict_1.dsl"))
            #expect(set.discovery == .numberedSiblings)
            #expect(set.files.map(\.lastPathComponent) == [
                "dict_1.dsl",
                "dict_2.dsl",
                "dict_3.dsl",
            ])
        }
    }

    /// Picking volume two has to find volume one, because that is where the
    /// directives and the dictionary's own name live.
    @Test("Picking a later volume restarts discovery from the first")
    func picksLowestSibling() throws {
        try directory([
            "dict_1.dsl": "#NAME \"whole thing\"\n#INCLUDE \"dict_2.dsl\"\n\n爱\n ài\n [m1]x[/m]\n",
            "dict_2.dsl": "#NAME \"volume 2\"\n\n了\n le\n [m1]y[/m]\n",
        ]) { root in
            let set = try DSLFileSet.discover(from: root.appendingPathComponent("dict_2.dsl"))
            #expect(set.discovery == .includeDirectives)
            #expect(set.header.name == "whole thing")
            #expect(set.files.map(\.lastPathComponent) == ["dict_1.dsl", "dict_2.dsl"])
        }
    }

    /// A set missing its second volume is a set of one, not a set of two with
    /// a hole in it.
    @Test("A gap in the numbering ends the run")
    func gapEndsTheRun() throws {
        try directory([
            "dict_1.dsl": "#NAME \"1\"\n\n爱\n ài\n [m1]x[/m]\n",
            "dict_3.dsl": "#NAME \"3\"\n\n一\n yī\n [m1]z[/m]\n",
        ]) { root in
            let set = try DSLFileSet.discover(from: root.appendingPathComponent("dict_1.dsl"))
            #expect(set.files.map(\.lastPathComponent) == ["dict_1.dsl"])
            #expect(set.discovery == .single)
        }
    }

    @Test("Zero padding in the numbering is preserved")
    func zeroPadding() throws {
        try directory([
            "vol_01.dsl": "#NAME \"1\"\n\n爱\n ài\n [m1]x[/m]\n",
            "vol_02.dsl": "#NAME \"2\"\n\n了\n le\n [m1]y[/m]\n",
        ]) { root in
            let set = try DSLFileSet.discover(from: root.appendingPathComponent("vol_01.dsl"))
            #expect(set.files.map(\.lastPathComponent) == ["vol_01.dsl", "vol_02.dsl"])
        }
    }

    /// A file whose name happens to end in a digit is not part of a run it is
    /// not in; importing files the reader did not pick needs a better reason
    /// than a coincidence of naming.
    @Test("A file outside the numbered run is imported alone")
    func unrelatedNumbering() throws {
        try directory([
            "dict_1.dsl": "#NAME \"1\"\n\n爱\n ài\n [m1]x[/m]\n",
            "dict_9.dsl": "#NAME \"9\"\n\n了\n le\n [m1]y[/m]\n",
        ]) { root in
            let set = try DSLFileSet.discover(from: root.appendingPathComponent("dict_9.dsl"))
            #expect(set.files.map(\.lastPathComponent) == ["dict_9.dsl"])
            #expect(set.discovery == .single)
        }
    }

    /// Returning 64 volumes of a 65-volume dictionary as though it were
    /// complete is the worst of the three possible behaviours: it imports, it
    /// looks right, and the missing volume's words simply cannot be found.
    @Test("Discovery says so when it stops at its file limit")
    func tooManyIncludes() throws {
        var files: [String: String] = [:]
        let includes = (1 ... DSLFileSet.fileLimit + 2)
            .map { "#INCLUDE \"v\($0).dsl\"\n" }
            .joined()
        files["a.dsl"] = "#NAME \"A\"\n" + includes + "\n爱\n ài\n [m1]x[/m]\n"
        for index in 1 ... DSLFileSet.fileLimit + 2 {
            files["v\(index).dsl"] = "#NAME \"\(index)\"\n\n了\n le\n [m1]y[/m]\n"
        }
        try directory(files) { root in
            let set = try DSLFileSet.discover(from: root.appendingPathComponent("a.dsl"))
            #expect(set.files.count == DSLFileSet.fileLimit)
            #expect(set.diagnostics.contains {
                $0.kind == .tooManyFiles(limit: DSLFileSet.fileLimit)
            })
        }
    }

    @Test("A numbered run that hits the limit says so too")
    func tooManySiblings() throws {
        var files: [String: String] = [:]
        for index in 1 ... DSLFileSet.fileLimit + 2 {
            files["vol_\(index).dsl"] = "#NAME \"\(index)\"\n\n了\n le\n [m1]y[/m]\n"
        }
        try directory(files) { root in
            let set = try DSLFileSet.discover(from: root.appendingPathComponent("vol_1.dsl"))
            #expect(set.files.count == DSLFileSet.fileLimit)
            #expect(set.diagnostics.contains {
                $0.kind == .tooManyFiles(limit: DSLFileSet.fileLimit)
            })
        }
    }

    /// Under a sandbox the reader's choice of one file need not grant
    /// access to its siblings, and a dictionary importing two volumes of
    /// three with a diagnostic beats one importing nothing with an error.
    @Test("A volume that is there but unreadable is reported, not thrown")
    func unreadableIncludeIsReported() throws {
        try directory([
            "a.dsl": "#NAME \"A\"\n#INCLUDE \"b.dsl\"\n#INCLUDE \"c.dsl\"\n\n爱\n ài\n [m1]x[/m]\n",
            "c.dsl": "#NAME \"C\"\n\n一\n yī\n [m1]z[/m]\n",
        ]) { root in
            // Present, and refusing to be read.
            let unreadable = root.appendingPathComponent("b.dsl")
            try Data().write(to: unreadable)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0],
                ofItemAtPath: unreadable.path,
            )
            defer {
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o644],
                    ofItemAtPath: unreadable.path,
                )
            }

            let set = try DSLFileSet.discover(from: root.appendingPathComponent("a.dsl"))
            #expect(set.files.map(\.lastPathComponent) == ["a.dsl", "c.dsl"])
            #expect(set.diagnostics.map(\.kind) == [.missingInclude("b.dsl")])
        }
    }

    @Test("A name with no trailing number stands alone")
    func noNumber() throws {
        try directory([
            "dict.dsl": "#NAME \"d\"\n\n爱\n ài\n [m1]x[/m]\n",
        ]) { root in
            let set = try DSLFileSet.discover(from: root.appendingPathComponent("dict.dsl"))
            #expect(set.discovery == .single)
            #expect(set.files.map(\.lastPathComponent) == ["dict.dsl"])
        }
    }
}
