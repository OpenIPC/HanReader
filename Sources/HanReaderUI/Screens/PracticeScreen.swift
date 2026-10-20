// HanReader — MIT licensed. See LICENSE.

import HanReaderCore
import HanReaderPlatform
import HanReaderPlayback
import SwiftUI

/// Listening practice: hear one phrase, type what you heard, be told where
/// you were wrong.
///
/// ### Every shortcut is a ⌘ chord
///
/// WorkAudioBook puts these on bare Space, arrows and R, which it can
/// because its text box is a separate panel that must be focused
/// deliberately. Here the field holds focus the whole time and the reader is
/// typing Chinese through an input method, where a bare Space commits a
/// candidate and a bare arrow moves through them. Taking those keys would
/// make the app fight the IME on every character.
///
/// ### The transcript is hidden until it is checked
///
/// Not a preference. The answer being on screen is the one thing that makes
/// dictation worthless, so it is revealed by checking or by giving up, and
/// by nothing else.
struct PracticeScreen: View {
    let model: PracticeModel
    let playback: PlaybackModel
    let style: ReaderStyle

    @FocusState private var isWriting: Bool

    var body: some View {
        VStack(spacing: 0) {
            switch model.phase {
            case .noAudio:
                ContentUnavailableView(
                    "This text has no recording",
                    systemImage: "waveform.slash",
                    description: Text("Add audio from the reader to practise listening."),
                )
            case .needsAlignment:
                AlignmentInvitation(model: model)
            case let .aligning(progress):
                AlignmentProgressView(progress: progress) { model.cancelAlignment() }
            case let .unavailable(obstacle):
                AlignmentObstacleView(obstacle: obstacle, model: model)
            case .ready:
                practice
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Practising

    private var practice: some View {
        VStack(spacing: 0) {
            PhraseProgressStrip(model: model)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    PhraseTransport(model: model, playback: playback)
                    if model.tapping != nil {
                        TapAlongBar(model: model, style: style)
                    } else {
                        if model.isEditing {
                            BoundaryEditor(model: model, style: style)
                        }
                        writing
                    }
                    if let result = model.result {
                        DictationMarkedView(
                            result: result,
                            expected: model.text,
                            style: style,
                            readings: model.readings,
                        )
                        GradeRow(model: model)
                    } else if model.isRevealed {
                        revealed
                    }
                }
                .padding(ReaderMetrics.readingColumnPadding)
                .frame(maxWidth: style.maximumColumnWidth, alignment: .leading)
            }
        }
        .toolbar { toolbar }
    }

    private var writing: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Type what you hear…", text: Bindable(model).typed, axis: .vertical)
                .textFieldStyle(.plain)
                .font(ReaderFont.base(style))
                .lineLimit(2 ... 4)
                .focused($isWriting)
                // Guarded the same way the Check button is. Return
                // otherwise checks an empty field, which reveals the answer
                // and writes down a zero — through a control the screen is
                // showing as disabled.
                .onSubmit {
                    guard !model.typed.isEmpty else { return }
                    Task { await model.check() }
                }
            HStack(spacing: 12) {
                Button("Check") { Task { await model.check() } }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(model.typed.isEmpty)
                Button("Show the answer") { model.reveal() }
                    .buttonStyle(.borderless)
                    .font(.caption)
                Spacer()
                Text("⌘P play · ⌘→ next · ⌘↩ check early")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .onAppear {
            isWriting = true
            model.playOnArrival()
        }
        // Every keystroke on this screen is meant to be Chinese, so the
        // system is asked for a Chinese input source while the field holds
        // focus rather than leaving the learner to switch twice a sentence
        // and find out they forgot after the answer is marked wrong.
        .onChange(of: isWriting) { _, writing in
            writing ? ChineseInput.prefer() : ChineseInput.clearPreference()
        }
        .onChange(of: model.current) { _, _ in
            isWriting = true
            model.playOnArrival()
        }
        // Typing is the whole interaction. The answer is marked as soon as
        // it is as long as the sentence, and a correct one moves on by
        // itself — Check and Next phrase stay for the times that is not
        // what was wanted.
        .onChange(of: model.typed) { _, _ in
            Task { await model.answerChanged() }
        }
    }

    private var revealed: some View {
        Text(verbatim: model.text)
            .font(ReaderFont.base(style))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem {
            Picker(selection: Bindable(model).filter) {
                Text("All phrases").tag(PracticeModel.Filter.all)
                Text("Needs work").tag(PracticeModel.Filter.needsWork)
            } label: {
                Text("Which phrases")
            }
            .pickerStyle(.segmented)
        }
        ToolbarItem {
            DrillMenu(model: model)
        }
        ToolbarItem {
            Button {
                model.isEditing ? model.stopEditing() : model.startEditing()
            } label: {
                Label("Edit boundaries", systemImage: "waveform.path")
            }
            .help("Drag where this phrase starts and ends.")
        }
    }
}

// MARK: - Before there are phrases

/// Offered rather than done. Listening to a recording takes a moment and,
/// the first time, a model download measured in hundreds of megabytes —
/// neither of which should happen because somebody opened a tab.
private struct AlignmentInvitation: View {
    let model: PracticeModel

    var body: some View {
        ContentUnavailableView {
            Label("Find the phrases", systemImage: "waveform.badge.magnifyingglass")
        } description: {
            Text("""
            HanReader listens to the recording once to work out where each \
            sentence is said. It happens on this device and the audio is \
            not sent anywhere.
            """)
        } actions: {
            VStack(spacing: 8) {
                Button("Listen to the recording") { model.align() }
                    .buttonStyle(.borderedProminent)
                // Offered here too, not only after something has gone
                // wrong: a reader who already knows the recogniser cannot
                // follow this recording should not have to wait for it to
                // fail before they can do it themselves.
                Button("Place the phrases myself") {
                    Task { await model.splitWithoutListening() }
                }
                .font(.caption)
            }
        }
    }
}

private struct AlignmentProgressView: View {
    let progress: SpeechAlignmentProgress
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            if progress.isInstallingModel {
                ProgressView(value: progress.fraction ?? 0) {
                    Text("Downloading the Chinese speech model…")
                }
                Text("This happens once. It is several hundred megabytes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let fraction = progress.fraction {
                ProgressView(value: fraction) {
                    Text("Listening to the recording…")
                }
            } else {
                ProgressView("Listening to the recording…")
            }
            Button("Stop", role: .cancel, action: onCancel)
                .font(.caption)
        }
        .frame(maxWidth: 420)
        .padding()
    }
}

/// What to say when alignment cannot be done, which on a managed Mac is a
/// real and un-obvious situation: `allowDictation = false` closes the usual
/// route to a Chinese speech model, and the reader deserves to know the app
/// is not simply broken.
private struct AlignmentObstacleView: View {
    let obstacle: PracticeModel.AlignmentObstacle
    let model: PracticeModel

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: "waveform.badge.exclamationmark")
        } description: {
            Text(verbatim: explanation)
        } actions: {
            VStack(spacing: 8) {
                if obstacle.canInstall {
                    Button("Download the model") { model.align(installingModel: true) }
                        .buttonStyle(.borderedProminent)
                }
                // Always offered, including when the model could be
                // installed: a reader who will not download several hundred
                // megabytes should still be able to practise, and this is
                // the path that always works.
                let myself = Button("Place the phrases myself") {
                    Task { await model.splitWithoutListening() }
                }
                if obstacle.canInstall {
                    myself.buttonStyle(.bordered)
                } else {
                    myself.buttonStyle(.borderedProminent)
                }
            }
        }
    }

    private var title: LocalizedStringKey {
        switch obstacle {
        case .modelMissing: "The Chinese speech model is not installed"
        case .systemTooOld: "This Mac cannot find phrases automatically"
        case .languageUnsupported: "Chinese speech recognition is unavailable"
        case .failed: "The recording could not be read"
        }
    }

    private var explanation: String {
        switch obstacle {
        case .modelMissing:
            """
            HanReader needs it to work out where each sentence is said. It \
            downloads once, works offline afterwards, and does not require \
            Dictation to be switched on.
            """
        case .systemTooOld:
            """
            Finding phrases automatically needs macOS 26 or later. You can \
            still practise by placing the phrase boundaries yourself.
            """
        case .languageUnsupported:
            "This system has no Chinese speech recognition to offer."
        case let .failed(reason):
            reason
        }
    }
}
