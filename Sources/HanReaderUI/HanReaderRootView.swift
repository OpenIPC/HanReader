// HanReader — MIT licensed. See LICENSE.

import HanReaderCore
import HanReaderPlayback
public import SwiftUI
import UniformTypeIdentifiers

/// The app's databases, settings and synthesizer.
///
/// Held by the `App`, not by a view, and that distinction is the whole
/// point. The predecessor prototype created its `AppModel` inside
/// `ContentView`, which on macOS means **one per window**: two windows meant
/// two database handles, two dictionary caches and two of everything else,
/// each warming separately. An earlier draft of this file reintroduced
/// exactly that by keeping the launch state in `@State` on the root view —
/// a `WindowGroup` builds its content once per window.
///
/// So each platform's `@main` owns one of these and passes it down. Two
/// lines of duplication across the two targets, against a shared mutable
/// singleton or a bug that only appears when somebody opens a second window.
@Observable
@MainActor
public final class HanReaderLaunch {
    /// Internal: the app targets only ever construct this and hand it to
    /// `HanReaderRootView`. Everything it holds is an implementation
    /// detail of this module.
    enum State {
        case loading
        case ready(AppServices, Settings, SpeechModel)
        case failed(String)
    }

    private(set) var state: State = .loading

    public init() {}

    /// Opens the databases. Safe to call repeatedly; only the first does
    /// anything, because every window's root view calls it on appear.
    func start() {
        guard case .loading = state else { return }
        do {
            state = try .ready(AppServices.launch(), Settings(), SpeechModel())
        } catch {
            // Only a failure to open the *library* reaches here. A missing
            // or unreadable dictionary is handled inside `AppServices` and
            // degrades to a reader with no annotations, because refusing to
            // launch would turn a degraded reader into no reader.
            Log.error("launch", "could not open the library: \(error)")
            state = .failed(error.localizedDescription)
        }
    }
}

/// The application's root view, shared by both targets.
public struct HanReaderRootView: View {
    private let launch: HanReaderLaunch
    @State private var selection: TextID?

    public init(launch: HanReaderLaunch) {
        self.launch = launch
    }

    public var body: some View {
        switch launch.state {
        case .loading:
            // Opening a prepared dictionary container takes about a
            // millisecond, so there is nothing worth showing a spinner for.
            Color.clear
                .task { launch.start() }
        case let .failed(message):
            ContentUnavailableView(
                "HanReader could not start",
                systemImage: "exclamationmark.triangle",
                description: Text(verbatim: message),
            )
        case let .ready(services, settings, speech):
            LibraryAndReader(
                services: services,
                settings: settings,
                speech: speech,
                selection: $selection,
            )
        }
    }
}

/// The library beside the reader.
private struct LibraryAndReader: View {
    let services: AppServices
    let settings: Settings
    let speech: SpeechModel
    @Binding var selection: TextID?

    @State private var library: LibraryModel
    @State private var importer: TextImporter
    @State private var isFileImporterPresented = false
    @State private var duplicateNotice = false

    /// Whichever failure is outstanding.
    ///
    /// The library's errors were previously recorded and never shown, so a
    /// library that failed to load looked like a library with nothing in it,
    /// and a failed deletion looked like a deletion that had worked.
    private var failure: String? {
        importer.error ?? library.error?.localizedDescription
    }

    private func clearFailure() {
        importer.error = nil
        library.clearError()
    }

    init(
        services: AppServices,
        settings: Settings,
        speech: SpeechModel,
        selection: Binding<TextID?>,
    ) {
        self.services = services
        self.settings = settings
        self.speech = speech
        _selection = selection
        let library = LibraryModel(services: services)
        _library = State(initialValue: library)
        _importer = State(initialValue: TextImporter(library: library))
    }

    var body: some View {
        NavigationSplitView {
            LibrarySidebar(
                model: library,
                selection: $selection,
                onImport: { isFileImporterPresented = true },
            )
            .navigationSplitViewColumnWidth(
                min: 200,
                ideal: ReaderMetrics.sidebarWidth,
                max: 360,
            )
        } detail: {
            if let selection {
                ReaderScreen(
                    textID: selection,
                    services: services,
                    settings: settings,
                    speech: speech,
                )
            } else {
                ContentUnavailableView(
                    "Choose a text",
                    systemImage: "text.book.closed",
                    description: Text("Or import one to start reading."),
                )
            }
        }
        .task { await library.load() }
        // `.fileImporter` is identical on both platforms and handles the
        // security-scoped URL itself, which is why there is no `NSOpenPanel`
        // anywhere in this project and no platform branch here.
        .fileImporter(
            isPresented: $isFileImporterPresented,
            allowedContentTypes: [.plainText, .text, .utf8PlainText],
        ) { result in
            switch result {
            case let .success(url):
                Task { await importer.open(url) }
            case let .failure(error):
                importer.error = error.localizedDescription
            }
        }
        .sheet(isPresented: Binding(
            get: { importer.pending != nil },
            set: {
                if !$0 {
                    importer.cancel()
                }
            },
        )) {
            if let pending = importer.pending {
                EncodingPicker(
                    fileName: pending.fileName,
                    previews: pending.previews,
                    onPick: { encoding in Task { await importer.resolve(as: encoding) } },
                    onCancel: { importer.cancel() },
                )
            }
        }
        .onChange(of: importer.imported) { _, imported in
            guard let imported else { return }
            selection = imported
            importer.acknowledge()
        }
        .alert(
            "This file could not be imported",
            isPresented: Binding(
                get: { importer.error != nil },
                set: {
                    if !$0 {
                        importer.error = nil
                    }
                },
            ),
            presenting: importer.error,
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { message in
            Text(verbatim: message)
        }
    }
}
