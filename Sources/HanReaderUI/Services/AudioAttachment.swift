// HanReader — MIT licensed. See LICENSE.

import Foundation
import HanReaderCore
import HanReaderPersistence
import UniformTypeIdentifiers

/// Copies a narration into the app's own storage and records it against a
/// text.
///
/// ### Copy in, always
///
/// Both platforms, no exceptions. The reader picked the file out of a
/// security-scoped location and that grant does not survive the launch, let
/// alone a restore from backup — so a reference to where they found it is a
/// reference that will stop working. Copying is also what makes the stored
/// path *ours*, and therefore relative.
///
/// ### Relative paths, which is the whole point
///
/// The prototype stored `dest.path` — an absolute path containing the app
/// container's UUID. That UUID changes when an iOS app is reinstalled or
/// restored from a backup, so every audio association in the library broke
/// at once, silently, long after the mistake. `LibraryRepository.attachAudio`
/// rejects an absolute path outright; this is the code that gives it a
/// relative one.
enum AudioAttachment {
    /// Audio formats worth offering. AVFoundation reads more than this, but
    /// a picker that lists everything invites a reader to choose a video
    /// file and wonder why it has no picture.
    static let contentTypes: [UTType] = [.audio, .mpeg4Audio, .mp3, .wav, .aiff]

    /// Copies `url` into the audio directory and records it against `text`.
    ///
    /// - Returns: the file inside the container, ready to play.
    @discardableResult
    static func attach(
        _ url: URL,
        to text: TextID,
        in locations: AppDatabase.Locations,
        library: LibraryRepository,
    ) async throws
        -> URL
    {
        // Scoped to the reader's choice. Without this the copy fails on a
        // sandboxed build with a permission error that reads like a missing
        // file.
        let scoped = url.startAccessingSecurityScopedResource()
        defer {
            if scoped {
                url.stopAccessingSecurityScopedResource()
            }
        }

        try FileManager.default.createDirectory(
            at: locations.audio,
            withIntermediateDirectories: true,
        )

        // Named after the text rather than after the source file, so two
        // texts narrated by files both called `audio.m4a` do not collide,
        // and so the name carries no part of the reader's own filesystem.
        let name = "text-\(text.rawValue).\(url.pathExtension.lowercased())"
        let destination = locations.audio.appendingPathComponent(name)
        let previous = try await library.audioTrack(for: text)

        // Copied beside the destination first, then moved into place. The
        // obvious order — delete the old file, copy the new one — destroys a
        // working narration the moment the copy fails, leaving a row
        // pointing at a file that is no longer there.
        let staging = locations.audio
            .appendingPathComponent("incoming-\(UUID().uuidString).\(url.pathExtension)")
        try FileManager.default.copyItem(at: url, to: staging)
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: staging)
            } else {
                try FileManager.default.moveItem(at: staging, to: destination)
            }
            try await library.attachAudio(AudioTrack(
                textID: text,
                relativePath: name,
                // Left for the player to discover. Reading it here would mean
                // loading the asset twice, and a duration the transport has
                // not confirmed is worse than none.
                duration: nil,
                importedAt: Date(),
            ))
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }

        // The row holds one path, so a narration replaced by a file with a
        // different extension leaves the old one on disk with nothing
        // pointing at it and no way to find it later.
        if let previous, previous.relativePath != name {
            try? FileManager.default.removeItem(
                at: file(for: previous, in: locations),
            )
        }
        return destination
    }

    /// Where a recorded track lives now.
    ///
    /// Resolved on every use rather than stored, because the container
    /// directory is exactly the thing that moves.
    static func file(
        for track: AudioTrack,
        in locations: AppDatabase.Locations,
    )
        -> URL
    {
        locations.audio.appendingPathComponent(track.relativePath)
    }
}
