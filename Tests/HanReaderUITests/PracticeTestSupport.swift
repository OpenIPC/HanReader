// HanReader — MIT licensed. See LICENSE.

import Foundation
import HanReaderCore
import HanReaderPersistence
import HanReaderPlayback
@testable import HanReaderUI

/// Shared fixtures for the listening-practice suites.
///
/// A namespace rather than file-scoped `private` declarations, for the same
/// reason as `ModelTestSupport`: `private` in Swift reaches extensions in
/// the same file only, and these fixtures are wanted by two suites.
nonisolated enum PracticeTestSupport {
    /// Three sentences of five UTF-16 units each; a phrase covers the four
    /// characters and leaves the full stop out, because what a learner types
    /// is the sentence rather than its punctuation.
    static let content = "第一句话。第二句话。第三句话。"

    static func phrase(_ index: Int, grade: PhraseGrade? = nil) -> Phrase {
        Phrase(
            index: index,
            start: Double(index) * 5,
            end: Double(index) * 5 + 4,
            textRange: (index * 5) ..< (index * 5 + 4),
            grade: grade,
        )
    }

    enum FixtureError: Error { case importFailed }

    /// Services over an in-memory library with a recording attached.
    ///
    /// The file has to exist on disk — `load()` checks, because a row
    /// pointing at a missing file is exactly what a restored backup used to
    /// produce — but nothing ever reads it: the engine is silent.
    @MainActor
    static func services(
        content: String,
        lookup: some DictionaryLookup = EmptyDictionary(),
    ) async throws
        -> (services: AppServices, id: TextID)
    {
        let services = try AppServices.inMemory(lookup: lookup)
        guard case let .imported(id) = try await services.library.importText(
            title: "听力",
            content: content,
        ) else {
            throw FixtureError.importFailed
        }
        let name = "text-\(id.rawValue).m4a"
        try FileManager.default.createDirectory(
            at: services.locations.audio,
            withIntermediateDirectories: true,
        )
        try Data().write(to: services.locations.audio.appendingPathComponent(name))
        try await services.library.attachAudio(AudioTrack(
            textID: id,
            relativePath: name,
            duration: 15,
            importedAt: Date(),
        ))
        return (services, id)
    }

    /// A model over `services`, with a transport that makes no sound and
    /// never waits.
    @MainActor
    static func model(textID: TextID, services: AppServices) -> PracticeModel {
        PracticeModel(
            textID: textID,
            services: services,
            playback: PlaybackModel(
                engine: SilentEngine(),
                session: SilentSession(),
                wait: { _ in },
            ),
        )
    }

    /// A text with three phrases already aligned, so the tests are about
    /// practising rather than about alignment — which needs a speech model
    /// and cannot run on a fresh clone.
    @MainActor
    static func practising(
        grades: [Int: PhraseGrade] = [:],
        attempts: [Int: Double] = [:],
    ) async throws
        -> PracticeModel
    {
        let (services, id) = try await services(content: content)
        try await services.library.savePhrases(
            (0 ..< 3).map { phrase($0, grade: grades[$0]) },
            for: id,
        )
        for (index, accuracy) in attempts {
            try await services.library.recordAttempt("答", accuracy: accuracy, at: index, in: id)
        }
        return model(textID: id, services: services)
    }

    /// Knows that 真 and 针 are both `zhen1`, which is the only way a test
    /// can tell the strict score from the listening one.
    struct HomophoneDictionary: DictionaryLookup {
        func entries(for _: String) throws -> [DictionaryEntry] {
            []
        }

        func readings(forCharacter character: Character) throws -> [CharacterReading] {
            guard let numeric = ["真": "zhen1", "针": "zhen1"][String(character)] else { return [] }
            return [CharacterReading(
                character: character,
                numeric: numeric,
                display: Pinyin.display(Pinyin.parse(numeric: numeric)),
                rank: 0,
            )]
        }
    }
}

/// A transport that makes no sound, for tests about practising rather than
/// about playing.
///
/// At file scope and `@MainActor`, like `SpyEngine` in the playback tests,
/// rather than nested in the namespace above. Nested inside a `nonisolated`
/// type its members would still take this target's `MainActor` default
/// isolation while its implicit initialiser stayed nonisolated — which
/// Xcode 26.6 rejects outright and a later compiler quietly accepts.
@MainActor
final class SilentEngine: AudioEngine {
    var duration = 60.0
    var currentTime = 0.0
    var onTime: ((Double) -> Void)?
    var onDuration: ((Double) -> Void)?
    var onFinish: (() -> Void)?

    func load(_: URL) {}
    func play() {}
    func pause() {}
    func seek(to _: Double) {}
    func setRate(_: Double) {}
    func setStopTime(_: Double?) {}
}

@MainActor
final class SilentSession: PlaybackSession {
    var onInterruption: ((PlaybackInterruption) -> Void)?
    func activate() throws {}
    func deactivate() {}
}
