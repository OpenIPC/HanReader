// HanReader — MIT licensed. See LICENSE.

import Foundation

/// Something a DSL file said that could not be acted on, reported rather than
/// hidden.
///
/// The rule the whole importer follows is that nothing is ever deleted. A span
/// the lexer cannot identify is emitted as literal text *and* reported; a line
/// the card reader cannot place is reported *and* kept. A dictionary that
/// silently drops what it does not understand is worse than one that shows a
/// stray bracket, because the reader cannot tell "the dictionary says nothing
/// here" from "the importer ate it".
public struct DSLDiagnostic: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        /// A bracketed span whose name is not in `DSLTagKind`.
        case unknownTag(String)
        /// A `[` with no matching `]` before the end of the line.
        case unterminatedTag
        /// An indented line with no headword above it. This is what a file
        /// split on a byte boundary rather than a card boundary looks like
        /// from the second half.
        case bodyWithoutHeadword
        /// A headword with no article under it — the other half of the same
        /// split.
        case headwordWithoutBody
        /// An `#INCLUDE` naming a file that is not beside the one including
        /// it.
        case missingInclude(String)
    }

    public let kind: Kind
    /// The text as it appeared, which is also what was emitted or kept.
    public let text: String
    /// Byte offset in the file, where the reporting layer knows one.
    ///
    /// The lexer works a line at a time and does not, so this is nil for its
    /// diagnostics and set for everything found at the card level.
    public let offset: Int?

    public init(kind: Kind, text: String, offset: Int? = nil) {
        self.kind = kind
        self.text = text
        self.offset = offset
    }
}
