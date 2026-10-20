// HanReader — MIT licensed. See LICENSE.

import Foundation
import HanReaderCore
import Testing
@testable import HanReaderPlayback

/// What can be checked without a recording and without the model.
///
/// The parts that need both — that a real 147-second 听力 recording yields
/// per-character timings, and that slicing the audio at the resulting
/// boundaries re-transcribes to the same words — are verified by hand
/// against the reader's own material and reported in the pull request. A
/// test that downloaded a speech model would be a test that fails on a
/// fresh clone and on CI, which is worse than one that says what it covers.
@Suite("Speech aligner")
struct SpeechAlignerTests {
    /// Conditional on purpose. A headless CI runner reports *no* supported
    /// languages at all, so asserting Chinese outright asserts a fact about
    /// the machine rather than about the code — which is how this test first
    /// passed here and failed in CI.
    ///
    /// What *is* a fact about the code: wherever the system can transcribe
    /// anything, it can transcribe Chinese, because that is the language
    /// this app exists for and the one the availability check names.
    @Test("Where the system transcribes anything, Chinese is among it")
    func chineseIsSupportedWhereAnythingIs() async {
        guard #available(macOS 26.0, iOS 26.0, *) else { return }
        let languages = await SpeechAligner.supportedLanguages()
        guard !languages.isEmpty else { return }
        #expect(await SpeechAligner().isLanguageSupported())
    }

    /// A locale nobody speaks must be refused before any work is attempted,
    /// rather than producing an empty transcription that looks like silence.
    @Test("An unsupported language is refused up front")
    func unsupportedLanguage() async throws {
        guard #available(macOS 26.0, iOS 26.0, *) else { return }
        let aligner = SpeechAligner(locale: Locale(identifier: "xx-XX"))
        #expect(await aligner.isLanguageSupported() == false)

        await #expect(throws: SpeechAlignmentProblem.languageUnsupported("xx-XX")) {
            try await aligner.listen(to: URL(fileURLWithPath: "/dev/null"))
        }
    }

    /// A file that is not audio, or is not there, is the reader's mistake
    /// and has to come back as something the UI can show them.
    @Test("An unreadable recording reports itself as unreadable")
    func unreadableRecording() async throws {
        guard #available(macOS 26.0, iOS 26.0, *) else { return }
        let aligner = SpeechAligner()
        guard await aligner.isModelInstalled() else { return }

        let missing = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("not-there-\(UUID().uuidString).m4a")
        do {
            _ = try await aligner.listen(to: missing)
            Issue.record("expected a failure")
        } catch let problem as SpeechAlignmentProblem {
            guard case .unreadable = problem else {
                Issue.record("expected .unreadable, got \(problem)")
                return
            }
        }
    }

    /// Only a missing model is worth offering the reader a download for.
    /// Telling them to install something for a language that does not exist,
    /// or for a file that is not audio, would be a dead end dressed up as a
    /// remedy.
    @Test("Only a missing model is offered as installable")
    func recoverability() {
        #expect(SpeechAlignmentProblem.modelUnavailable("zh-CN").isRecoverableByInstalling)
        #expect(!SpeechAlignmentProblem.languageUnsupported("xx").isRecoverableByInstalling)
        #expect(!SpeechAlignmentProblem.unreadable("…").isRecoverableByInstalling)
        #expect(!SpeechAlignmentProblem.systemTooOld.isRecoverableByInstalling)
    }

    /// Nothing downloads hundreds of megabytes because a reader opened a
    /// text. The install is a thing they ask for.
    @Test("A missing model is reported rather than fetched unasked")
    func modelIsNotFetchedWithoutAsking() async throws {
        guard #available(macOS 26.0, iOS 26.0, *) else { return }
        // A language the system supports but is most unlikely to have
        // installed, so this exercises the refusal rather than the cache.
        let aligner = SpeechAligner(locale: Locale(identifier: "ko-KR"))
        guard await aligner.isLanguageSupported(), await !aligner.isModelInstalled() else {
            return
        }
        await #expect(throws: SpeechAlignmentProblem.modelUnavailable("ko-KR")) {
            try await aligner.listen(to: URL(fileURLWithPath: "/dev/null"))
        }
    }

    @Test("Progress distinguishes downloading from listening")
    func progressShape() {
        #expect(SpeechAlignmentProgress(fraction: 0.5).isInstallingModel == false)
        #expect(SpeechAlignmentProgress(fraction: nil, isInstallingModel: true).fraction == nil)
    }
}
