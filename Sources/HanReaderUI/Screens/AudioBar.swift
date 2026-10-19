// HanReader — MIT licensed. See LICENSE.

import HanReaderPlayback
import SwiftUI

/// The transport for a text's narration.
///
/// Persistent while a text with audio is open, which is fidelity invariant 6
/// — the prototype's bottom bar, kept. It has one behaviour worth stating
/// outright, because getting it wrong is what made the prototype's scrubber
/// fight itself: **the slider commits once**.
///
/// `Slider`'s `onEditingChanged` is the seam. While the finger is down the
/// binding writes to `PlaybackModel.scrub(to:)`, which moves nothing but the
/// thumb; when it comes up, `endScrub()` issues exactly one seek. The
/// prototype bound the slider straight to `player.seek`, so every drag delta
/// was a frame-accurate seek, and the position observer wrote the old value
/// back underneath the finger.
struct AudioBar: View {
    let model: PlaybackModel
    /// Shown beside the transport so the reader knows what is playing when
    /// several windows are open.
    let title: String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 12) {
                playButton
                skipButton(by: -NowPlayingController.skipInterval)
                skipButton(by: NowPlayingController.skipInterval)
                scrubber
                speedMenu
            }
            if case let .failed(message) = model.state {
                Text(verbatim: message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, ReaderMetrics.readingColumnPadding)
        .padding(.vertical, 10)
        .background(.bar)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Audio for \(title)"))
    }

    private var playButton: some View {
        Button {
            model.toggle()
        } label: {
            Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
        }
        .buttonStyle(.borderless)
        .modifier(TransportHitTarget())
        .disabled(model.state != .ready)
        .keyboardShortcut(.space, modifiers: [])
        .accessibilityLabel(model.isPlaying ? Text("Pause") : Text("Play"))
    }

    private func skipButton(by seconds: Double) -> some View {
        let isBack = seconds < 0
        return Button {
            model.skip(by: seconds)
        } label: {
            Image(systemName: isBack ? "gobackward.10" : "goforward.10")
        }
        .buttonStyle(.borderless)
        .modifier(TransportHitTarget())
        .disabled(model.state != .ready)
        .accessibilityLabel(
            isBack
                ? Text("Back \(Int(-seconds)) seconds")
                : Text("Forward \(Int(seconds)) seconds"),
        )
    }

    private var scrubber: some View {
        HStack(spacing: 8) {
            timeLabel(model.displayTime)
            Slider(
                value: Binding(
                    get: { model.displayTime },
                    // Moves the thumb only. No seek is issued here, which is
                    // the entire point.
                    set: { model.scrub(to: $0) },
                ),
                in: 0 ... max(model.duration, 1),
            ) { isEditing in
                if isEditing {
                    model.beginScrub(at: model.displayTime)
                } else {
                    model.endScrub()
                }
            }
            .disabled(model.state != .ready || model.duration <= 0)
            .accessibilityLabel(Text("Playback position"))
            .accessibilityValue(Text(Self.spoken(model.displayTime)))
            timeLabel(model.duration)
        }
    }

    private var speedMenu: some View {
        Menu {
            Picker("Speed", selection: Bindable(model).rate) {
                ForEach(PlaybackRate.allCases, id: \.self) { rate in
                    Text(verbatim: rate.label).tag(rate)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Text(verbatim: model.rate.label)
                .font(.caption.monospacedDigit())
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(model.state != .ready)
        .accessibilityLabel(Text("Playback speed"))
    }

    private func timeLabel(_ seconds: Double) -> some View {
        // Monospaced digits, or the whole row shifts sideways every time the
        // seconds tick over from 1 to 2 — the layout jitter that makes a
        // transport feel unsteady.
        Text(verbatim: Self.clock(seconds))
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
    }

    /// `m:ss`, or `h:mm:ss` for anything over an hour.
    ///
    /// Hand-formatted rather than `Duration.formatted`, which spells a
    /// position as "1 min, 4 sec" — correct prose, and unreadable as a
    /// changing clock.
    static func clock(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded(.down))
        let (hours, minutes, secs) = (total / 3600, total / 60 % 60, total % 60)
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }

    /// What VoiceOver says, which is prose rather than a clock: "4 minutes,
    /// 12 seconds" reads correctly where "4:12" is announced as a time of
    /// day.
    static func spoken(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0 seconds" }
        return Duration.seconds(Int(seconds.rounded(.down)))
            .formatted(.units(allowed: [.hours, .minutes, .seconds], width: .wide))
    }
}

/// Gives a transport button a target worth aiming at.
///
/// An SF Symbol in a borderless button is as big as its glyph — the play
/// triangle measured 9×11 points, which is a target you hunt for rather than
/// hit. The width is the full guideline; the height is less, because a 44pt
/// row would make the bar as tall as the detail panel on a Mac. M8 raises it
/// for touch, where the guideline is not a guideline.
private struct TransportHitTarget: ViewModifier {
    func body(content: Content) -> some View {
        content
            .frame(minWidth: ReaderMetrics.minimumHitTarget, minHeight: 24)
            .contentShape(.rect)
    }
}
