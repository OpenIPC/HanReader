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
    let services: AppServices
    let settings: Settings
    let speech: SpeechModel

    @State private var model: ReaderModel?
    @State private var isInspectorPresented = false

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
            .task(id: textID) {
                // The previous model is closed before the next is built.
                // `.task(id:)` cancels its own task when the id changes, but
                // the unstructured work the model holds -- the debounced
                // position save, the reading window, the detail lookup --
                // has no relationship to it, so switching texts in the
                // sidebar would leave the old text's work running and its
                // position unwritten.
                if let previous = model {
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
            }
            .onDisappear {
                // An utterance outlives the view that started it: the
                // synthesizer is app-scoped, so without this a word spoken
                // in one text carries on into the next.
                speech.stop()
                let model = model
                Task { await model?.close() }
            }
            .onChange(of: scenePhase) { _, phase in
                // The position save is debounced, so going to the background
                // with one in flight loses it. On iOS the app may not be
                // running again afterwards to write it.
                guard phase != .active, let model else { return }
                Task { await model.flushPosition() }
            }
            .toolbar { toolbar }
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
                    speech.speak(token.text, suppressed: voiceOverEnabled)
                }
            },
            topBlock: $model.topBlock,
        )
        .modifier(DetailPanelPlacement(isCompact: sizeClass == .compact) {
            WordDetailPanel(
                state: model.detail,
                style: style,
                onExpand: { isInspectorPresented = true },
                onSpeak: { speech.speak($0, suppressed: voiceOverEnabled) },
            )
        })
        // One modifier for both platforms. On a regular width this is a side
        // panel; on a compact one SwiftUI presents it as a sheet by itself,
        // which is exactly the behaviour wanted and needs no `#if os(`.
        .inspector(isPresented: $isInspectorPresented) {
            if case let .loaded(detail) = model.detail {
                WordDetailContent(
                    detail: detail,
                    style: style,
                    onSpeak: { speech.speak($0, suppressed: voiceOverEnabled) },
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

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
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
