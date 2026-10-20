// HanReader — MIT licensed. See LICENSE.

import HanReaderCore
import HanReaderPlayback
import SwiftUI

/// Where the reader is in the text, and what they have already passed.
///
/// A strip of marks rather than a list: a two-minute exercise is twenty-odd
/// phrases, and the useful question is "how much is left and which ones am
/// I failing", not "what is phrase fourteen called".
struct PhraseProgressStrip: View {
    let model: PracticeModel

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 4) {
                ForEach(model.visible, id: \.index) { phrase in
                    Button {
                        model.select(phrase.index)
                    } label: {
                        Capsule()
                            .fill(colour(for: phrase))
                            .frame(width: phrase.index == model.current ? 22 : 12, height: 6)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(label(for: phrase))
                }
            }
            .padding(.horizontal, ReaderMetrics.readingColumnPadding)
            .padding(.vertical, 10)
        }
        .scrollIndicators(.never)
    }

    private func colour(for phrase: Phrase) -> Color {
        if phrase.index == model.current {
            return ReaderColor.highlight
        }
        guard let attempt = model.attempts[phrase.index] else {
            return ReaderColor.untried
        }
        return attempt.isPassing() ? ReaderColor.passed : ReaderColor.needsWork
    }

    private func label(for phrase: Phrase) -> Text {
        guard let attempt = model.attempts[phrase.index] else {
            return Text("Phrase \(phrase.index + 1), not yet attempted")
        }
        return Text("Phrase \(phrase.index + 1), \(Int(attempt.accuracy * 100)) percent")
    }
}

/// Play this phrase, again, slower, or move to another one.
struct PhraseTransport: View {
    let model: PracticeModel
    let playback: PlaybackModel

    var body: some View {
        HStack(spacing: 14) {
            Button {
                playback.isPlaying ? model.stop() : model.play()
            } label: {
                Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title2)
            }
            .buttonStyle(.borderless)
            .keyboardShortcut("p", modifiers: .command)
            .accessibilityLabel(playback.isPlaying ? Text("Stop") : Text("Play this phrase"))

            Button {
                model.advance(by: -1)
            } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.borderless)
            .keyboardShortcut(.leftArrow, modifiers: .command)
            .accessibilityLabel(Text("Previous phrase"))

            Button {
                model.advance(by: 1)
            } label: {
                Image(systemName: "chevron.right")
            }
            .buttonStyle(.borderless)
            .keyboardShortcut(.rightArrow, modifiers: .command)
            .accessibilityLabel(Text("Next phrase"))

            if let phrase = model.phrase {
                Text(verbatim: "\(phrase.index + 1) / \(model.phrases.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Text(verbatim: AudioBar.clock(phrase.duration))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
                // Low confidence means the recogniser inferred most of this
                // phrase's timing rather than matching it, so the reader is
                // told before they blame their ears for a boundary.
                if phrase.confidence < 0.5 {
                    Label("Boundary uncertain", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .labelStyle(.iconOnly)
                        .help("The recording was hard to follow here.")
                }
            }

            Spacer()

            Picker(selection: Bindable(playback).rate) {
                ForEach(PlaybackRate.allCases, id: \.self) { rate in
                    Text(verbatim: rate.label).tag(rate)
                }
            } label: {
                Text("Speed")
            }
            .pickerStyle(.menu)
            .fixedSize()
            .accessibilityLabel(Text("Playback speed"))
        }
    }
}

/// How many times each phrase plays, and how long a gap it leaves.
struct DrillMenu: View {
    let model: PracticeModel

    var body: some View {
        Menu {
            Picker("Repeats", selection: repeats) {
                ForEach([1, 2, 3, 5], id: \.self) { count in
                    Text("\(count)×").tag(count)
                }
            }
            Picker("Gap", selection: gap) {
                Text("None").tag(0.0)
                Text("2 seconds").tag(2.0)
                Text("5 seconds").tag(5.0)
                Text("10 seconds").tag(10.0)
            }
        } label: {
            Label("Repeat settings", systemImage: "repeat")
        }
    }

    private var repeats: Binding<Int> {
        Binding(
            get: { model.drill.repeats },
            set: { model.drill = .init(repeats: $0, gap: model.drill.gap) },
        )
    }

    private var gap: Binding<Double> {
        Binding(
            get: { model.drill.gap },
            set: { model.drill = .init(repeats: model.drill.repeats, gap: $0) },
        )
    }
}

/// Easy, medium, hard — and what to drill again.
struct GradeRow: View {
    let model: PracticeModel

    var body: some View {
        HStack(spacing: 10) {
            ForEach(PhraseGrade.allCases, id: \.self) { grade in
                Button(title(grade)) {
                    Task { await model.grade(model.phrase?.grade == grade ? nil : grade) }
                }
                .buttonStyle(.bordered)
                .tint(model.phrase?.grade == grade ? ReaderColor.highlight : nil)
                .font(.caption)
            }
            Spacer()
            // No shortcut here. ⌘→ belongs to the transport's own next
            // button, which is on screen at the same time; binding both
            // leaves SwiftUI to pick one, and a later change to either
            // action would silently alter the other.
            Button("Next phrase") { model.advance(by: 1) }
                .font(.caption)
        }
    }

    private func title(_ grade: PhraseGrade) -> LocalizedStringKey {
        switch grade {
        case .easy: "Easy"
        case .medium: "Middling"
        case .hard: "Hard"
        }
    }
}

/// Tapping the phrase boundaries in while the recording plays.
///
/// The path for a system with no Chinese speech recognition, and the repair
/// for a recording the recogniser could not follow. It is a few dozen lines
/// and it is always exactly right, which is why it is here rather than a
/// second alignment algorithm guessing from silence.
struct TapAlongBar: View {
    let model: PracticeModel
    let style: ReaderStyle

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Press Mark as each phrase begins.")
                    .font(.callout.weight(.medium))
                Text("⌘↩")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            if let next = model.upcoming {
                Text(verbatim: next.text(in: model.content))
                    .font(ReaderFont.base(style))
                    .lineLimit(2)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                // ⌘↩ rather than the obvious ⌘M: that is the system's
                // Minimize, and a view's shortcut competing with a menu
                // command is a fight to lose. ⌘↩ is free here — the writing
                // field is not on screen while this is — and it already
                // means "commit this" everywhere else on the screen.
                Button("Mark") {
                    Task { await model.tapBoundary() }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)

                if let tapping = model.tapping {
                    Text(verbatim: "\(tapping.next) / \(model.phrases.count - 1)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Stop", role: .cancel) { model.cancelTapAlong() }
                    .font(.caption)
            }
        }
        .padding(ReaderMetrics.readingColumnPadding / 2)
        .background {
            RoundedRectangle(cornerRadius: ReaderMetrics.tokenCornerRadius)
                .fill(ReaderColor.highlightWash)
        }
    }
}
