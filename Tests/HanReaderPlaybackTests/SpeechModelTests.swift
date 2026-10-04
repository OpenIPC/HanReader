// HanReader — MIT licensed. See LICENSE.

import AVFoundation
import Foundation
import Testing
@testable import HanReaderPlayback

@MainActor
@Suite("Speech")
struct SpeechModelTests {
    /// The check that matters on a fresh machine. A missing Chinese voice is
    /// common, and the prototype's response was to call `speak` into a
    /// synthesizer with no voice and have nothing happen, with nothing on
    /// screen to say why.
    @Test("A Chinese voice is found, or its absence is reported")
    func voiceStatusIsHonest() {
        let model = SpeechModel()
        switch model.voiceStatus {
        case let .available(identifier):
            #expect(!identifier.isEmpty)
        case .noChineseVoice:
            // Legitimate on a machine with no Chinese voice installed. The
            // point of the test is that the state is reported either way.
            #expect(SpeechModel.bestChineseVoice() == nil)
        }
    }

    @Test("Mainland Mandarin is preferred over the other Chinese voices")
    func prefersMainland() throws {
        let voices = AVSpeechSynthesisVoice.speechVoices()
        let languages = Set(voices.map(\.language))
        try #require(languages.contains { $0.hasPrefix("zh-CN") }, "no zh-CN voice installed")

        let chosen = try #require(SpeechModel.bestChineseVoice())
        #expect(chosen.language.hasPrefix("zh-CN"))
    }

    /// Identifiers are not stable across OS versions, so matching on one
    /// would be a feature that stops working at some future update for no
    /// visible reason. Matching on the language prefix is what makes this
    /// survive.
    @Test("Selection is by language, not by a hard-coded identifier")
    func matchesByLanguage() throws {
        let synthetic = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("zh") }
        try #require(!synthetic.isEmpty, "no Chinese voice installed")

        let chosen = try #require(SpeechModel.bestChineseVoice(from: synthetic))
        #expect(chosen.language.hasPrefix("zh"))
    }

    @Test("No Chinese voice at all is handled rather than crashing")
    func noChineseVoices() {
        let english = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("en") }
        #expect(SpeechModel.bestChineseVoice(from: english) == nil)
        #expect(SpeechModel.bestChineseVoice(from: []) == nil)
    }

    /// VoiceOver announces the token itself the moment it takes focus, so
    /// speaking as well says the word twice, over itself, in two different
    /// voices.
    @Test("Speaking is suppressed under VoiceOver")
    func suppressedUnderVoiceOver() {
        let model = SpeechModel()
        model.speak("中国", suppressed: true)
        #expect(!model.isSpeaking)
    }

    @Test("An empty word is not spoken")
    func emptyIsIgnored() {
        let model = SpeechModel()
        model.speak("")
        #expect(!model.isSpeaking)
    }

    @Test("A word is read more slowly than prose")
    func rateIsSlower() {
        // The reader is listening to one word in a language they are
        // learning, not to a paragraph in one they know.
        #expect(SpeechModel.rate < AVSpeechUtteranceDefaultSpeechRate)
        #expect(SpeechModel.rate > AVSpeechUtteranceMinimumSpeechRate)
    }

    @Test("Mainland Mandarin comes before the other Chinese languages")
    func preferenceOrder() {
        #expect(SpeechModel.preferredLanguages.first == "zh-CN")
        #expect(SpeechModel.preferredLanguages.contains("zh-TW"))
        // A bare `zh` last, so an unusual Chinese voice is still better than
        // silence -- the reader can hear that it is wrong, whereas nothing
        // happening is indistinguishable from a broken app.
        #expect(SpeechModel.preferredLanguages.last == "zh")
    }
}
