// HanReader — MIT licensed. See LICENSE.

import Foundation
import HanReaderCore
import HanReaderPlayback

/// Working out where each phrase is said, which is what makes the rest of
/// the screen possible.
///
/// Split from the model's own file because it is a different concern with
/// its own failure modes — a model to download, a system too old, a
/// recording that cannot be read — and because the model was over the size
/// a class is allowed to be once the boundary editor arrived.
extension PracticeModel {
    /// Works out where each phrase is said, which is what makes any of the
    /// rest possible.
    func align(installingModel: Bool = false) {
        guard alignTask == nil else { return }
        alignGeneration += 1
        let generation = alignGeneration
        alignTask = Task { [weak self] in
            await self?.runAlignment(installingModel: installingModel, generation: generation)
            guard let self, generation == alignGeneration else { return }
            alignTask = nil
        }
    }

    func cancelAlignment() {
        alignTask?.cancel()
        alignTask = nil
        // Bumped so that whatever the stopped run does on its way out
        // belongs to a generation nobody is listening to any more.
        alignGeneration += 1
        phase = phrases.isEmpty ? .needsAlignment : .ready
    }

    private func runAlignment(installingModel: Bool, generation: Int) async {
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
        guard generation == alignGeneration else { return }
        phase = .aligning(SpeechAlignmentProgress(fraction: nil))

        do {
            let heard = try await aligner.listen(
                to: file,
                installIfNeeded: installingModel,
                progress: { [weak self] progress in
                    Task { @MainActor in self?.report(progress, from: generation) }
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
            // Checked again after the write, not only after the listening.
            // Stop pressed while the database was busy would otherwise let
            // the run finish and announce itself ready.
            try Task.checkCancellation()
            guard generation == alignGeneration else { return }
            phrases = try await services.library.phrases(for: textID)
            attempts = try await services.library.attempts(for: textID)
            current = firstUnfinished
            phase = .ready
        } catch is CancellationError {
            guard generation == alignGeneration else { return }
            phase = phrases.isEmpty ? .needsAlignment : .ready
        } catch let problem as SpeechAlignmentProblem {
            guard generation == alignGeneration else { return }
            phase = .unavailable(obstacle(for: problem))
        } catch {
            guard generation == alignGeneration else { return }
            phase = .unavailable(.failed(error.localizedDescription))
        }
    }

    private func report(_ progress: SpeechAlignmentProgress, from generation: Int) {
        guard generation == alignGeneration, case .aligning = phase else { return }
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
