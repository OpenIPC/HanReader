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
        Subcommands for CC-CEDICT and ABBYY DSL input arrive in milestones M3 \
        and M6 respectively. This build reports the tool and package version so \
        that the build pipeline wiring can be verified end to end first.
        """,
        version: Dictgen.versionString
    )

    static var versionString: String {
        "hanreader-dictgen \(HanReaderCore.moduleName) scaffold"
    }

    func run() async throws {
        // Referencing each module keeps the executable's link graph honest:
        // if a dependency is dropped from Package.swift, this stops compiling.
        let linked = [
            HanReaderCore.moduleName,
            HanReaderPersistence.moduleName,
            HanReaderDictionaryImport.moduleName,
        ]
        print("hanreader-dictgen scaffold — linked modules: \(linked.joined(separator: ", "))")
        print("Dictionary subcommands arrive in milestone M3 (CC-CEDICT) and M6 (DSL).")
    }
}
