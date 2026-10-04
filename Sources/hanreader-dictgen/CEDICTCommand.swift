// HanReader — MIT licensed. See LICENSE.

import ArgumentParser
import Foundation
import HanReaderCore
import HanReaderPersistence

/// Compiles CC-CEDICT into a `.hanreaderdict` container.
///
/// Run at *build* time rather than on first launch. Parsing the full
/// dictionary takes around 2.6 seconds in a release build, which on its own
/// nearly exhausts a three-second first-launch budget before a single row is
/// written — so the work moves to the build, the repository keeps the
/// reviewable `.u8` text, and the app ships a database it only has to open.
struct CompileCEDICT: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cedict",
        abstract: "Compile a CC-CEDICT .u8 file into a HanReader dictionary.",
    )

    /// Bumped whenever the parser's *output* changes.
    ///
    /// Containers record this, so a parser fix invalidates and rebuilds them.
    /// No schema migration can repair data that was parsed wrongly.
    static let parserVersion = 1

    @Argument(help: "Path to cedict_ts.u8.") var input: String

    @Option(name: .shortAndLong, help: "Where to write the .hanreaderdict file.") var output: String

    @Option(help: "Fail if fewer than this many entries are produced.") var minimumEntries = 100_000

    @Flag(name: .shortAndLong, help: "Print progress and statistics.") var verbose = false

    func run() throws {
        let inputURL = URL(fileURLWithPath: input)
        let outputURL = URL(fileURLWithPath: output)

        let started = Date()
        let text = try String(contentsOf: inputURL, encoding: .utf8)
        let parsed = CEDICTParser.parse(text)
        let parseTime = Date().timeIntervalSince(started)

        // A parser refactor that silently halves the dictionary is the failure
        // this guards against: everything still builds, the app still runs,
        // and words simply stop being found. Nobody notices by eye.
        guard parsed.diagnostics.isEmpty else {
            throw CompileError.unparsedLines(
                count: parsed.diagnostics.count,
                samples: parsed.diagnostics.prefix(3).map { "line \($0.line): \($0.text)" },
            )
        }
        guard parsed.entries.count >= minimumEntries else {
            throw CompileError.tooFewEntries(got: parsed.entries.count, expected: minimumEntries)
        }
        // The file states its own entry count. If ours disagrees, one of the
        // two is wrong and it is not safe to guess which.
        if let declared = parsed.metadata["entries"].flatMap(Int.init),
           declared != parsed.entries.count
        {
            throw CompileError.entryCountMismatch(declared: declared, parsed: parsed.entries.count)
        }

        let metadata = DictionaryMetadata.ccCEDICT(
            entryCount: parsed.entries.count,
            sourceVersion: parsed.metadata["date"] ?? parsed.metadata["version"],
            parserVersion: Self.parserVersion,
        )

        try DictionaryContainer.write(entries: parsed.entries, metadata: metadata, to: outputURL)
        let total = Date().timeIntervalSince(started)

        if verbose {
            let container = try DictionaryContainer(contentsOf: outputURL)
            let size = (try? FileManager.default
                .attributesOfItem(atPath: outputURL.path)[.size] as? Int) ?? 0
            try print("""
            entries:    \(parsed.entries.count)
            lexemes:    \(container.lexicon().count)
            characters: \(container.syllableBases().count) syllable bases
            size:       \(size / 1_048_576) MB
            parse:      \(String(format: "%.2f", parseTime))s
            total:      \(String(format: "%.2f", total))s
            """)
        } else {
            print("Wrote \(parsed.entries.count) entries to \(outputURL.lastPathComponent)")
        }
    }

    enum CompileError: Error, CustomStringConvertible {
        case unparsedLines(count: Int, samples: [String])
        case tooFewEntries(got: Int, expected: Int)
        case entryCountMismatch(declared: Int, parsed: Int)

        var description: String {
            switch self {
            case let .unparsedLines(count, samples):
                """
                \(count) line(s) could not be parsed, which means the upstream \
                format has changed or the parser has regressed:
                \(samples.joined(separator: "\n"))
                """
            case let .tooFewEntries(got, expected):
                """
                only \(got) entries were produced, expected at least \(expected). \
                A parser change has probably started dropping entries silently.
                """
            case let .entryCountMismatch(declared, parsed):
                """
                the source declares \(declared) entries but \(parsed) were parsed. \
                One of the two is wrong and guessing which is not safe.
                """
            }
        }
    }
}
