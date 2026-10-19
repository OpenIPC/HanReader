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
    /// Slug to display name, so an answer can say which dictionary it came
    /// from. Attribution is a licence obligation for CC BY-SA data, not a
    /// nicety, and it has to reach the reader where they read the gloss.
    var dictionaryNames: [String: String] = [:]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                if detail.isDefined {
                    ForEach(Array(detail.orderedGroups.enumerated()), id: \.offset) { _, group in
                        groupView(group)
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

    /// One reading, with every dictionary's answer for it.
    ///
    /// The reading heads the group rather than repeating on each answer:
    /// 了's two dictionaries both say `le`, and printing it twice implies
    /// they are two readings.
    private func groupView(_ group: ReadingGroup) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(verbatim: group.readingDisplay)
                    .font(.headline)
                if let traditional = Self.traditional(in: group) {
                    // Shown only when the two forms actually differ, which is
                    // true for 63% of CC-CEDICT. Printing the same characters
                    // twice for the rest would be noise.
                    Text(verbatim: traditional)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(Text("Traditional form"))
                }
            }
            ForEach(Array(group.entries.enumerated()), id: \.offset) { _, attributed in
                answerView(attributed)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func answerView(_ attributed: AttributedEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let name = dictionaryNames[attributed.dictionary] {
                Text(verbatim: name)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(Text("From \(name)"))
            }
            ForEach(attributed.entry.senses) { sense in
                senseView(sense)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// One sense, indented by how deeply the dictionary nested it.
    ///
    /// The indent is the whole reason `Sense` carries a level: BKRS writes
    /// Roman-numeral divisions with numbered senses beneath them and examples
    /// beneath those, and flattening that is what made the predecessor's
    /// definitions unreadable.
    private func senseView(_ sense: Sense) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(verbatim: sense.label ?? "\(sense.id + 1).")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.tertiary)
            VStack(alignment: .leading, spacing: 2) {
                if !sense.partOfSpeech.isEmpty || !sense.registers.isEmpty {
                    Text(verbatim: (sense.partOfSpeech + sense.registers)
                        .joined(separator: " "))
                        .font(.caption.italic())
                        .foregroundStyle(.secondary)
                }
                Text(verbatim: sense.gloss.text)
                    .font(.callout)
                    .textSelection(.enabled)
                ForEach(Array(sense.examples.enumerated()), id: \.offset) { _, example in
                    Text(verbatim: example.raw)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(.leading, Double(sense.level) * 14)
    }

    /// The traditional spelling, if any dictionary in the group gives one
    /// that differs.
    private static func traditional(in group: ReadingGroup) -> String? {
        group.entries
            .first { $0.entry.headword.scriptsDiffer }?
            .entry.headword.traditionalOrSimplified
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
