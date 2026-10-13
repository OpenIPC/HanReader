// HanReader — MIT licensed. See LICENSE.

import ArgumentParser
import Foundation
import HanReaderCore
import HanReaderPersistence

/// Checks a compiled container and reports what is in it.
///
/// Run in CI after every build of the bundled dictionary. The failure it
/// exists to catch is the quiet one: a parser or lexicon change that still
/// produces a valid, openable database containing half the words. Everything
/// compiles, the app runs, and words simply stop being found.
struct VerifyDictionary: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "verify",
        abstract: "Check a compiled dictionary and report its contents.",
    )

    @Argument(help: "Path to the .hanreaderdict file.") var input: String

    /// Defaults sized for the bundled dictionary, which is what this command
    /// was written to guard: the failure it catches is a parser refactor that
    /// silently halves it, where everything still builds and words simply
    /// stop being found. They are applied only to the format they describe —
    /// a container compiled from someone's own DSL dictionary may legitimately
    /// hold a hundred entries — and are options so a caller can state its own.
    @Option(help: "Fail if fewer than this many entries are present.") var minimumEntries = 100_000

    @Option(help: "Fail if fewer than this many lexemes are present.") var minimumLexemes = 80000

    @Flag(help: "Also measure lookup latency.") var benchmark = false

    func run() throws {
        let url = URL(fileURLWithPath: input)

        let openStarted = Date()
        let container = try DictionaryContainer(contentsOf: url)
        let openTime = Date().timeIntervalSince(openStarted)

        guard let metadata = try container.metadata() else {
            throw VerifyError.missingMetadata
        }

        let entryCount = try container.entryCount()
        let lexemeCount = try container.lexemeCount()
        let longestLexeme = try container.longestLexeme()
        let bases = try container.syllableBases()
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0

        report(metadata: metadata, openTime: openTime, counts: Counts(
            entries: entryCount,
            lexemes: lexemeCount,
            bases: bases.count,
            bytes: size,
        ))

        // Attribution is a licence obligation, not a nicety, so its absence is
        // a hard failure rather than a warning.
        guard !metadata.attribution.isEmpty, !metadata.licence.isEmpty else {
            throw VerifyError.missingAttribution
        }
        guard entryCount == metadata.entryCount else {
            throw VerifyError.entryCountMismatch(recorded: metadata.entryCount, actual: entryCount)
        }
        let isBundled = metadata.format == "cc-cedict"
        guard !isBundled || entryCount >= minimumEntries else {
            throw VerifyError.tooFew(what: "entries", got: entryCount, expected: minimumEntries)
        }
        guard !isBundled || lexemeCount >= minimumLexemes else {
            throw VerifyError.tooFew(what: "lexemes", got: lexemeCount, expected: minimumLexemes)
        }
        guard entryCount > 0 else {
            throw VerifyError.tooFew(what: "entries", got: 0, expected: 1)
        }
        // A lexeme longer than the cap means maximum-matching could swallow a
        // whole clause, which is the specific failure the cap prevents.
        if longestLexeme > LexiconBuilder.maximumWordLength {
            throw VerifyError.lexemeTooLong(longestLexeme)
        }

        // The spot checks below are CC-CEDICT's own words, and every check
        // above this line is structural. A container compiled from someone's
        // DSL dictionary is a valid container that does not contain 中国 with
        // the reading `zhong1 guo2`, and failing it for that would make
        // `verify` useless for the format this milestone added.
        if isBundled {
            try checkKnownWords(container)
        } else {
            print("  (content checks are CC-CEDICT's; skipped for \(metadata.format))")
        }

        if benchmark {
            try measureLookups(container)
        }
        print("  OK")
    }

    /// What the container turned out to hold.
    private struct Counts {
        let entries: Int
        let lexemes: Int
        let bases: Int
        let bytes: Int
    }

    private func report(
        metadata: DictionaryMetadata,
        openTime: TimeInterval,
        counts: Counts,
    ) {
        print("""
        \(metadata.displayName) (\(metadata.slug))
          licence:       \(metadata.licence)
          source:        \(metadata.sourceVersion ?? "unspecified")
          parser:        v\(metadata.parserVersion)
          entries:       \(counts.entries)
          lexemes:       \(counts.lexemes)
          syllables:     \(counts.bases) bases
          size:          \(counts.bytes / 1_048_576) MB
          open:          \(String(format: "%.1f", openTime * 1000)) ms
        """)
    }

    /// Words that must be findable, with the reading they must have.
    ///
    /// A spot check rather than a sample: each is here because it would catch
    /// a different kind of regression.
    private func checkKnownWords(_ container: DictionaryContainer) throws {
        // Checked through the lexicon as well as through lookup. A lexicon
        // regression that drops 中国 while keeping 80,000 other words breaks
        // segmentation for it, and an entry-count check cannot see that.
        let lexicon = try Set(container.lexicon().map(\.word))

        for expectation in Self.expectations {
            let found = try container.entries(for: expectation.word)
            let readings = Set(found.map(\.readingKey))
            let missing = expectation.readings.subtracting(readings)
            guard missing.isEmpty else {
                throw VerifyError.missingReadings(
                    expectation.word,
                    missing: missing.sorted(),
                    found: readings.sorted(),
                    note: expectation.note,
                )
            }
            if expectation.inLexicon, !lexicon.contains(expectation.word) {
                throw VerifyError.missingLexeme(expectation.word)
            }
        }

        // The per-character fallback is what gives pinyin to words no
        // dictionary lists as a unit. Without it a reader using a Russian
        // dictionary sees pinyin on almost nothing, since 77% of BKRS entries
        // carry no reading.
        for character in "学习中文很有趣學習們對"
            where try container.readings(forCharacter: character).isEmpty
        {
            throw VerifyError.missingCharacterReading(character)
        }
    }

    private struct Expectation {
        let word: String
        let readings: Set<String>
        let inLexicon: Bool
        let note: String
    }

    /// Each expectation names the readings it must find, not merely how many
    /// entries exist. Counting alone passes a container holding two 了 rows
    /// that are both `le5`, which is precisely the regression the 了 check is
    /// supposed to catch.
    private static let expectations = [
        Expectation(
            word: "和",
            readings: ["he2", "he4", "hu2", "huo2", "huo4"],
            inLexicon: true,
            note: "homographs survive — the prototype kept one of eight",
        ),
        Expectation(
            word: "了",
            readings: ["le5", "liao3"],
            inLexicon: true,
            note: "both readings, not two copies of one",
        ),
        Expectation(
            word: "中国",
            readings: ["Zhong1 guo2"],
            inLexicon: true,
            note: "an ordinary two-character word",
        ),
        Expectation(
            word: "中國",
            readings: ["Zhong1 guo2"],
            inLexicon: true,
            note: "the same word in traditional script",
        ),
        Expectation(
            word: "北京",
            readings: ["Bei3 jing1"],
            inLexicon: true,
            note: "a capitalised proper noun",
        ),
        Expectation(
            word: "略",
            readings: ["lu:e4"],
            inLexicon: true,
            note: "a u: base, where the tone mark lands on the e",
        ),
    ]

    private func measureLookups(_ container: DictionaryContainer) throws {
        let words = ["中国", "学习", "朋友", "电脑", "咖啡", "和", "了", "爱", "北京", "谢谢"]
        let iterations = 200
        let started = Date()
        for _ in 0 ..< iterations {
            for word in words {
                _ = try container.entries(for: word)
            }
        }
        let each = Date().timeIntervalSince(started) / Double(iterations * words.count)
        print("  lookup:        \(String(format: "%.0f", each * 1_000_000)) µs mean")
    }

    enum VerifyError: Error, CustomStringConvertible {
        case missingMetadata
        case missingAttribution
        case entryCountMismatch(recorded: Int, actual: Int)
        case tooFew(what: String, got: Int, expected: Int)
        case lexemeTooLong(Int)
        case missingReadings(String, missing: [String], found: [String], note: String)
        case missingLexeme(String)
        case missingCharacterReading(Character)

        var description: String {
            switch self {
            case .missingMetadata:
                "the container has no metadata, so it cannot be attributed or identified"
            case .missingAttribution:
                "the container records no licence or attribution, which CC BY-SA requires"
            case let .entryCountMismatch(recorded, actual):
                "metadata records \(recorded) entries but the table holds \(actual)"
            case let .tooFew(what, got, expected):
                """
                only \(got) \(what), expected at least \(expected) \
                — something is dropping data silently
                """
            case let .lexemeTooLong(length):
                """
                a lexeme of \(length) characters exceeds the \
                \(LexiconBuilder.maximumWordLength)-character cap; maximum-matching \
                would swallow whole clauses
                """
            case let .missingReadings(word, missing, found, note):
                """
                \(word): missing reading(s) \(missing.joined(separator: ", ")); \
                found \(found.joined(separator: ", ")) — \(note)
                """
            case let .missingLexeme(word):
                """
                \(word) is not in the segmentation lexicon, so text containing \
                it would be split character by character
                """
            case let .missingCharacterReading(character):
                "no reading for \(character); the per-character pinyin fallback is broken"
            }
        }
    }
}
