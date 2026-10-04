// HanReader — MIT licensed. See LICENSE.

import ArgumentParser
import Foundation
import HanReaderCore
import HanReaderDictionaryImport
import HanReaderPersistence

/// Compiles an ABBYY DSL dictionary into a `.hanreaderdict` container.
///
/// Unlike `cedict`, this is not a build step: the source is the reader's own
/// file and is never in the repository. It exists so the import can be run and
/// measured outside an app — which is how the resume behaviour is exercised,
/// since `kill -9` is easier to arrange against a command than against a
/// window.
///
/// Interrupting it is expected and safe. Run the same command again and it
/// picks up from the last committed batch.
struct CompileDSL: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "dsl",
        abstract: "Compile an ABBYY DSL dictionary into a HanReader dictionary.",
        discussion: """
        Point it at any file of the set; the others are found through its \
        #INCLUDE directives, or failing that through numbered siblings beside \
        it. Interrupting the command is safe — running it again resumes from \
        the last committed batch rather than starting over.

        A dictionary supplies readings as diacritics, which have to be split \
        into syllables to be comparable with CC-CEDICT's numeric form. Pass \
        --bases pointing at a compiled CC-CEDICT container to enable that; \
        without it a reading still displays exactly as written and only the \
        cross-dictionary merge key is lost.
        """,
    )

    @Argument(help: "Path to any file of the DSL set.") var input: String

    @Option(name: .shortAndLong, help: "Where to write the .hanreaderdict file.") var output: String

    @Option(
        help: "A compiled dictionary to take syllable bases from, normally CC-CEDICT.",
    ) var bases: String?

    @Option(help: "Entries per transaction.") var batchSize = DSLImporter.defaultBatchSize

    @Option(help: "Fail if fewer than this many entries are produced.") var minimumEntries = 1

    @Flag(name: .shortAndLong, help: "Print progress and statistics.") var verbose = false

    func run() throws {
        let outputURL = URL(fileURLWithPath: output)
        let fileSet = try DSLFileSet.discover(from: URL(fileURLWithPath: input))

        var syllableBases: Set<String> = []
        if let bases {
            syllableBases = try DictionaryContainer(contentsOf: URL(fileURLWithPath: bases))
                .syllableBases()
        }

        if verbose {
            print("""
            discovery:  \(fileSet.discovery)
            files:      \(fileSet.files.map(\.lastPathComponent).joined(separator: ", "))
            name:       \(fileSet.header.name ?? "not declared")
            languages:  \(fileSet.header.indexLanguage ?? "?") \
            to \(fileSet.header.contentsLanguage ?? "?")
            bases:      \(syllableBases.count)
            """)
            for diagnostic in fileSet.diagnostics {
                print("  \(diagnostic.kind): \(diagnostic.text)")
            }
        }

        let started = Date()
        let importer = DSLImporter(
            fileSet: fileSet,
            destination: outputURL,
            syllableBases: syllableBases,
            batchSize: batchSize,
        )
        let reporter = ProgressReporter(enabled: verbose)
        let summary = try importer.run(progress: { reporter.report($0) })
        reporter.finish()
        let elapsed = Date().timeIntervalSince(started)

        // The failure this guards against is a parser change that silently
        // halves the dictionary: everything still builds, the app still runs,
        // and words simply stop being found.
        guard summary.entriesWritten >= minimumEntries else {
            throw CompileDSLError.tooFewEntries(
                got: summary.entriesWritten,
                expected: minimumEntries,
            )
        }

        try reportResult(summary, at: outputURL, elapsed: elapsed)
    }

    private func reportResult(
        _ summary: DSLImportSummary,
        at outputURL: URL,
        elapsed: TimeInterval,
    ) throws {
        guard verbose else {
            print("Wrote \(summary.entriesWritten) entries to \(outputURL.lastPathComponent)")
            return
        }
        let container = try DictionaryContainer(contentsOf: outputURL)
        let size = (try? FileManager.default
            .attributesOfItem(atPath: outputURL.path)[.size] as? Int) ?? 0
        try print("""
        resumed:    \(summary.resumed)
        cards:      \(summary.cardsRead)
        entries:    \(summary.entriesWritten)
        lexemes:    \(container.lexemeCount())
        characters: \(container.syllableBases().count) syllable bases
        diagnostics:\(summary.diagnostics)
        slug:       \(summary.metadata.slug)
        name:       \(summary.metadata.displayName)
        size:       \(size / 1_048_576) MB
        elapsed:    \(String(format: "%.1f", elapsed))s
        """)
    }

    /// Prints a single rewritten line, so a long import is legible in a
    /// terminal without scrolling it off the top.
    ///
    /// Stateless, which is what lets it be `Sendable` and go straight into the
    /// importer's `@Sendable` progress callback. The importer reports on its
    /// first batch and again at the end, so there is always a line to
    /// terminate.
    private struct ProgressReporter: Sendable {
        let enabled: Bool

        func report(_ progress: DSLImportProgress) {
            guard enabled else { return }
            let percent = Int(progress.fraction * 100)
            FileHandle.standardError.write(Data("""
            \r  file \(progress.fileIndex + 1)/\(progress.fileCount)  \
            \(percent)%  \(progress.cardsRead) cards  \
            \(progress.entriesWritten) entries
            """.utf8))
        }

        func finish() {
            guard enabled else { return }
            FileHandle.standardError.write(Data("\n".utf8))
        }
    }

    enum CompileDSLError: Error, CustomStringConvertible {
        case tooFewEntries(got: Int, expected: Int)

        var description: String {
            switch self {
            case let .tooFewEntries(got, expected):
                """
                only \(got) entries were produced, expected at least \(expected). \
                A parser change has probably started dropping entries silently.
                """
            }
        }
    }
}
