// HanReader — MIT licensed. See LICENSE.

public import Foundation

/// Identifies a text in the library.
///
/// A wrapper rather than a bare `Int64` so that a text id cannot be passed
/// where some other id is expected.
public struct TextID: Hashable, Sendable, RawRepresentable {
    public let rawValue: Int64
    public init(rawValue: Int64) {
        self.rawValue = rawValue
    }
}

/// A text in the library, without its body.
///
/// The content is deliberately absent. The prototype's `allTexts()` selected
/// it for every row, so opening the sidebar loaded every document in the
/// library in full in order to render a 60-character preview. The preview is
/// stored at import instead, and the body is fetched only when a text is
/// actually opened.
public struct LibraryItem: Hashable, Sendable, Identifiable {
    public let id: TextID
    public let title: String
    /// First ~120 characters, stored at import rather than derived on demand.
    public let preview: String
    public let characterCount: Int
    public let hasAudio: Bool
    public let importedAt: Date
    public let lastOpenedAt: Date?
    /// How far through the text the reader has got, 0...1, for a progress
    /// indicator in the list. Nil when it has never been opened.
    public let progress: Double?

    public init(
        id: TextID,
        title: String,
        preview: String,
        characterCount: Int,
        hasAudio: Bool,
        importedAt: Date,
        lastOpenedAt: Date? = nil,
        progress: Double? = nil,
    ) {
        self.id = id
        self.title = title
        self.preview = preview
        self.characterCount = characterCount
        self.hasAudio = hasAudio
        self.importedAt = importedAt
        self.lastOpenedAt = lastOpenedAt
        self.progress = progress
    }
}

/// Where the reader had got to in a text.
///
/// Stored as a position in the *content*, never as a pixel offset. The
/// prototype had a `scroll_offset` column that was always written as zero and
/// never read, and a pixel offset could not have worked anyway: it is
/// meaningless after a font-size change, a window resize, or moving between a
/// Mac and a phone.
///
/// `characterOffset` is the durable anchor — a UTF-16 offset into the text,
/// which survives even re-segmentation by a different tokenizer, because the
/// block and token indices can be recomputed from it.
public struct ReadingPosition: Hashable, Sendable {
    public let textID: TextID
    /// Paragraph index, for restoring scroll position cheaply.
    public let blockIndex: Int
    /// Token index within that paragraph.
    public let tokenIndex: Int
    /// UTF-16 offset into the text. The authoritative value.
    public let characterOffset: Int
    /// Playback position of the attached audio, if any. The prototype lost
    /// this entirely on every relaunch.
    public let audioTime: Double?
    public let updatedAt: Date

    public init(
        textID: TextID,
        blockIndex: Int,
        tokenIndex: Int,
        characterOffset: Int,
        audioTime: Double? = nil,
        updatedAt: Date = .now,
    ) {
        self.textID = textID
        self.blockIndex = blockIndex
        self.tokenIndex = tokenIndex
        self.characterOffset = characterOffset
        self.audioTime = audioTime
        self.updatedAt = updatedAt
    }

    /// Fraction through the text, for a progress indicator.
    public func fraction(ofTextLength length: Int) -> Double {
        guard length > 0 else { return 0 }
        return min(1, max(0, Double(characterOffset) / Double(length)))
    }
}

/// An audio file attached to a text.
public struct AudioTrack: Hashable, Sendable {
    public let textID: TextID
    /// Path **relative** to the application's audio directory.
    ///
    /// Never absolute. The prototype stored an absolute path containing the
    /// application container's UUID, which changes on iOS across installs and
    /// restores — so every audio attachment broke the first time a user
    /// restored a backup.
    public let relativePath: String
    public let duration: Double?
    public let importedAt: Date

    public init(textID: TextID, relativePath: String, duration: Double?, importedAt: Date) {
        self.textID = textID
        self.relativePath = relativePath
        self.duration = duration
        self.importedAt = importedAt
    }
}
