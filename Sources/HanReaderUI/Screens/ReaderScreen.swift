// HanReader — MIT licensed. See LICENSE.

import HanReaderCore
import HanReaderPlayback
import SwiftUI

/// One open text.
///
/// The model is created and destroyed by `.task(id:)`, so opening another
/// text discards this one along with everything it had in flight. That is
/// the document scope the architecture calls for, and it is why there is no
/// reset code here: there is nothing to reset.
struct ReaderScreen: View {
    let textID: TextID
    /// For the transport and the lock screen. Passed in rather than queried:
    /// the sidebar already has it, and a second read to label a control the
    /// reader is looking at is a read too many.
    let title: String
    let services: AppServices
    let settings: Settings
    let speech: SpeechModel
    /// Scene-scoped, so one window's narration is not another's. Passed in
    /// rather than owned here: a model created per text would stop and
    /// restart the transport every time the reader changed the font size.
    let playback: PlaybackModel
    let nowPlaying: NowPlayingController

    /// Changes when the dictionaries do, so the model — which caches
    /// readings and definitions — is rebuilt against the new ones.
    let dictionaryGeneration: Int

    @State private var model: ReaderModel?
    @State private var isInspectorPresented = false
    @State private var isAudioImporterPresented = false
    @State private var isPractising = false
    /// Whether this text has a narration, which decides whether the
    /// transport is on screen at all.
    @State private var hasAudio = false
    /// What was last written, so a periodic flush can tell whether anything
    /// has moved since.
    @State private var lastSavedPlayhead = 0.0

    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var sizeClass

    /// Dynamic Type as a number. `DynamicTypeSize` is an ordered enum with
    /// no numeric value, and `@ScaledMetric` on a round number is the only
    /// way to read the real multiplier rather than inventing a table.
    @ScaledMetric(relativeTo: .body) private var textScaleProbe = 100.0

    private var style: ReaderStyle {
        ReaderStyle(
            fontSize: settings.fontSize,
            spacing: settings.wordSpacing,
            textScale: textScaleProbe / 100,
            minimumFontSize: sizeClass == .compact
                ? ReaderStyle.compactFontSizeFloor
                : ReaderStyle.fontSizeRange.lowerBound,
        )
    }

    var body: some View {
        content
            .task(id: Reading(text: textID, dictionaries: dictionaryGeneration)) {
                // The previous model is closed before the next is built.
                // `.task(id:)` cancels its own task when the id changes, but
                // the unstructured work the model holds -- the debounced
                // position save, the reading window, the detail lookup --
                // has no relationship to it, so switching texts in the
                // sidebar would leave the old text's work running and its
                // position unwritten.
                if let previous = model {
                    // The playhead belongs to the text that is leaving, and
                    // `textID` is already the one arriving — so the id comes
                    // from the outgoing model. Without this, changing text in
                    // the sidebar lost the playhead silently, which is the
                    // prototype's behaviour this milestone exists to fix.
                    await savePlayhead(for: previous.textID)
                    await previous.close()
                }
                speech.stop()
                let next = ReaderModel(
                    textID: textID,
                    services: services,
                    settings: settings,
                )
                model = next
                await next.load()
                await loadAudio(for: next)
            }
            .onDisappear {
                // An utterance outlives the view that started it: the
                // synthesizer is app-scoped, so without this a word spoken
                // in one text carries on into the next.
                speech.stop()
                // Read before unloading, which resets it.
                let outgoing = textID
                let model = model
                // The transport is scene-scoped but the track is not: the
                // next text has its own, and a lock screen still naming the
                // last one is worse than an empty one.
                let pending = pendingPlayhead()
                playback.unload()
                nowPlaying.detach()
                Task {
                    await write(pending, for: outgoing)
                    await model?.close()
                }
            }
            .onChange(of: scenePhase) { _, phase in
                // The position save is debounced, so going to the background
                // with one in flight loses it. On iOS the app may not be
                // running again afterwards to write it.
                guard phase != .active, let model else { return }
                let pending = pendingPlayhead()
                let id = textID
                Task {
                    await model.flushPosition()
                    await write(pending, for: id)
                }
            }
            // The playhead is written while the reader is using the app, not
            // only when they leave it. macOS delivers neither a scene-phase
            // change nor `onDisappear` reliably on quit, so a transport that
            // saved only on teardown saved nothing at all — which is exactly
            // the prototype's bug wearing a different hat.
            .onChange(of: playback.isPlaying) { _, playing in
                guard !playing else { return }
                // Read now, written later. A task that read the playhead when
                // it ran could find the shared transport already loaded with
                // another text's narration, and write that position under
                // this text's id.
                let pending = pendingPlayhead()
                let id = textID
                Task { await write(pending, for: id) }
            }
            .onChange(of: playback.observedTime) { _, time in
                // And periodically while playing, so quitting mid-sentence
                // costs seconds rather than the session. `observedTime` is
                // already throttled to once a second, so this is a comparison
                // once a second and a write once a minute.
                guard playback.isPlaying,
                      abs(time - lastSavedPlayhead) >= Self.playheadSaveInterval
                else { return }
                lastSavedPlayhead = time
                let id = textID
                Task { await write(time, for: id) }
            }
            .onChange(of: speech.isSpeaking) { _, speaking in
                // Resumed when the utterance ends rather than after a guessed
                // delay. `resumeAfterSpeech` only acts if it was this that
                // paused the audio, so a reader who had already paused it
                // does not find it playing again.
                if !speaking, settings.pausesAudioWhileSpeaking {
                    playback.resumeAfterSpeech()
                }
            }
            .fileImporter(
                isPresented: $isAudioImporterPresented,
                allowedContentTypes: AudioAttachment.contentTypes,
            ) { result in
                switch result {
                case let .success(url):
                    Task { await attachAudio(url) }
                case let .failure(error):
                    hasAudio = true
                    playback.fail(error.localizedDescription)
                }
            }
            .toolbar { toolbar }
            // A sheet rather than a mode of the reader. Practice hides the
            // text, which is the opposite of what the reader is for, and
            // the two sharing a surface would mean every change to one
            // reasoning about the other.
            .sheet(isPresented: $isPractising) {
                PracticeSheet(
                    textID: textID,
                    title: title,
                    services: services,
                    playback: playback,
                    style: style,
                )
            }
            .alert(
                "No Chinese voice is installed",
                isPresented: Binding(
                    get: { speech.needsVoiceNotice },
                    set: {
                        if !$0 {
                            speech.acknowledgeMissingVoice()
                        }
                    },
                ),
            ) {
                Button("OK", role: .cancel) { speech.acknowledgeMissingVoice() }
            } message: {
                Text(
                    """
                    HanReader cannot speak words aloud until a Chinese voice \
                    is added in System Settings, under Accessibility, \
                    Spoken Content, System Voice.
                    """,
                )
            }
    }

    @ViewBuilder
    private var content: some View {
        if let model {
            switch model.phase {
            case .loading:
                // No spinner for a load this fast. A 40 ms load that flashes
                // a spinner looks worse than one that simply appears.
                Color.clear
            case let .failed(message):
                ContentUnavailableView(
                    "This text could not be opened",
                    systemImage: "exclamationmark.triangle",
                    description: Text(verbatim: message),
                )
            case .ready:
                reader(model)
            }
        } else {
            Color.clear
        }
    }

    private func reader(_ model: ReaderModel) -> some View {
        @Bindable var model = model
        return ReaderSurface(
            document: model.document ?? SegmentedDocument(blocks: [], sourceLength: 0),
            style: style,
            readings: model.readings,
            selection: model.selection,
            reveal: model.reveal,
            onTap: { id in
                model.tap(id)
                if settings.speaksOnTap, let token = model.document?[id] {
                    speak(token.text)
                }
            },
            topBlock: $model.topBlock,
        )
        .modifier(DetailPanelPlacement(isCompact: sizeClass == .compact) {
            WordDetailPanel(
                state: model.detail,
                style: style,
                onExpand: { isInspectorPresented = true },
                onSpeak: { speak($0) },
            )
        })
        // The transport sits below everything, including the detail panel,
        // and only when the text actually has a narration — an empty
        // transport is a control that does nothing, which is worse than no
        // control.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if hasAudio {
                AudioBar(model: playback, title: title)
            }
        }
        // One modifier for both platforms. On a regular width this is a side
        // panel; on a compact one SwiftUI presents it as a sheet by itself,
        // which is exactly the behaviour wanted and needs no `#if os(`.
        .inspector(isPresented: $isInspectorPresented) {
            if case let .loaded(detail) = model.detail {
                WordDetailContent(
                    detail: detail,
                    style: style,
                    onSpeak: { speak($0) },
                    dictionaryNames: services.dictionaryNames,
                )
                .inspectorColumnWidth(min: 260, ideal: 320, max: 480)
            } else {
                ContentUnavailableView(
                    "No word selected",
                    systemImage: "character.magnify",
                )
            }
        }
    }

    /// How far the playhead must move before it is written again while
    /// playing. A minute of narration is a tolerable amount to lose to a
    /// crash, and a write a minute is nothing.
    static let playheadSaveInterval = 60.0

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem {
            Button {
                isPractising = true
            } label: {
                Label("Listening practice", systemImage: "headphones")
            }
            .disabled(!hasAudio)
            .help("Hear one sentence at a time and type what you heard.")
        }
        ToolbarItem {
            Button {
                isAudioImporterPresented = true
            } label: {
                Label(
                    hasAudio ? "Replace audio" : "Add audio",
                    systemImage: hasAudio ? "waveform.circle.fill" : "waveform.circle",
                )
            }
        }
        ToolbarItem {
            Picker(selection: Binding(
                get: { settings.wordSpacing },
                set: { settings.wordSpacing = $0 },
            )) {
                Text("Separated").tag(WordSpacing.separated)
                Text("Continuous").tag(WordSpacing.continuous)
            } label: {
                Text("Word spacing")
            }
            .pickerStyle(.segmented)
        }
        ToolbarItem {
            Button(action: settings.increaseFontSize) {
                Label("Larger text", systemImage: "textformat.size.larger")
            }
            // The `=` key, not `+`. On most layouts `+` is the shifted `=`,
            // so binding it means ⌘+ fires only as ⌘⇧+ while ⌘= — which is
            // what people press — does nothing at all.
            .keyboardShortcut("=", modifiers: .command)
            .disabled(settings.fontSize >= ReaderStyle.fontSizeRange.upperBound)
        }
        ToolbarItem {
            Button(action: settings.decreaseFontSize) {
                Label("Smaller text", systemImage: "textformat.size.smaller")
            }
            .keyboardShortcut("-", modifiers: .command)
            .disabled(settings.fontSize <= ReaderStyle.fontSizeRange.lowerBound)
        }
    }
}

/// The narration: finding it, attaching it, and keeping the spoken word
/// from talking over it.
///
/// An extension because it is one coherent concern that arrived whole in
/// M7, and because the screen's own body is the reading surface rather than
/// the transport.
extension ReaderScreen {
    // MARK: - Audio

    /// Finds this text's narration, if it has one, and parks it where the
    /// reader left off.
    private func loadAudio(for model: ReaderModel) async {
        do {
            let found = try await services.library.audioTrack(for: textID)
            // The transport is shared across texts, and this is the other
            // side of an `await`: the reader may have chosen another text
            // while the lookup was in flight, in which case writing to it
            // here loads this text's narration under that one's name.
            guard isStillCurrent(model) else { return }
            guard let track = found else {
                hasAudio = false
                playback.unload()
                return
            }
            let file = AudioAttachment.file(for: track, in: services.locations)
            guard FileManager.default.fileExists(atPath: file.path) else {
                // The row outlived its file. Said plainly rather than shown
                // as a transport that does nothing when pressed.
                hasAudio = true
                playback.fail("The audio file for this text is missing.")
                return
            }
            hasAudio = true
            lastSavedPlayhead = model.storedAudioTime ?? 0
            playback.load(file, startingAt: model.storedAudioTime)
            nowPlaying.attach(to: playback, title: title)
        } catch {
            Log.error("reader", "could not read the audio track: \(error)")
            hasAudio = false
        }
    }

    /// The playhead worth storing, or nil when there is nothing to store.
    ///
    /// Read synchronously, because every caller is about to unload the
    /// transport or hand it to another text — and `unload()` resets it.
    private func pendingPlayhead() -> Double? {
        guard hasAudio, playback.state == .ready else { return nil }
        return playback.playhead
    }

    /// Writes the playhead, so the next launch resumes mid-sentence rather
    /// than at the top. The prototype lost this on every relaunch.
    ///
    /// Called at every point the transport stops being this text's: a scene
    /// going inactive, the reader choosing another text, the window closing.
    /// Saving only on the first of those was its own version of the bug —
    /// changing text in the sidebar is the commonest of the three.
    private func savePlayhead(for id: TextID) async {
        await write(pendingPlayhead(), for: id)
    }

    private func write(_ time: Double?, for id: TextID) async {
        guard let time else { return }
        do {
            lastSavedPlayhead = time
            try await services.library.saveAudioTime(time, for: id)
        } catch {
            Log.error("reader", "could not save the playhead: \(error)")
        }
    }

    private func attachAudio(_ url: URL) async {
        let target = textID
        do {
            let file = try await AudioAttachment.attach(
                url,
                to: target,
                in: services.locations,
                library: services.library,
            )
            // A narration starts at its own beginning, so the playhead
            // stored for whatever was attached before has to go — otherwise
            // a reader who replaces a recording and leaves finds the new one
            // resuming at the old one's position, possibly past its end.
            try? await services.library.clearAudioTime(of: target)
            guard isStillCurrent() else { return }
            lastSavedPlayhead = 0
            hasAudio = true
            playback.load(file)
            nowPlaying.attach(to: playback, title: title)
        } catch {
            Log.error("reader", "could not attach audio: \(error)")
            guard isStillCurrent() else { return }
            hasAudio = true
            playback.fail(error.localizedDescription)
        }
    }

    /// Whether this screen still owns the shared transport.
    ///
    /// `model` is `@State`, so reading it after an `await` gives whichever
    /// text is open *now* — not the one this call started for.
    private func isStillCurrent(_ expected: ReaderModel? = nil) -> Bool {
        guard let current = model else { return false }
        if let expected, current !== expected {
            return false
        }
        return current.textID == textID
    }

    /// Speaks a word, ducking the narration first if the reader asked for
    /// that — which is the default, because the attached audio is usually
    /// the same narration and hearing both is confusing.
    private func speak(_ word: String) {
        guard settings.pausesAudioWhileSpeaking else {
            speech.speak(word, suppressed: voiceOverEnabled)
            return
        }
        playback.pauseForSpeech()
        speech.speak(word, suppressed: voiceOverEnabled)
        // `speak` declines in three ordinary situations — VoiceOver is on,
        // the word is empty, no Chinese voice is installed — and says so by
        // never starting. Without this the narration ducks for an utterance
        // that never happens and stays paused until the reader presses play,
        // which on a Mac with no Chinese voice is every single tap.
        if !speech.isSpeaking {
            playback.resumeAfterSpeech()
        }
    }
}

/// Puts the word-detail panel where the platform wants it.
///
/// Above the text on a regular width, which is the prototype's placement and
/// what Docs/fidelity.md commits to; below it on a compact one, where the
/// bottom of the screen is reachable and the top is under the status bar.
///
/// A modifier rather than two `.safeAreaInset` calls, because an inset with
/// an empty body still reserves its spacing — the panel would be at the
/// bottom and a blank band would sit at the top.
private struct DetailPanelPlacement<Panel: View>: ViewModifier {
    let isCompact: Bool
    @ViewBuilder let panel: () -> Panel

    func body(content: Content) -> some View {
        if isCompact {
            content.safeAreaInset(edge: .bottom, spacing: 0, content: panel)
        } else {
            content.safeAreaInset(edge: .top, spacing: 0, content: panel)
        }
    }
}

/// What a reader view is showing: a text, read with a particular set of
/// dictionaries.
///
/// Both halves are identity. Keying only on the text meant an imported
/// dictionary did not reach a text that was already open, because the model
/// holding the caches was never rebuilt.
private struct Reading: Equatable {
    let text: TextID
    let dictionaries: Int
}
