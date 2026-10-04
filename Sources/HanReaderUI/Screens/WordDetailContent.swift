// HanReader — MIT licensed. See LICENSE.

import HanReaderCore
import SwiftUI

/// Every sense of a word, for the expanded surface.
///
/// Where the panel truncates, this does not. Showing *all* the entries is
/// the point: 和 has eight and 了 has two readings, and the prototype's
/// `WHERE simplified = ? LIMIT 1` showed one of them with nothing to say
/// that others existed.
struct WordDetailContent: View {
    let detail: WordDetail
    let style: ReaderStyle
    let onSpeak: (String) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                if detail.isDefined {
                    ForEach(Array(detail.entries.enumerated()), id: \.offset) { _, entry in
                        entryView(entry)
                    }
                } else {
                    Text("No entry in the dictionary for this word.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(verbatim: detail.word)
                    .font(ReaderFont.base(style))
                Button {
                    onSpeak(detail.word)
                } label: {
                    Label("Speak", systemImage: "speaker.wave.2")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
            }
            if let reading = detail.reading {
                Text(verbatim: reading.display)
                    .font(.title3)
                    .foregroundStyle(
                        reading.source.isApproximate
                            ? ReaderColor.approximateRuby
                            : ReaderColor.ruby,
                    )
                if let caveat = Self.caveat(for: reading.source) {
                    // Said plainly rather than implied by a lighter colour.
                    // A reader deciding whether to trust an annotation
                    // should not have to infer it from a shade of grey.
                    Text(caveat)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func entryView(_ entry: DictionaryEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(verbatim: entry.readingDisplay)
                    .font(.headline)
                if entry.headword.scriptsDiffer {
                    // Shown only when the two forms actually differ, which
                    // is true for 63% of CC-CEDICT. Printing the same
                    // characters twice for the rest would be noise.
                    Text(verbatim: entry.headword.traditionalOrSimplified)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(Text("Traditional form"))
                }
            }
            ForEach(entry.senses) { sense in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(verbatim: "\(sense.id + 1).")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.tertiary)
                    Text(verbatim: sense.gloss.text)
                        .font(.callout)
                        .textSelection(.enabled)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Optional rather than an empty string: a reading the dictionary
    /// vouched for has nothing to explain, and `nil` says that plainly
    /// where `""` would read as a missing translation.
    static func caveat(for source: ReadingSource) -> LocalizedStringKey? {
        switch source {
        case .dictionary:
            nil
        case .ambiguous:
            "This word has more than one pronunciation. The most common one is shown."
        case .composed:
            """
            Assembled from the individual characters, because the dictionary \
            has no entry for this word.
            """
        }
    }
}
