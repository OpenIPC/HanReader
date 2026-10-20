// HanReader — MIT licensed. See LICENSE.

import HanReaderCore
import SwiftUI

/// What the learner wrote, against what was said, character by character.
///
/// The three kinds of wrong are the point of the screen. A learner who typed
/// 真 for 针 heard the phrase perfectly and picked the wrong candidate from
/// their input method; one who typed 是 for 时 heard the syllable and missed
/// the tone; one who typed 猫 for 狗 did not hear it. Telling them apart is
/// the difference between "practise listening more" and "your ears are
/// fine, watch your IME".
struct DictationMarkedView: View {
    let result: DictationResult
    let expected: String
    let style: ReaderStyle
    /// What each character sounds like, for the ones that were wrong.
    ///
    /// A learner looking at a mistake needs to know what the character they
    /// missed actually sounds like — that is the thing worth taking away
    /// from it — and seeing it beside what they typed is what turns "wrong"
    /// into "those two sound alike, I picked the wrong one".
    let readings: [Character: [CharacterReading]]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            marks
            summary
            legend
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The transcript with each character marked.
    ///
    /// Laid out as a wrapping row of characters rather than one attributed
    /// string, because a wrong character needs the right one *above* it —
    /// the same reason the reader draws ruby itself.
    private var marks: some View {
        FlowRow(spacing: 2) {
            ForEach(Array(result.marks.enumerated()), id: \.offset) { _, mark in
                MarkView(mark: mark, style: style, readings: readings)
            }
        }
    }

    private var summary: some View {
        HStack(spacing: 14) {
            Text("\(result.correct) of \(result.expected) correct")
                .font(.callout.weight(.medium))
            ForEach(Self.reportable, id: \.self) { outcome in
                let count = result.count(of: outcome)
                if count > 0 {
                    Text(Self.describe(outcome, count: count))
                        .font(.caption)
                        .foregroundStyle(ReaderColor.dictation(outcome))
                }
            }
            Spacer()
            // The score that decides whether this phrase is done, which is
            // the listening one: a homophone slip is not a listening
            // mistake, so it does not keep a phrase in the drill.
            Text("\(Int((result.listeningAccuracy * 100).rounded()))% heard")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var legend: some View {
        let kinds = Self.reportable.filter { result.count(of: $0) > 0 }
        if !kinds.isEmpty {
            HStack(spacing: 12) {
                ForEach(kinds, id: \.self) { outcome in
                    Label {
                        Text(Self.explain(outcome))
                    } icon: {
                        Circle()
                            .fill(ReaderColor.dictation(outcome))
                            .frame(width: 7, height: 7)
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    static let reportable: [DictationOutcome] = [
        .homophone, .toneSlip, .misheard, .missing, .extra,
    ]

    static func describe(_ outcome: DictationOutcome, count: Int) -> String {
        switch outcome {
        case .homophone: "\(count) homophone"
        case .toneSlip: "\(count) tone"
        case .misheard: "\(count) misheard"
        case .missing: "\(count) missing"
        case .extra: "\(count) extra"
        case .correct: ""
        }
    }

    static func explain(_ outcome: DictationOutcome) -> String {
        switch outcome {
        case .homophone: "heard right, wrong character"
        case .toneSlip: "right syllable, wrong tone"
        case .misheard: "not heard"
        case .missing: "left out"
        case .extra: "not said"
        case .correct: ""
        }
    }
}

/// One marked character: what was said, and what was typed instead.
private struct MarkView: View {
    let mark: DictationMark
    let style: ReaderStyle
    let readings: [Character: [CharacterReading]]

    var body: some View {
        VStack(spacing: 1) {
            // What they typed, above, only when it differs — the same place
            // the reader puts pinyin, for the same reason: it annotates
            // without moving the line it annotates.
            Text(verbatim: typedAbove)
                .font(ReaderFont.ruby(style))
                .foregroundStyle(ReaderColor.dictation(mark.outcome))
                .frame(minHeight: style.rubyReservation)
            Text(verbatim: displayed)
                .font(ReaderFont.base(style))
                .foregroundStyle(mark.outcome == .extra ? .secondary : .primary)
                .strikethrough(mark.outcome == .extra)
                .padding(.horizontal, 1)
                .background {
                    RoundedRectangle(cornerRadius: ReaderMetrics.tokenCornerRadius)
                        .fill(ReaderColor.dictationFill(mark.outcome))
                }
            // And underneath, how the character they missed is said. Only
            // under the wrong ones: pinyin under every character would be
            // the reading surface, and this is a marking.
            Text(verbatim: pinyin)
                .font(ReaderFont.ruby(style))
                .foregroundStyle(.secondary)
                .frame(minHeight: style.rubyReservation)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibility)
    }

    /// How the expected character is said, or how the typed one is when
    /// there was nothing to expect.
    private var pinyin: String {
        guard mark.outcome != .correct else { return " " }
        let character = mark.expected ?? mark.typed
        guard let character, let reading = readings[character]?.first else { return " " }
        return reading.display
    }

    /// A missing character is shown as an underscore rather than omitted:
    /// the gap is the information.
    private var displayed: String {
        if let expected = mark.expected {
            return String(expected)
        }
        if let typed = mark.typed {
            return String(typed)
        }
        return "＿"
    }

    private var typedAbove: String {
        guard mark.outcome != .correct, mark.outcome != .extra,
              let typed = mark.typed, mark.expected != nil
        else { return " " }
        return String(typed)
    }

    private var accessibility: Text {
        let expected = mark.expected.map(String.init) ?? ""
        let typed = mark.typed.map(String.init) ?? ""
        return switch mark.outcome {
        case .correct: Text("\(expected), correct")
        case .homophone: Text("\(expected), you wrote \(typed), same sound")
        case .toneSlip: Text("\(expected), you wrote \(typed), wrong tone")
        case .misheard: Text("\(expected), you wrote \(typed)")
        case .missing: Text("\(expected), missing")
        case .extra: Text("\(typed), not said")
        }
    }
}

/// A row that wraps, for laying out marked characters.
///
/// The reading surface's `TokenFlowLayout` is not reused here: it exists to
/// reserve ruby space and apply kinsoku across a paragraph of tokens, and
/// this is a single phrase of single characters. Borrowing it would mean
/// taking its whole line-breaking model for a row of boxes.
private struct FlowRow: Layout {
    var spacing: CGFloat = 2

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var rows = 1
        var x: CGFloat = 0
        var height: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                rows += 1
                x = 0
            }
            x += size.width + spacing
            height = max(height, size.height)
        }
        return CGSize(
            width: proposal.width ?? x,
            height: height * CGFloat(rows) + spacing * CGFloat(rows - 1),
        )
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout (),
    ) {
        var x = bounds.minX
        var y = bounds.minY
        var lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += lineHeight + spacing
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
