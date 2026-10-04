// HanReader — MIT licensed. See LICENSE.

public import AVFoundation
import Foundation
import HanReaderCore
import Observation

/// Whether a Chinese voice is available to speak with.
public enum SpeechVoiceStatus: Equatable, Sendable {
    /// A voice was found. Carries its identifier for diagnostics.
    case available(String)
    /// No Chinese voice is installed.
    ///
    /// Common on a fresh Mac, and the reason this is a state rather than a
    /// silent failure: the prototype called `speak` into a synthesizer with
    /// no voice and nothing happened, with nothing on screen to say why.
    case noChineseVoice
}

/// Speaks a word aloud.
///
/// Deliberately small. Tapping a word is the app's primary interaction and
/// hearing it is half the point, so the only operations are "say this" and
/// "stop".
@Observable
@MainActor
public final class SpeechModel {
    /// The languages to look for, in order.
    ///
    /// Mainland first because the dictionary's readings are Putonghua, then
    /// Taiwan, then anything Chinese at all. A Cantonese voice reading
    /// Mandarin pinyin is wrong, but it is far better than silence and the
    /// reader can hear that it is wrong — whereas nothing happening is
    /// indistinguishable from a broken app.
    public static let preferredLanguages = ["zh-CN", "zh-TW", "zh-HK", "zh"]

    public private(set) var isSpeaking = false
    public private(set) var voiceStatus: SpeechVoiceStatus

    /// Set the first time speaking is attempted with no voice installed.
    ///
    /// Raised on the attempt rather than at launch: a reader who never taps
    /// a word does not need to be told about a voice they were not going to
    /// use. Cleared by `acknowledgeMissingVoice()` and not raised again, so
    /// it is a notice rather than a nag.
    public private(set) var needsVoiceNotice = false
    private var hasGivenVoiceNotice = false

    private let synthesizer: AVSpeechSynthesizer
    private let voice: AVSpeechSynthesisVoice?
    private let observer = SpeechObserver()

    /// Rate for a single word.
    ///
    /// Below the default, because the reader is listening to one word in a
    /// language they are learning, not to a paragraph in one they know.
    public static let rate = AVSpeechUtteranceDefaultSpeechRate * 0.85

    public init(synthesizer: AVSpeechSynthesizer = AVSpeechSynthesizer()) {
        self.synthesizer = synthesizer
        voice = Self.bestChineseVoice()
        voiceStatus = voice.map { .available($0.identifier) } ?? .noChineseVoice
        observer.onChange = { [weak self] speaking in
            self?.isSpeaking = speaking
        }
        synthesizer.delegate = observer

        if voice == nil {
            Log.error("speech", "no Chinese voice is installed")
        }
    }

    /// Speaks a word.
    ///
    /// - Parameter suppressed: pass true when VoiceOver is running.
    ///   VoiceOver announces the token itself the moment it takes focus, so
    ///   speaking as well says the word twice, over itself, in two different
    ///   voices. The caller decides because only the view knows.
    public func speak(_ text: String, suppressed: Bool = false) {
        guard !suppressed, !text.isEmpty else { return }
        guard let voice else {
            // The prototype's behaviour here was nothing at all, which is
            // indistinguishable from a broken app — and a Mac with no
            // Chinese voice installed is the common case, not an exotic one.
            if !hasGivenVoiceNotice {
                hasGivenVoiceNotice = true
                needsVoiceNotice = true
            }
            return
        }

        // Stopped rather than queued. Tapping along a sentence should say
        // each word as it is tapped, not read back the whole trail of them
        // several seconds later.
        synthesizer.stopSpeaking(at: .immediate)

        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        utterance.rate = Self.rate
        synthesizer.speak(utterance)
        isSpeaking = true
    }

    public func acknowledgeMissingVoice() {
        needsVoiceNotice = false
    }

    public func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        isSpeaking = false
    }

    /// The best Chinese voice installed, or nil.
    ///
    /// Matched on the language prefix rather than on an exact identifier,
    /// because voice identifiers are not stable across OS versions and a
    /// hard-coded one is a feature that stops working at some future update
    /// for no visible reason.
    static func bestChineseVoice(
        from voices: [AVSpeechSynthesisVoice] = AVSpeechSynthesisVoice.speechVoices(),
    )
        -> AVSpeechSynthesisVoice?
    {
        for language in preferredLanguages {
            let matches = voices.filter {
                $0.language == language || $0.language.hasPrefix("\(language)-")
            }
            // Enhanced and premium voices sound markedly better and are
            // worth preferring when the reader has downloaded one.
            if let best = matches.max(by: { $0.quality.rawValue < $1.quality.rawValue }) {
                return best
            }
        }
        return nil
    }
}

/// Bridges the synthesizer's delegate callbacks onto the main actor.
///
/// A separate object because `AVSpeechSynthesizerDelegate` is an
/// Objective-C protocol whose callbacks carry no isolation guarantee, so the
/// model cannot conform to it directly without lying about where its state
/// is touched.
private final class SpeechObserver: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    var onChange: (@MainActor (Bool) -> Void)?

    func speechSynthesizer(_: AVSpeechSynthesizer, didStart _: AVSpeechUtterance) {
        notify(true)
    }

    func speechSynthesizer(_: AVSpeechSynthesizer, didFinish _: AVSpeechUtterance) {
        notify(false)
    }

    func speechSynthesizer(_: AVSpeechSynthesizer, didCancel _: AVSpeechUtterance) {
        notify(false)
    }

    private func notify(_ speaking: Bool) {
        let onChange = onChange
        Task { @MainActor in onChange?(speaking) }
    }
}
