// HanReader — MIT licensed. See LICENSE.

import AVFoundation
public import Foundation
public import HanReaderCore
import Speech

/// Why a recording could not be listened to.
public nonisolated enum SpeechAlignmentProblem: Error, Sendable, Equatable {
    /// This system is too old for `SpeechTranscriber`.
    ///
    /// The older `SFSpeechRecognizer` is deliberately not used instead. Its
    /// Chinese model arrives with the Dictation language, and on a managed
    /// Mac `allowDictation = false` forbids installing one — which is the
    /// case this feature most needs to work in. A second implementation that
    /// fails exactly where the first was needed is not a fallback.
    case systemTooOld
    /// The language is not one the system can transcribe at all.
    case languageUnsupported(String)
    /// The model is not installed and could not be fetched.
    case modelUnavailable(String)
    case unreadable(String)

    public var isRecoverableByInstalling: Bool {
        if case .modelUnavailable = self {
            return true
        }
        return false
    }
}

/// How far a recording has been listened to.
public nonisolated struct SpeechAlignmentProgress: Equatable, Sendable {
    /// Zero to one, or nil while the model is downloading and there is
    /// nothing yet to measure.
    public let fraction: Double?
    public let isInstallingModel: Bool

    public init(fraction: Double?, isInstallingModel: Bool = false) {
        self.fraction = fraction
        self.isInstallingModel = isInstallingModel
    }
}

/// Listens to a recording so a transcript can be placed in it.
///
/// ### It is not transcribing
///
/// The words are already known — the reader imported them. What this is for
/// is *timing*: `ForcedAlignment` lines the recogniser's output up against
/// the transcript, and the characters it got right carry the clock across
/// the ones it did not. A recogniser that is 80% accurate still places every
/// phrase.
///
/// ### Why `SpeechTranscriber` and not `SFSpeechRecognizer`
///
/// Measured on the machine this was built for, which is managed by an MDM
/// profile setting `allowDictation = false`:
///
/// - `SFSpeechRecognizer(locale: "zh-CN").supportsOnDeviceRecognition` is
///   **false**, and the system logs *No Assistant asset for language zh-CN*.
///   Its model ships with the Dictation language, and Dictation cannot be
///   switched on, so the language cannot be added. `en-US` and `ru-RU` report
///   true — they are the two assets that happen to be installed.
/// - Falling back to the network is refused outright, not merely avoided:
///   it would send the reader's own recordings to a server, in an app whose
///   whole premise is that it works offline, and server recognition is
///   capped at about a minute of audio anyway.
/// - `SpeechTranscriber` manages its own models and is not governed by that
///   restriction. On the same machine it reports zh-CN `supported` and
///   installs on request.
///
/// The cost is a floor of macOS 26 / iOS 26 for automatic alignment. Older
/// systems place phrases by hand instead, which is slower but never wrong.
@available(macOS 26.0, iOS 26.0, *)
public nonisolated struct SpeechAligner: Sendable {
    public let locale: Locale

    public init(locale: Locale = Locale(identifier: "zh-CN")) {
        self.locale = locale
    }

    /// Whether this language can be transcribed at all, before any work or
    /// any download is attempted.
    public func isLanguageSupported() async -> Bool {
        await SpeechTranscriber.supportedLocales.contains { $0.matches(locale) }
    }

    /// Whether the model is already on the device.
    public func isModelInstalled() async -> Bool {
        await SpeechTranscriber.installedLocales.contains { $0.matches(locale) }
    }

    /// Fetches the model, which on a managed Mac is the only route to one.
    ///
    /// Reserving it afterwards is what stops the system reclaiming it: there
    /// is a per-app allowance, and a model that evaporates would send the
    /// reader back to a download they have already done once.
    public func installModel(
        progress: @escaping @Sendable (Double) -> Void = { _ in },
    ) async throws {
        guard await isLanguageSupported() else {
            throw SpeechAlignmentProblem.languageUnsupported(locale.identifier)
        }
        guard let request = try await AssetInventory.assetInstallationRequest(
            supporting: [transcriber()],
        ) else {
            // Nothing to fetch: it is already here.
            _ = try? await AssetInventory.reserve(locale: locale)
            return
        }
        let tracked = request.progress
        let watcher = Task {
            while !Task.isCancelled, !tracked.isFinished {
                progress(tracked.fractionCompleted)
                try? await Task.sleep(for: .milliseconds(400))
            }
        }
        defer { watcher.cancel() }
        try await request.downloadAndInstall()
        _ = try? await AssetInventory.reserve(locale: locale)
    }

    /// Listens to a recording and reports what was heard, with timings.
    ///
    /// - Parameter installIfNeeded: fetch the model when it is missing.
    ///   Off by default, so nothing downloads hundreds of megabytes without
    ///   the reader having said so.
    public func listen(
        to url: URL,
        installIfNeeded: Bool = false,
        progress: @escaping @Sendable (SpeechAlignmentProgress) -> Void = { _ in },
    ) async throws
        -> RecognisedSpeech
    {
        guard await isLanguageSupported() else {
            throw SpeechAlignmentProblem.languageUnsupported(locale.identifier)
        }
        if await !isModelInstalled() {
            guard installIfNeeded else {
                throw SpeechAlignmentProblem.modelUnavailable(locale.identifier)
            }
            try await installModel { fraction in
                progress(SpeechAlignmentProgress(
                    fraction: fraction,
                    isInstallingModel: true,
                ))
            }
        }

        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw SpeechAlignmentProblem.unreadable(error.localizedDescription)
        }
        let duration = file.fileFormat.sampleRate > 0
            ? Double(file.length) / file.fileFormat.sampleRate
            : 0

        let module = transcriber()
        let analyzer = SpeechAnalyzer(modules: [module])
        _ = try await analyzer.analyzeSequence(from: file)
        try await analyzer.finalizeAndFinishThroughEndOfInput()

        var segments: [RecognisedSpeech.Segment] = []
        for try await result in module.results {
            try Task.checkCancellation()
            for run in result.text.runs {
                guard let range = run.audioTimeRange else { continue }
                segments.append(RecognisedSpeech.Segment(
                    text: String(result.text[run.range].characters),
                    start: range.start.seconds,
                    end: range.end.seconds,
                ))
            }
            if duration > 0, let last = segments.last {
                progress(SpeechAlignmentProgress(fraction: min(1, last.end / duration)))
            }
        }
        return RecognisedSpeech(segments: segments, duration: duration)
    }

    /// Timings are the whole point, so `.audioTimeRange` is the one option
    /// that is not optional. The transcriber hands back one run per
    /// character for Chinese — measured, not assumed: on a real recording a
    /// typical character spans 0.24 s and the first after a pause spans 1.8,
    /// which is what `ForcedAlignment` reads pauses out of.
    private func transcriber() -> SpeechTranscriber {
        SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: [.audioTimeRange],
        )
    }
}

extension Locale {
    /// Whether two locales name the same language and region.
    ///
    /// Compared on the language code rather than the identifier: the system
    /// lists `zh-CN` and a caller may hold `zh_CN` or `zh-Hans-CN`, and a
    /// string comparison would call those different languages.
    @available(macOS 26.0, iOS 26.0, *)
    fileprivate nonisolated func matches(_ other: Locale) -> Bool {
        language.languageCode == other.language.languageCode
            && language.region == other.language.region
    }
}
