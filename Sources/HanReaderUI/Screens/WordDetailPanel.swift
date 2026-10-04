// HanReader — MIT licensed. See LICENSE.

import HanReaderCore
import SwiftUI

/// The always-visible strip under the reading surface.
///
/// **Fixed height, and that is the whole design.** A panel that grows to fit
/// its content pushes the body text down every time a word with a longer
/// definition is tapped, which is the most disruptive thing a reading
/// surface can do and is fidelity invariant 1 lost through the back door.
/// The prototype got this right and it is preserved exactly — 88 points,
/// scaled by Dynamic Type, which the prototype did not do and which is why
/// its panel clipped its own content at AX3 and above.
///
/// A definition longer than the strip is truncated here and read in full in
/// the expanded surface, which is one tap away and does not move the text.
struct WordDetailPanel: View {
    let state: DetailState
    let style: ReaderStyle
    let onExpand: () -> Void
    let onSpeak: (String) -> Void

    @ScaledMetric private var height = ReaderMetrics.detailPanelHeight
    @ScaledMetric private var headwordWidth = ReaderMetrics.detailHeadwordWidth
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            content
            Spacer(minLength: 0)
        }
        .padding(.horizontal, ReaderMetrics.readingColumnPadding)
        .padding(.vertical, 12)
        .frame(height: height, alignment: .top)
        .frame(maxWidth: .infinity)
        .background(.bar)
        .animation(ReaderAnimation.detail(reduceMotion: reduceMotion), value: state)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Word detail"))
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .empty:
            Text("Tap a word to see its reading and meaning.")
                .font(.callout)
                .foregroundStyle(.tertiary)

        case let .loading(word):
            // Redacted rather than a spinner, and certainly not "not found".
            // The prototype reported "Not found in dictionary" while the
            // dictionary was still being read, which is not a slow answer
            // but a wrong one.
            entryRow(
                word: word,
                reading: nil,
                summary: "Looking this word up in the dictionary",
                senses: [],
            )
            .redacted(reason: .placeholder)

        case let .loaded(detail):
            // One case, whether or not the dictionary defines the word. As
            // two, the "not found" branch had no reading to pass and so
            // removed the pinyin that was already visible above the word —
            // which for a word composed from its characters is exactly the
            // reading the reader most wants to keep looking at.
            entryRow(
                word: detail.word,
                reading: detail.reading,
                summary: nil,
                senses: detail.entries,
            )
        }
    }

    @ViewBuilder
    private func entryRow(
        word: String,
        reading: TokenReading?,
        summary: String?,
        senses: [DictionaryEntry],
    )
        -> some View
    {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: word)
                .font(ReaderFont.base(style))
            if let reading {
                Text(verbatim: reading.display)
                    .font(ReaderFont.ruby(style))
                    .foregroundStyle(
                        reading.source.isApproximate
                            ? ReaderColor.approximateRuby
                            : ReaderColor.ruby,
                    )
            }
        }
        .frame(width: headwordWidth, alignment: .leading)
        .accessibilityElement(children: .combine)

        VStack(alignment: .leading, spacing: 4) {
            if let summary {
                Text(verbatim: summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else if senses.isEmpty {
                Text("No entry in the dictionary for this word.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Text(verbatim: Self.summary(of: senses))
                    .font(.callout)
                    .lineLimit(2)
            }
        }

        Spacer(minLength: 0)

        if case let .loaded(detail) = state {
            HStack(spacing: 8) {
                Button {
                    onSpeak(detail.word)
                } label: {
                    Label("Speak", systemImage: "speaker.wave.2")
                }
                Button(action: onExpand) {
                    Label("Show all senses", systemImage: "text.justify.left")
                }
                // Offered even with no entries, because there is still
                // something to show there: the reading, and why it is only
                // an approximation.
                .disabled(detail.reading == nil && !detail.isDefined)
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
        }
    }

    /// A one-line gloss.
    ///
    /// Prefers an entry that actually defines something. A sense that only
    /// says "variant of 妳" is a poor one-line summary, which is exactly why
    /// `SenseKind` exists and why `summarySense` already makes that choice —
    /// this only has to pick between *entries*.
    static func summary(of entries: [DictionaryEntry]) -> String {
        let defining = entries.first { $0.summarySense?.kind == .definition }
        let chosen = defining ?? entries.first
        return chosen?.summarySense?.gloss.text ?? ""
    }
}
