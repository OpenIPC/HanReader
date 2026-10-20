// HanReader — MIT licensed. See LICENSE.

import Foundation
import HanReaderCore
import HanReaderPlayback

/// Placing phrase boundaries by hand.
///
/// Two ways in, for two different situations:
///
/// - **Correcting one boundary**, which is what forced alignment leaves
///   behind: it is right most of the time and wrong in a way the reader can
///   hear, a syllable late, so the next phrase opens with the tail of the
///   last word. That is a drag on a waveform.
/// - **Placing all of them**, for a Mac too old for `SpeechTranscriber` or a
///   system with no Chinese speech at all. The text is split into phrases
///   with no times worth having, the recording plays once, and the reader
///   presses a key as each phrase begins. A few dozen lines, always exactly
///   right, and the same editor repairs it afterwards.
extension PracticeModel {
    /// Where the reader is up to while tapping boundaries in.
    struct TapAlong: Equatable {
        /// The phrase whose start the next tap places. Counting from one,
        /// because the first phrase starts where the recording does and
        /// needs no tap.
        var next: Int

        /// Whether every boundary has been placed.
        func isFinished(of count: Int) -> Bool {
            next >= count
        }
    }

    // MARK: - The waveform

    /// Opens the editor, reading the recording's shape the first time.
    ///
    /// Read on demand rather than at load: it is tens of millions of samples
    /// for a file most readers never edit, and the practice screen is
    /// useful long before the waveform is.
    func startEditing() {
        isEditing = true
        // Opening the editor shows the phrase, because a boundary cannot be
        // placed without knowing which words it is meant to contain. That
        // counts as having looked, exactly as "Show the answer" does, and
        // saying so is better than letting a reader peek through a side
        // door.
        reveal()
        guard peaks.isEmpty, waveformTask == nil else { return }
        guard let file = audioFile else { return }
        isReadingWaveform = true
        waveformTask = Task { [weak self] in
            let read = try? await WaveformReader.peaks(of: file)
            guard let self, !Task.isCancelled else { return }
            peaks = read ?? .empty
            isReadingWaveform = false
            waveformTask = nil
        }
    }

    func stopEditing() {
        isEditing = false
        cancelTapAlong()
    }

    /// The span of recording the editor draws, around the phrase being
    /// edited.
    var editorWindow: Range<Double> {
        guard let phrase else { return 0 ..< max(playback.duration, 1) }
        return BoundaryEditing.window(
            around: phrase,
            duration: max(playback.duration, phrase.end),
        )
    }

    // MARK: - Dragging a boundary

    /// Moves one end of the current phrase, and the neighbour that shares
    /// it.
    ///
    /// Written straight through to the library rather than held and saved
    /// on close: a drag is the whole edit, there is nothing to confirm, and
    /// a correction lost because a sheet was dismissed is a correction the
    /// reader makes twice.
    func move(_ boundary: PhraseBoundary, to time: Double) async {
        guard let phrase else { return }
        let moved = BoundaryEditing.move(
            boundary,
            of: phrase.index,
            to: time,
            in: phrases,
            duration: recordingLength,
        )
        await save(moved)
    }

    func apply(_ moved: [Phrase]) {
        var byIndex = Dictionary(uniqueKeysWithValues: moved.map { ($0.index, $0) })
        phrases = phrases.map { byIndex.removeValue(forKey: $0.index) ?? $0 }
    }

    /// Plays just the phrase being edited, so a boundary can be judged by
    /// ear rather than by eye.
    func playSpan() {
        guard let phrase else { return }
        playback.play(segment: phrase.audioRange, drill: .once)
    }

    // MARK: - Tapping the boundaries in

    /// Splits the text into phrases with no times worth having, so there is
    /// something to tap against.
    ///
    /// Equal slices, confidence zero — which is exactly what tells the
    /// screen these are placeholders rather than answers.
    func splitWithoutListening() async {
        guard !content.isEmpty else { return }
        let duration = max(playback.duration, 1)
        let splitting = PhraseSplitting.forAudio(
            characters: content.count,
            duration: duration,
        )
        let ranges = PhraseSplitter.phrases(in: content, splitting: splitting)
        do {
            try await services.library.savePhrases(
                ForcedAlignment.spread(ranges, across: duration),
                for: textID,
            )
            phrases = try await services.library.phrases(for: textID)
            attempts = try await services.library.attempts(for: textID)
            current = phrases.first?.index ?? 0
            phase = phrases.isEmpty ? .needsAlignment : .ready
            // Through `startEditing` rather than setting the flag, or the
            // editor opens on a flat line: reading the recording's shape is
            // part of opening it, and placeholders are the one case where
            // there is nothing to do until the shape is on screen.
            startEditing()
        } catch {
            Log.error("practice", "could not split without listening: \(error)")
            phase = .unavailable(.failed(error.localizedDescription))
        }
    }

    /// Starts the recording from the top, ready to be tapped through.
    func beginTapAlong() {
        guard phrases.count > 1 else { return }
        tapping = TapAlong(next: 1)
        select(phrases[0].index)
        playback.clearSegment()
        playback.seek(to: 0)
        playback.play()
    }

    /// Marks the start of the next phrase at wherever the recording is now.
    ///
    /// The tap also closes the phrase before it, because that is what the
    /// reader means: a boundary is the line between two phrases, not two
    /// separate facts. The phrases after it are left where they are and
    /// pushed out of the way only as far as the rules require, so a reader
    /// who taps a few and stops still has a usable text.
    func tapBoundary() async {
        // Through `upcoming` rather than indexing again: the bound belongs
        // in one place, and that place is already the one the screen shows
        // the reader.
        guard var tapping, let next = upcoming else { return }
        let time = playback.playhead
        // Advanced before the write, not after it. Each Mark starts its own
        // task, and two presses either side of a database round trip would
        // otherwise both read the same upcoming phrase and place the same
        // boundary twice — losing one of them.
        tapping.next += 1
        self.tapping = tapping.isFinished(of: phrases.count) ? nil : tapping
        select(phrases[min(tapping.next, phrases.count) - 1].index)
        await save(BoundaryEditing.place(
            boundaryBefore: next.index,
            at: time,
            in: phrases,
            duration: recordingLength,
        ))
    }

    /// How long the recording is, as far as anything here knows.
    ///
    /// The transport's own figure, or the end of the last phrase when it
    /// has not learnt one yet — which is the case in a test, and briefly at
    /// launch.
    var recordingLength: Double {
        max(playback.duration, phrases.last?.end ?? 0)
    }

    /// Applies moved phrases and writes them down.
    func save(_ moved: [Phrase]) async {
        guard !moved.isEmpty else { return }
        // Applied locally first, so the strip follows the drag rather than
        // the database round trip.
        apply(moved)
        do {
            for phrase in moved {
                try await services.library.movePhrase(
                    phrase.index,
                    in: textID,
                    start: phrase.start,
                    end: phrase.end,
                    confidence: phrase.confidence,
                    // Carried through rather than assumed: everything a
                    // reader places is `manual`, and the phrases shuffled
                    // along behind them are not.
                    origin: phrase.origin,
                )
            }
        } catch {
            Log.error("practice", "could not place a boundary: \(error)")
            // The screen was updated before the write, so a failure has to
            // take it back. Leaving the moved boundary on display would tell
            // the reader their correction was kept, and it would be gone the
            // next time they opened the text.
            phrases = await (try? services.library.phrases(for: textID)) ?? phrases
        }
    }

    /// Stopping needs no tidying up. Every tap leaves the text consistent,
    /// so there is never a run of stubs piled up behind the playhead to
    /// repair — and the repair that used to happen here was what let a
    /// reader who opened tapping and stopped at once have a good alignment
    /// replaced with equal slices.
    func cancelTapAlong() {
        guard tapping != nil else { return }
        playback.pause()
        tapping = nil
    }

    /// The phrase whose start the next tap places.
    var upcoming: Phrase? {
        guard let tapping, tapping.next < phrases.count else { return nil }
        return phrases[tapping.next]
    }

    // MARK: - Where the recording is

    var audioFile: URL? {
        guard let track = audioTrack else { return nil }
        return AudioAttachment.file(for: track, in: services.locations)
    }
}
