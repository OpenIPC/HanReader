// HanReader — MIT licensed. See LICENSE.

import Foundation
import HanReaderCore
import HanReaderPersistence
import HanReaderPlayback

/// One text's listening and dictation practice.
///
/// Document-scoped, like `ReaderModel`: created by `.task(id:)` and
/// discarded with the text, so there is no reset code and no stale state to
/// clear.
@Observable
@MainActor
final class PracticeModel {
    /// What the screen can be doing.
    enum Phase: Equatable {
        /// No recording attached, so there is nothing to practise against.
        case noAudio
        /// A recording, but nobody has worked out where its phrases are.
        case needsAlignment
        case aligning(SpeechAlignmentProgress)
        /// Alignment cannot be done here, with the reason to show.
        case unavailable(AlignmentObstacle)
        case ready
    }

    /// Why automatic alignment is not possible, in terms the reader can act
    /// on — or be told plainly that they cannot.
    enum AlignmentObstacle: Equatable {
        /// The system is older than `SpeechTranscriber`.
        case systemTooOld
        /// The Chinese model is not installed. This is the one worth
        /// offering a button for.
        case modelMissing
        /// Speech recognition does not know this language at all.
        case languageUnsupported
        case failed(String)

        var canInstall: Bool {
            self == .modelMissing
        }
    }

    /// Which phrases the reader is working through.
    enum Filter: String, CaseIterable, Hashable {
        case all
        /// Graded hard, or last attempted below the pass mark. The replay
        /// filter WorkAudioBook spells as "play only bookmarks", and the
        /// closest this gets to a scheduler.
        case needsWork
    }

    private(set) var phase: Phase = .noAudio
    private(set) var phrases: [Phrase] = []
    private(set) var attempts: [Int: DictationAttempt] = [:]
    private(set) var current = 0
    /// The last check, or nil if this phrase has not been answered yet.
    private(set) var result: DictationResult?
    /// Whether the transcript is on screen. Off until checked, because the
    /// answer being visible is the one thing that makes dictation worthless.
    private(set) var isRevealed = false

    var typed = ""
    var filter: Filter = .all
    var drill = PlaybackModel.Drill.once

    let textID: TextID
    private let services: AppServices
    private let playback: PlaybackModel
    private var content = ""
    private var alignTask: Task<Void, Never>?

    init(textID: TextID, services: AppServices, playback: PlaybackModel) {
        self.textID = textID
        self.services = services
        self.playback = playback
    }

    // MARK: - Opening

    func load() async {
        do {
            guard let content = try await services.library.content(of: textID) else {
                phase = .noAudio
                return
            }
            self.content = content
            guard let track = try await services.library.audioTrack(for: textID) else {
                phase = .noAudio
                return
            }
            let file = AudioAttachment.file(for: track, in: services.locations)
            guard FileManager.default.fileExists(atPath: file.path) else {
                phase = .noAudio
                return
            }
            playback.load(file)

            phrases = try await services.library.phrases(for: textID)
            attempts = try await services.library.attempts(for: textID)
            phase = phrases.isEmpty ? .needsAlignment : .ready
            current = firstUnfinished
        } catch {
            Log.error("practice", "could not open practice for \(textID.rawValue): \(error)")
            phase = .unavailable(.failed(error.localizedDescription))
        }
    }

    func close() async {
        alignTask?.cancel()
        alignTask = nil
        playback.clearSegment()
    }

    /// The first phrase not yet passed, so reopening a text resumes rather
    /// than starting the reader at the top of something half done.
    private var firstUnfinished: Int {
        phrases.first { attempts[$0.index]?.isPassing() != true }?.index ?? 0
    }

    // MARK: - Working through phrases

    /// The phrases the reader is actually stepping through, after the
    /// filter.
    ///
    /// The phrase they are on is always in the list, even once it stops
    /// needing work. Dropping it the instant it passes loses their place:
    /// the strip would show nothing as current, and moving on would count
    /// from the top of the list rather than from where they are — so
    /// passing a phrase would skip the one after it. It leaves the list the
    /// moment they move off it, which is the point at which removing it
    /// costs them nothing.
    var visible: [Phrase] {
        switch filter {
        case .all:
            phrases
        case .needsWork:
            phrases.filter { needsWork($0) || $0.index == current }
        }
    }

    func needsWork(_ phrase: Phrase) -> Bool {
        if phrase.grade == .hard {
            return true
        }
        guard let attempt = attempts[phrase.index] else { return true }
        return !attempt.isPassing()
    }

    var phrase: Phrase? {
        phrases.first { $0.index == current }
    }

    var text: String {
        phrase?.text(in: content) ?? ""
    }

    func select(_ index: Int) {
        guard phrases.contains(where: { $0.index == index }) else { return }
        current = index
        typed = attempts[index]?.typed ?? ""
        result = nil
        isRevealed = false
        playback.clearSegment()
    }

    func advance(by offset: Int) {
        let order = visible.map(\.index)
        guard !order.isEmpty else { return }
        let position = order.firstIndex(of: current) ?? 0
        let next = (position + offset).clamped(to: 0 ... (order.count - 1))
        select(order[next])
    }

    /// Plays the current phrase, as many times as the drill asks.
    func play() {
        guard let phrase, phase == .ready else { return }
        playback.play(segment: phrase.audioRange, drill: drill)
    }

    func stop() {
        playback.pause()
    }

    // MARK: - Checking

    /// Marks the attempt and shows the transcript.
    ///
    /// Revealing is part of checking rather than a separate step: the reader
    /// has committed an answer, and the only useful next thing is seeing
    /// where it differed.
    func check() async {
        guard let phrase else { return }
        // Fetched before marking rather than during it. `check` is a pure
        // function over a synchronous lookup, which is what makes it
        // testable without a database — so the asynchronous part happens
        // here, once, for every character either side might need.
        let readings = await services.dictionary.readings(
            forCharacters: Array(text) + Array(typed),
        )
        let outcome = DictationComparison.check(
            typed: typed,
            against: text,
            readings: { readings[$0] ?? [] },
        )
        result = outcome
        isRevealed = true
        do {
            try await services.library.recordAttempt(
                typed,
                accuracy: outcome.listeningAccuracy,
                at: phrase.index,
                in: textID,
            )
            attempts = try await services.library.attempts(for: textID)
        } catch {
            Log.error("practice", "could not record an attempt: \(error)")
        }
    }

    /// Shows the transcript without marking anything — for a reader who
    /// wants to give up on one phrase rather than guess.
    func reveal() {
        isRevealed = true
    }

    func grade(_ grade: PhraseGrade?) async {
        guard let phrase else { return }
        do {
            try await services.library.gradePhrase(phrase.index, in: textID, as: grade)
            phrases = try await services.library.phrases(for: textID)
        } catch {
            Log.error("practice", "could not grade a phrase: \(error)")
        }
    }

    // MARK: - Alignment

    /// Works out where each phrase is said, which is what makes any of the
    /// rest possible.
    func align(installingModel: Bool = false) {
        guard alignTask == nil else { return }
        alignTask = Task { [weak self] in
            await self?.runAlignment(installingModel: installingModel)
            self?.alignTask = nil
        }
    }

    func cancelAlignment() {
        alignTask?.cancel()
        alignTask = nil
        phase = phrases.isEmpty ? .needsAlignment : .ready
    }

    private func runAlignment(installingModel: Bool) async {
        guard #available(macOS 26.0, iOS 26.0, *) else {
            phase = .unavailable(.systemTooOld)
            return
        }
        guard let track = try? await services.library.audioTrack(for: textID) else {
            phase = .noAudio
            return
        }
        let file = AudioAttachment.file(for: track, in: services.locations)
        let aligner = SpeechAligner()
        phase = .aligning(SpeechAlignmentProgress(fraction: nil))

        do {
            let heard = try await aligner.listen(
                to: file,
                installIfNeeded: installingModel,
                progress: { [weak self] progress in
                    Task { @MainActor in self?.report(progress) }
                },
            )
            try Task.checkCancellation()

            let splitting = PhraseSplitting.forAudio(
                characters: content.count,
                duration: heard.duration,
            )
            let placed = ForcedAlignment.align(
                phrases: PhraseSplitter.phrases(in: content, splitting: splitting),
                in: content,
                to: heard,
            )
            try await services.library.savePhrases(placed, for: textID)
            phrases = try await services.library.phrases(for: textID)
            attempts = try await services.library.attempts(for: textID)
            current = firstUnfinished
            phase = .ready
        } catch is CancellationError {
            phase = phrases.isEmpty ? .needsAlignment : .ready
        } catch let problem as SpeechAlignmentProblem {
            phase = .unavailable(obstacle(for: problem))
        } catch {
            phase = .unavailable(.failed(error.localizedDescription))
        }
    }

    private func report(_ progress: SpeechAlignmentProgress) {
        guard case .aligning = phase else { return }
        phase = .aligning(progress)
    }

    private func obstacle(for problem: SpeechAlignmentProblem) -> AlignmentObstacle {
        switch problem {
        case .systemTooOld: .systemTooOld
        case .languageUnsupported: .languageUnsupported
        case .modelUnavailable: .modelMissing
        case let .unreadable(reason): .failed(reason)
        }
    }
}

extension Int {
    fileprivate func clamped(to range: ClosedRange<Int>) -> Int {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
