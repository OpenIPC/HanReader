// HanReader — MIT licensed. See LICENSE.

import HanReaderCore
import HanReaderPlayback
import SwiftUI

/// Where a phrase starts and ends, as something to drag.
///
/// The only place in the app that draws a waveform. Everywhere else the
/// recording is a line and a clock, because everywhere else the question is
/// "how far through am I" — here it is "does that syllable belong inside",
/// and that is a question about shape.
///
/// ### The text is shown here
///
/// Practice hides the transcript, and this reveals it. That is not a leak
/// but the point: a boundary cannot be placed without knowing which words it
/// is meant to contain. Opening the editor counts as giving up on the
/// phrase, the same as pressing "Show the answer", and the model records it
/// that way.
struct BoundaryEditor: View {
    let model: PracticeModel
    let style: ReaderStyle

    /// Where a handle has been dragged to but not yet committed.
    ///
    /// One write per gesture rather than one per delta, which is the lesson
    /// the transport's scrubber already learnt: a frame-accurate write on
    /// every drag event fights the thing reading it back.
    @State private var dragging: (boundary: PhraseBoundary, time: Double)?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if model.isReadingWaveform {
                ProgressView("Reading the recording…")
                    .frame(height: ReaderMetrics.waveformHeight)
                    .frame(maxWidth: .infinity)
            } else {
                strip
            }
            controls
        }
    }

    // MARK: - What is being edited

    @ViewBuilder
    private var header: some View {
        if let phrase = model.phrase {
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: phrase.text(in: model.content))
                    .font(ReaderFont.base(style))
                    .lineLimit(2)
                HStack(spacing: 10) {
                    Text(
                        verbatim: "\(AudioBar.clock(phrase.start)) – \(AudioBar.clock(phrase.end))",
                    )
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    if phrase.origin == .manual {
                        Label("Placed by you", systemImage: "hand.draw")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: - The strip

    private var strip: some View {
        GeometryReader { geometry in
            let window = model.editorWindow
            let width = geometry.size.width

            ZStack(alignment: .leading) {
                waveform(window: window, size: geometry.size)
                if let phrase = model.phrase {
                    let from = x(of: start(of: phrase), in: window, width: width)
                    let to = x(of: end(of: phrase), in: window, width: width)
                    Rectangle()
                        .fill(ReaderColor.highlightWash)
                        .frame(width: max(0, to - from))
                        .offset(x: from)
                    handle(.start, at: from, window: window, width: width)
                    handle(.end, at: to, window: window, width: width)
                }
            }
            .contentShape(Rectangle())
        }
        .frame(height: ReaderMetrics.waveformHeight)
        .background {
            RoundedRectangle(cornerRadius: ReaderMetrics.tokenCornerRadius)
                .fill(.quaternary.opacity(0.4))
        }
    }

    /// The recording's shape, bar by bar, with the phrase's own bars in the
    /// accent colour.
    private func waveform(window: Range<Double>, size: CGSize) -> some View {
        Canvas { context, size in
            let bars = max(1, Int(size.width / 2))
            let samples = model.peaks.resampled(over: window, count: bars)
            let step = size.width / CGFloat(bars)
            let middle = size.height / 2
            let span = model.phrase.map { start(of: $0) ... end(of: $0) }

            for (index, value) in samples.enumerated() {
                let x = CGFloat(index) * step
                // A floor, so silence is a visible line rather than a gap —
                // a strip that disappears where the speaker paused reads as
                // a drawing failure.
                let height = max(1, CGFloat(value) * size.height * 0.9)
                let time = window.lowerBound
                    + Double(index) / Double(bars) * (window.upperBound - window.lowerBound)
                context.fill(
                    Path(CGRect(x: x, y: middle - height / 2, width: step * 0.8, height: height)),
                    with: .color(
                        span?.contains(time) == true
                            ? ReaderColor.waveformInPhrase
                            : ReaderColor.waveform,
                    ),
                )
            }
        }
        .frame(width: size.width, height: size.height)
    }

    /// One draggable edge.
    private func handle(
        _ boundary: PhraseBoundary,
        at position: CGFloat,
        window: Range<Double>,
        width: CGFloat,
    )
        -> some View
    {
        Rectangle()
            .fill(ReaderColor.highlight)
            .frame(width: 2)
            .frame(maxHeight: .infinity)
            .overlay {
                // The grab area, far wider than the line and deliberately
                // invisible: a one-point target cannot be hit with a mouse,
                // let alone a finger.
                Color.clear
                    .frame(width: ReaderMetrics.waveformHandleWidth)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 1)
                            .onChanged { value in
                                dragging = (
                                    boundary,
                                    time(
                                        of: position + value.translation.width,
                                        in: window,
                                        width: width,
                                    ),
                                )
                            }
                            .onEnded { value in
                                let target = time(
                                    of: position + value.translation.width,
                                    in: window,
                                    width: width,
                                )
                                dragging = nil
                                Task { await model.move(boundary, to: target) }
                            },
                    )
            }
            .offset(x: position - 1)
            .accessibilityLabel(
                boundary == .start ? Text("Phrase start") : Text("Phrase end"),
            )
            .accessibilityAdjustableAction { direction in
                nudge(boundary, by: direction == .increment ? 0.1 : -0.1)
            }
    }

    // MARK: - Controls

    private var controls: some View {
        HStack(spacing: 12) {
            Button {
                model.playSpan()
            } label: {
                Label("Play this phrase", systemImage: "play.fill")
            }
            .font(.caption)

            Button("Trim start") { nudge(.start, by: 0.1) }
                .font(.caption)
            Button("Widen start") { nudge(.start, by: -0.1) }
                .font(.caption)

            Spacer()
            Button("Tap them all in") { model.beginTapAlong() }
                .font(.caption)
                .disabled(model.phrases.count < 2)
            Button("Done") { model.stopEditing() }
                .font(.caption)
        }
    }

    /// Moves a boundary by a fixed step, for a keyboard or VoiceOver.
    ///
    /// Dragging is not the only way in: a tenth of a second is about the
    /// smallest difference that matters here and about the smallest anyone
    /// can aim at, so the same step serves both.
    private func nudge(_ boundary: PhraseBoundary, by seconds: Double) {
        guard let phrase = model.phrase else { return }
        let from = boundary == .start ? phrase.start : phrase.end
        Task { await model.move(boundary, to: from + seconds) }
    }

    // MARK: - Time and position

    private func start(of phrase: Phrase) -> Double {
        dragging?.boundary == .start ? dragging?.time ?? phrase.start : phrase.start
    }

    private func end(of phrase: Phrase) -> Double {
        dragging?.boundary == .end ? dragging?.time ?? phrase.end : phrase.end
    }

    private func x(of time: Double, in window: Range<Double>, width: CGFloat) -> CGFloat {
        let span = window.upperBound - window.lowerBound
        guard span > 0 else { return 0 }
        return CGFloat((time - window.lowerBound) / span) * width
    }

    private func time(of x: CGFloat, in window: Range<Double>, width: CGFloat) -> Double {
        guard width > 0 else { return window.lowerBound }
        let span = window.upperBound - window.lowerBound
        return window.lowerBound + Double(x / width) * span
    }
}
