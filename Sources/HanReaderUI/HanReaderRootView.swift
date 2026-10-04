// HanReader — MIT licensed. See LICENSE.

import HanReaderCore
public import SwiftUI

/// The application's root view, shared by both targets.
///
/// At this point in M5 it hosts the reading surface over the built-in
/// fixtures, with no library, no dictionary and no models of any kind. That is
/// the sequencing the plan calls for, and it is not merely convenient: the
/// hardest part of this app is the reading surface, and building it against
/// values — with nothing observable in sight — is what forces the layout to
/// take plain values rather than read a model. Discovering that requirement
/// after the state exists means unpicking it from the layout.
///
/// The library, the dictionary-backed detail panel, text import and speech
/// replace the fixture wiring below in the following pull requests.
public struct HanReaderRootView: View {
    public init() {}

    public var body: some View {
        FixtureReader()
    }
}

/// The reading surface over the built-in fixtures.
///
/// Scaffolding, and deliberately shaped like what replaces it: the selection
/// and reveal state live here rather than in the views, the style is resolved
/// once and passed down as a value, and every input the surface takes is
/// already the input the real model will supply.
struct FixtureReader: View {
    @State private var fontSize = 22.0
    @State private var spacing = WordSpacing.separated
    @State private var selection: TokenID?
    @State private var revealedWords: Set<String> = []
    @State private var topBlock: Int?

    /// Dynamic Type as a number.
    ///
    /// `@ScaledMetric` is the only way to read the user's text-size setting as
    /// a ratio — `DynamicTypeSize` is an ordered enum with no numeric value,
    /// and hard-coding a table of multipliers would drift from whatever the
    /// system actually does. Scaling a round number and dividing gives the
    /// real factor.
    @ScaledMetric(relativeTo: .body) private var textScaleProbe = 100.0

    private var style: ReaderStyle {
        ReaderStyle(
            fontSize: fontSize,
            spacing: spacing,
            textScale: textScaleProbe / 100,
        )
    }

    private var document: SegmentedDocument {
        ReaderFixtures.prose
    }

    /// Tokens whose readings are shown.
    ///
    /// Every occurrence of a revealed word, which is the prototype's default
    /// behaviour and so what fidelity requires — but derived here from a set
    /// of *words*, with the selected token tracked separately. That separation
    /// is what makes tapping a second instance of an already-revealed word
    /// select it instead of appearing to do nothing.
    private var revealed: Set<TokenID> {
        var tokens = ReaderFixtures.tokens(matching: revealedWords, in: document)
        if let selection {
            tokens.insert(selection)
        }
        return tokens
    }

    var body: some View {
        ReaderSurface(
            document: document,
            style: style,
            readings: ReaderFixtures.readings(for: document),
            selection: selection,
            revealed: revealed,
            onTap: select,
            topBlock: $topBlock,
        )
        .safeAreaInset(edge: .bottom, spacing: 0) {
            FixtureDetailPanel(token: selection.flatMap { document[$0] }, style: style)
        }
        .toolbar { controls }
        .navigationTitle(Text(verbatim: "HanReader"))
    }

    @ToolbarContentBuilder
    private var controls: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Picker(selection: $spacing) {
                Text("Separated words").tag(WordSpacing.separated)
                Text("Continuous text").tag(WordSpacing.continuous)
            } label: {
                Text("Word spacing")
            }
            .pickerStyle(.segmented)
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                fontSize = min(fontSize + 2, ReaderStyle.fontSizeRange.upperBound)
            } label: {
                Label("Larger text", systemImage: "textformat.size.larger")
            }
            .keyboardShortcut("+", modifiers: .command)
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                fontSize = max(fontSize - 2, ReaderStyle.fontSizeRange.lowerBound)
            } label: {
                Label("Smaller text", systemImage: "textformat.size.smaller")
            }
            .keyboardShortcut("-", modifiers: .command)
        }
    }

    /// Selects a token, and reveals every occurrence of its word.
    ///
    /// Tapping the *same* token again clears the selection and hides the word
    /// again. Tapping a *different* instance of a word that is already
    /// revealed moves the selection and leaves the reveal in place — the fix
    /// for the prototype's single `Set<String>`, where any instance's tap
    /// toggled every instance.
    private func select(_ id: TokenID) {
        guard let token = document[id] else { return }
        if selection == id {
            selection = nil
            revealedWords.remove(token.text)
        } else {
            selection = id
            revealedWords.insert(token.text)
        }
    }
}

/// A placeholder for the word-detail panel.
///
/// Fixed height from the first version, because that is the property that
/// matters and the one most easily lost later: a panel that grows to fit its
/// content pushes the body text down every time a word with a longer
/// definition is tapped. Definitions arrive once the dictionary is wired up;
/// the geometry is settled now.
struct FixtureDetailPanel: View {
    let token: Token?
    let style: ReaderStyle

    @ScaledMetric private var height = ReaderMetrics.detailPanelHeight
    @ScaledMetric private var headwordWidth = ReaderMetrics.detailHeadwordWidth

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            if let token {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: token.text)
                        .font(ReaderFont.base(style))
                    if let reading = ReaderFixtures.readingsByWord[token.text] {
                        Text(verbatim: reading.display)
                            .font(ReaderFont.ruby(style))
                            .foregroundStyle(ReaderColor.ruby)
                    }
                }
                .frame(width: headwordWidth, alignment: .leading)

                Text("Definitions arrive with the dictionary in the next pull request.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Text("Tap a word to see its reading.")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, ReaderMetrics.readingColumnPadding)
        .padding(.vertical, 12)
        .frame(height: height, alignment: .top)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }
}

#Preview("Root view") {
    HanReaderRootView()
        .frame(width: 900, height: 600)
}
