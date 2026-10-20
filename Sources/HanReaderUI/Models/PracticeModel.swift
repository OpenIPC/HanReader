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

    // Settable from this module rather than `private(set)`, because this
    // type's implementation spans files — `private` in Swift reaches
    // extensions in the *same* file only — and the boundary editor lives in
    // one of them. Nothing outside the module can see any of it.
    var phase: Phase = .noAudio
    var phrases: [Phrase] = []
    var attempts: [Int: DictationAttempt] = [:]
    var current = 0
    /// The last check, or nil if this phrase has not been answered yet.
    private(set) var result: DictationResult?
    /// Whether the transcript is on screen. Off until checked, because the
    /// answer being visible is the one thing that makes dictation worthless.
    private(set) var isRevealed = false

    var typed = ""
    var filter: Filter = .all
    var drill = PlaybackModel.Drill.once

    /// Whether the boundary editor is open.
    var isEditing = false
    /// The recording's shape, read once the editor is first opened.
    var peaks = WaveformPeaks.empty
    var isReadingWaveform = false
    /// Where the reader is up to when tapping boundaries in by hand, or nil
    /// when they are not.
    var tapping: TapAlong?

    let textID: TextID
    let services: AppServices
    let playback: PlaybackModel
    private(set) var content = ""
    /// The narration, kept so the boundary editor can find the file without
    /// going back to the database for it.
    var audioTrack: AudioTrack?
    var alignTask: Task<Void, Never>?
    /// Where the narration was before practice took the transport over.
    var resumeAt: Double?
    /// Which alignment run is the current one.
    ///
    /// A cancelled task keeps running until its next suspension point, and
    /// its callbacks can still fire. Without a way to tell runs apart, a
    /// stopped run finishing late can clear the handle of the run that
    /// replaced it — leaving a second alignment going that nothing can
    /// stop.
    var alignGeneration = 0
    /// Internal rather than private because this type's implementation spans
    /// files, and `private` in Swift reaches extensions in the *same* file
    /// only.
    var waveformTask: Task<Void, Never>?

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
            audioTrack = track
            let file = AudioAttachment.file(for: track, in: services.locations)
            guard FileManager.default.fileExists(atPath: file.path) else {
                phase = .noAudio
                return
            }
            // Where the reader was in the narration, so closing practice
            // can put it back. Loading parks the playhead at zero, and the
            // reader's own position is a resume point they did not ask to
            // lose because they opened a different screen.
            resumeAt = playback.playhead
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
        waveformTask?.cancel()
        waveformTask = nil
        tapping = nil
        playback.pause()
        playback.clearSegment()
        if let resumeAt {
            playback.seek(to: resumeAt)
        }
    }

    /// The first phrase not yet passed, so reopening a text resumes rather
    /// than starting the reader at the top of something half done.
    var firstUnfinished: Int {
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
        // Paused before the segment is cleared, not after. Clearing it
        // removes the stop time, so a transport left running would sail
        // past the phrase it was playing and on into the next one, while
        // the screen showed a different phrase entirely.
        playback.pause()
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
        // Read before the await, not after it. The reader can keep typing,
        // or move to another phrase, while the dictionary is being asked —
        // and marking the answer they have now against the phrase they had
        // then would save a score under the wrong sentence.
        let expected = text
        let answer = typed
        // Whether they had already looked. Taken here for the same reason.
        let hadLooked = isRevealed
        // Fetched before marking rather than during it. `check` is a pure
        // function over a synchronous lookup, which is what makes it
        // testable without a database — so the asynchronous part happens
        // here, once, for every character either side might need.
        let readings = await services.dictionary.readings(
            forCharacters: Array(expected) + Array(answer),
        )
        guard current == phrase.index else { return }
        let outcome = DictationComparison.check(
            typed: answer,
            against: expected,
            readings: { readings[$0] ?? [] },
        )
        result = outcome
        isRevealed = true
        // A reader who showed the answer and then copied it has not
        // demonstrated anything about their listening, and recording a pass
        // would drop the phrase out of the drill on the strength of it.
        // They still see the marking — that is what they asked for.
        guard !hadLooked else { return }
        do {
            try await services.library.recordAttempt(
                answer,
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
}

extension Int {
    fileprivate func clamped(to range: ClosedRange<Int>) -> Int {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
