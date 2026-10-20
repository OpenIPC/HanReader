// HanReader — MIT licensed. See LICENSE.

#if os(macOS)
    import AppKit
#endif

/// Asking the system for a Chinese input source while a field is being typed
/// into.
///
/// Listening practice is the one screen in the app where every keystroke is
/// meant to be Chinese. Leaving the learner to switch input source themselves
/// means doing it on the way in and again on the way out, every sentence, and
/// discovering they forgot only once the answer has been typed in Latin
/// letters and marked wrong.
///
/// ### Asking, not forcing
///
/// `allowedInputSourceLocales` is a *request*: the system honours it when the
/// learner has a matching input source installed, and does nothing when they
/// have not. That is the right shape — an app that could force an input
/// source could also strand somebody with no way to type their own language —
/// and it is why this reports nothing back. There is no failure here to
/// handle, only a preference the system may or may not act on.
public enum ChineseInput {
    /// The locale to prefer. Simplified, matching the dictionary the app
    /// bundles and the transcripts it is built for.
    public static let locale = "zh-Hans"

    /// Prefers a Chinese input source for whatever is being typed into now.
    ///
    /// Call it as the writing field takes focus. The preference belongs to
    /// the focused field's input context, so it lasts as long as that field
    /// is first responder and the system restores the learner's own choice
    /// afterwards.
    public static func prefer() {
        #if os(macOS)
            NSTextInputContext.current?.allowedInputSourceLocales = [locale]
        #endif
    }

    /// Gives the choice back, for a field that is no longer the exercise.
    public static func clearPreference() {
        #if os(macOS)
            NSTextInputContext.current?.allowedInputSourceLocales = nil
        #endif
    }
}
