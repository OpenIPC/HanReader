// HanReader — MIT licensed. See LICENSE.

import Testing
@testable import HanReaderUI

@Suite("Settings")
struct SettingsTests {
    @Test("Defaults are the prototype's, so a first launch looks the same")
    func defaults() {
        let settings = Settings(store: InMemorySettingsStore())
        #expect(settings.fontSize == Settings.defaultFontSize)
        #expect(settings.wordSpacing == .separated)
        // The prototype revealed every occurrence of a word, and fidelity
        // says out-of-the-box behaviour matches.
        #expect(settings.revealMode == .allOccurrences)
        #expect(settings.speaksOnTap)
        #expect(settings.pausesAudioWhileSpeaking)
    }

    @Test("Every setting is written through on change")
    func writesThrough() {
        let store = InMemorySettingsStore()
        let settings = Settings(store: store)

        settings.fontSize = 30
        settings.wordSpacing = .continuous
        settings.revealMode = .thisInstance
        settings.speaksOnTap = false
        settings.pausesAudioWhileSpeaking = false

        let reloaded = Settings(store: store)
        #expect(reloaded.fontSize == 30)
        #expect(reloaded.wordSpacing == .continuous)
        #expect(reloaded.revealMode == .thisInstance)
        #expect(!reloaded.speaksOnTap)
        #expect(!reloaded.pausesAudioWhileSpeaking)
    }

    @Test("A size outside the range is clamped as it is set")
    func clampsOnSet() {
        let settings = Settings(store: InMemorySettingsStore())
        settings.fontSize = 500
        #expect(settings.fontSize == ReaderStyle.fontSizeRange.upperBound)
        settings.fontSize = -10
        #expect(settings.fontSize == ReaderStyle.fontSizeRange.lowerBound)
    }

    /// Assigning inside `didSet` does not run `didSet` again — which is what
    /// keeps the clamp from recursing, and is also the trap. An early return
    /// after correcting the value leaves the corrected one unpersisted, so
    /// the clamp holds until the next launch and is then forgotten.
    @Test("A clamped size is the one that gets persisted")
    func clampedValueIsPersisted() {
        let store = InMemorySettingsStore()
        let settings = Settings(store: store)
        settings.fontSize = 500

        #expect(Settings(store: store).fontSize == ReaderStyle.fontSizeRange.upperBound)
    }

    /// A value read back can be anything: a previous build's range, a
    /// corrupted plist, something a developer typed into defaults. Clamping
    /// only where the value is used is clamping nowhere it is forgotten.
    @Test("A stored size outside the range is clamped on load")
    func clampsOnLoad() {
        let store = InMemorySettingsStore(["reader.fontSize": 999.0])
        #expect(Settings(store: store).fontSize == ReaderStyle.fontSizeRange.upperBound)
    }

    /// `UserDefaults.double(forKey:)` returns 0 for a key that was never
    /// written, and 0 is not a legal font size — so a reader who had never
    /// changed it would get the smallest text available.
    @Test("An absent size falls back to the default, not to zero")
    func absentKeyIsNotZero() {
        #expect(Settings(store: InMemorySettingsStore()).fontSize == Settings.defaultFontSize)
    }

    @Test("A stored value that is nonsense falls back to the default")
    func nonsenseStoredValues() {
        let store = InMemorySettingsStore([
            "reader.wordSpacing": "sideways",
            "reader.revealMode": "",
        ])
        let settings = Settings(store: store)
        #expect(settings.wordSpacing == .separated)
        #expect(settings.revealMode == .allOccurrences)
    }

    @Test("Stepping the size stays inside the range")
    func steppingIsClamped() {
        let settings = Settings(store: InMemorySettingsStore())

        for _ in 0 ..< 50 {
            settings.increaseFontSize()
        }
        #expect(settings.fontSize == ReaderStyle.fontSizeRange.upperBound)

        for _ in 0 ..< 50 {
            settings.decreaseFontSize()
        }
        #expect(settings.fontSize == ReaderStyle.fontSizeRange.lowerBound)
    }

    @Test("Stepping moves by one step")
    func steppingMovesOneStep() {
        let settings = Settings(store: InMemorySettingsStore())
        let start = settings.fontSize
        settings.increaseFontSize()
        #expect(settings.fontSize == start + Settings.fontSizeStep)
        settings.decreaseFontSize()
        #expect(settings.fontSize == start)
    }
}
