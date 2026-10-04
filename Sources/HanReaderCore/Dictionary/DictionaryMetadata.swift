// HanReader — MIT licensed. See LICENSE.

public import Foundation

/// What a dictionary container says about itself.
///
/// Carried inside the file rather than alongside it, so attribution and
/// provenance travel with the data. The in-app Acknowledgements screen renders
/// from this, which is what makes CC BY-SA attribution correct by construction
/// for user-imported dictionaries as well as the bundled one.
public struct DictionaryMetadata: Hashable, Sendable {
    /// Stable identifier — `cc-cedict`, `dabkrs-250920`.
    public let slug: String
    /// Shown to the reader.
    public let displayName: String
    /// The source format, so a stale container can be rebuilt from the right
    /// parser.
    public let format: String

    /// What the headwords are written in.
    public let indexLanguage: String
    /// What the definitions are written in. Drives ordering for a reader
    /// whose system language is Russian.
    public let glossLanguage: String

    public let licence: String
    /// The attribution text the licence requires, verbatim.
    public let attribution: String
    public let sourceURL: String?
    /// The upstream version or snapshot date, where the source states one.
    public let sourceVersion: String?

    /// Which parser produced this container.
    ///
    /// Distinct from the schema version, because they fail differently: a
    /// schema change can be migrated, whereas data parsed by a buggy parser
    /// can only be rebuilt. A container whose `parserVersion` is behind the
    /// current one is regenerated rather than migrated.
    public let parserVersion: Int

    public let entryCount: Int
    public let generatedAt: Date

    public init(
        slug: String,
        displayName: String,
        format: String,
        indexLanguage: String,
        glossLanguage: String,
        licence: String,
        attribution: String,
        sourceURL: String? = nil,
        sourceVersion: String? = nil,
        parserVersion: Int,
        entryCount: Int,
        generatedAt: Date = .now,
    ) {
        self.slug = slug
        self.displayName = displayName
        self.format = format
        self.indexLanguage = indexLanguage
        self.glossLanguage = glossLanguage
        self.licence = licence
        self.attribution = attribution
        self.sourceURL = sourceURL
        self.sourceVersion = sourceVersion
        self.parserVersion = parserVersion
        self.entryCount = entryCount
        self.generatedAt = generatedAt
    }
}

extension DictionaryMetadata {
    /// The attribution CC BY-SA 4.0 requires for the bundled dictionary.
    ///
    /// The "changes made" sentence is a licence requirement for adaptations
    /// and the part most often left out, so it is written here once and
    /// carried into every container rather than retyped.
    public static func ccCEDICT(
        entryCount: Int,
        sourceVersion: String?,
        licenceURL: String,
        parserVersion: Int,
    )
        -> Self
    {
        Self(
            slug: "cc-cedict",
            displayName: "CC-CEDICT",
            format: "cc-cedict",
            indexLanguage: "zh-Hans",
            glossLanguage: "en",
            licence: licenceName(from: licenceURL),
            attribution: """
            CC-CEDICT — a bilingual Chinese-English dictionary, by the CC-CEDICT \
            Project (originally MDBG, continuing the CEDICT project begun by Paul \
            Denisowski). Licensed under \(licenceName(from: licenceURL)) \
            (\(licenceURL)). Changes made: parsed from the distributed .u8 text \
            format and converted into a SQLite database for lookup; numeric-tone \
            pinyin additionally rendered into diacritic form for display, and \
            per-character readings and a segmentation word list derived from the \
            headword set. No entry content was altered, removed, or added.
            """,
            sourceURL: "https://www.mdbg.net/chinese/dictionary?page=cc-cedict",
            sourceVersion: sourceVersion,
            parserVersion: parserVersion,
            entryCount: entryCount,
        )
    }

    /// A readable licence name for a Creative Commons URL.
    ///
    /// Falls back to the URL verbatim rather than guessing: an unrecognised
    /// licence should be reported as-is, not relabelled as one we know.
    public static func licenceName(from url: String) -> String {
        let lowered = url.lowercased()
        guard lowered.contains("creativecommons.org") else { return url }
        guard let kind = ["by-nc-sa", "by-sa", "by-nd", "by-nc", "by"]
            .first(where: { lowered.contains("/\($0)/") })
        else { return url }
        let version = lowered
            .split(separator: "/")
            .first { $0.first?.isNumber == true && $0.contains(".") }
            .map(String.init) ?? ""
        return "CC \(kind.uppercased()) \(version)".trimmingCharacters(in: .whitespaces)
    }
}
