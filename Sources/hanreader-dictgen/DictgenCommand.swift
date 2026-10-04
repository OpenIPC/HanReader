// HanReader — MIT licensed. See LICENSE.

import ArgumentParser
import Foundation
import HanReaderCore
import HanReaderDictionaryImport
import HanReaderPersistence

/// Compiles a source dictionary into HanReader's distributable container.
///
/// This tool is load-bearing for three separate requirements, which is why it
/// exists as a command-line target rather than as a hidden code path inside the
/// app:
///
/// 1. **A reproducible bundled dictionary.** CC-CEDICT is pinned as a source
///    snapshot and compiled at build time, so the repository carries reviewable
///    text rather than a regenerated binary.
/// 2. **CI verification.** A dictionary job asserts the entry count and
///    headword uniqueness after every change, which is the only practical way
///    to notice that a parser refactor silently halved the dictionary.
/// 3. **An iOS import path that never parses DSL.** A Mac compiles a 350 MB
///    BKRS set once and exports the result; iOS imports the compiled container
///    directly.
@main
struct Dictgen: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "hanreader-dictgen",
        abstract: "Compile a source dictionary into a HanReader dictionary container.",
        discussion: """
        Run at build time rather than on first launch: parsing the full \
        CC-CEDICT takes around 2.6 seconds, which would nearly exhaust a \
        three-second first-launch budget before a single row was written. The \
        repository keeps the reviewable .u8 text and the app ships a database \
        it only has to open.

        The dsl subcommand, for ABBYY DSL dictionaries such as BKRS, arrives \
        in milestone M6.
        """,
        version: HanReaderCore.version,
        subcommands: [CompileCEDICT.self, VerifyDictionary.self],
    )

    func run() async throws {
        print("hanreader-dictgen \(HanReaderCore.version)")
        print("Run `hanreader-dictgen cedict --help` to compile a dictionary.")
    }
}
