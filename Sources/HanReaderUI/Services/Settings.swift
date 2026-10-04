// HanReader — MIT licensed. See LICENSE.

import Foundation
import HanReaderCore

/// Somewhere small values persist between launches.
///
/// A protocol rather than `UserDefaults` directly, so that a test can run
/// against a dictionary in memory instead of leaving keys behind in the
/// suite's real defaults — which is how settings tests start passing or
/// failing depending on what ran before them.
protocol SettingsStore: AnyObject {
    func double(forKey key: String) -> Double?
    func bool(forKey key: String) -> Bool?
    func string(forKey key: String) -> String?
    func set(_ value: Double, forKey key: String)
    func set(_ value: Bool, forKey key: String)
    func set(_ value: String, forKey key: String)
}

extension UserDefaults: SettingsStore {
    func double(forKey key: String) -> Double? {
        // `UserDefaults.double(forKey:)` returns 0 for a key that was never
        // written, which is indistinguishable from a stored 0 — and 0 is not
        // a legal font size, so an absent key would silently become the
        // smallest text the reader can have.
        object(forKey: key) as? Double
    }

    func bool(forKey key: String) -> Bool? {
        object(forKey: key) as? Bool
    }

    func string(forKey key: String) -> String? {
        object(forKey: key) as? String
    }

    func set(_ value: Double, forKey key: String) {
        set(value as Any?, forKey: key)
    }

    func set(_ value: Bool, forKey key: String) {
        set(value as Any?, forKey: key)
    }

    func set(_ value: String, forKey key: String) {
        set(value as Any?, forKey: key)
    }
}

/// How revealing a word behaves.
enum RevealMode: String, CaseIterable, Sendable, Hashable {
    /// Reveal every occurrence of the word in the text.
    ///
    /// The default, because it is what the prototype did and fidelity says
    /// out-of-the-box behaviour should match. The difference is that it is
    /// now a property of the *word* with selection tracked separately, so
    /// tapping a second instance selects it rather than appearing to do
    /// nothing.
    case allOccurrences
    /// Reveal only the word that was tapped.
    ///
    /// Session-only. The store keys revealed words on `(text, word)`, so
    /// there is nowhere to record *which* 的 was revealed — and writing the
    /// word instead would light up every occurrence on reopening, which is
    /// the opposite of what this mode is for. Persisting per-instance
    /// reveals needs a schema change, and is not worth one until somebody
    /// asks for it.
    case thisInstance
}

/// The reader's preferences.
///
/// ### Why this is not `@AppStorage`
///
/// `@AppStorage` is a `DynamicProperty`. It works in a `View` and nowhere
/// else: inside a class it writes through to defaults but does not reliably
/// publish, so a change made here would persist and the interface would not
/// move. Under `@Observable` it stops publishing entirely. The failure is
/// silent, intermittent and looks like a SwiftUI bug, so the box is
/// hand-rolled instead — each property writes through in its own `didSet` and
/// `@Observable` handles the notifications.
///
/// Clamping happens in the setter, not at the point of use. A value read back
/// from defaults can be anything — a previous build's range, a corrupted
/// plist, a value a developer typed — and a setting that is clamped only
/// where it is read is a setting that is unclamped everywhere it is forgotten.
@Observable
final class Settings {
    private let store: any SettingsStore

    var fontSize: Double {
        didSet {
            // Assigning inside `didSet` does not run `didSet` again, which is
            // what makes this safe from recursion -- and is also the trap:
            // an early return after correcting the value would leave the
            // corrected one unpersisted, so the clamp would hold until the
            // next launch and then be forgotten. Store unconditionally.
            let clamped = fontSize.clamped(to: ReaderStyle.fontSizeRange)
            if clamped != fontSize {
                fontSize = clamped
            }
            store.set(clamped, forKey: Key.fontSize)
        }
    }

    var wordSpacing: WordSpacing {
        didSet { store.set(wordSpacing.rawValue, forKey: Key.wordSpacing) }
    }

    var revealMode: RevealMode {
        didSet { store.set(revealMode.rawValue, forKey: Key.revealMode) }
    }

    /// Whether tapping a word speaks it.
    ///
    /// Honoured only when VoiceOver is off: VoiceOver announces the token on
    /// focus, and speaking as well says the word twice, over itself, in two
    /// different voices.
    var speaksOnTap: Bool {
        didSet { store.set(speaksOnTap, forKey: Key.speaksOnTap) }
    }

    /// Whether playing audio pauses while a word is spoken.
    ///
    /// On by default: for this app the attached audio is usually the *same*
    /// narration, so hearing both at once is actively confusing rather than
    /// merely noisy.
    var pausesAudioWhileSpeaking: Bool {
        didSet { store.set(pausesAudioWhileSpeaking, forKey: Key.pausesAudioWhileSpeaking) }
    }

    init(store: any SettingsStore = UserDefaults.standard) {
        self.store = store
        fontSize = (store.double(forKey: Key.fontSize) ?? Self.defaultFontSize)
            .clamped(to: ReaderStyle.fontSizeRange)
        wordSpacing = store.string(forKey: Key.wordSpacing)
            .flatMap(WordSpacing.init(rawValue:)) ?? .separated
        revealMode = store.string(forKey: Key.revealMode)
            .flatMap(RevealMode.init(rawValue:)) ?? .allOccurrences
        speaksOnTap = store.bool(forKey: Key.speaksOnTap) ?? true
        pausesAudioWhileSpeaking = store.bool(forKey: Key.pausesAudioWhileSpeaking) ?? true
    }

    /// The prototype's reading size, kept as the default because it is a good
    /// one and because changing it would change every stored layout.
    static let defaultFontSize = 22.0

    /// Step for ⌘+ and ⌘−.
    static let fontSizeStep = 2.0

    func increaseFontSize() {
        fontSize += Self.fontSizeStep
    }

    func decreaseFontSize() {
        fontSize -= Self.fontSizeStep
    }

    /// Prefixed, so that a key cannot collide with one written by a framework
    /// or by a future setting with an obvious name.
    private enum Key {
        static let fontSize = "reader.fontSize"
        static let wordSpacing = "reader.wordSpacing"
        static let revealMode = "reader.revealMode"
        static let speaksOnTap = "reader.speaksOnTap"
        static let pausesAudioWhileSpeaking = "reader.pausesAudioWhileSpeaking"
    }
}

/// A settings store in memory, for tests and previews.
final class InMemorySettingsStore: SettingsStore {
    private var values: [String: Any] = [:]

    init(_ values: [String: Any] = [:]) {
        self.values = values
    }

    func double(forKey key: String) -> Double? {
        values[key] as? Double
    }

    func bool(forKey key: String) -> Bool? {
        values[key] as? Bool
    }

    func string(forKey key: String) -> String? {
        values[key] as? String
    }

    func set(_ value: Double, forKey key: String) {
        values[key] = value
    }

    func set(_ value: Bool, forKey key: String) {
        values[key] = value
    }

    func set(_ value: String, forKey key: String) {
        values[key] = value
    }
}
