// HanReader — MIT licensed. See LICENSE.

import HanReaderCore
import HanReaderPlayback
public import SwiftUI
import UniformTypeIdentifiers

/// The application's root view, shared by both targets.
///
/// Owns the app-scoped state: the services, the settings and the speech
/// synthesizer, created **once** here rather than inside a content view. The
/// prototype created its `AppModel` inside `ContentView`, which on macOS
/// means one per window — two windows meant two dictionary handles and two
/// caches warming separately.
public struct HanReaderRootView: View {
    public init() {}

    public var body: some View {
        RootContent()
    }
}

/// What happened when the app tried to open its databases.
private enum LaunchState {
    case loading
    case ready(AppServices, Settings, SpeechModel)
    case failed(String)

    @MainActor
    static func start() -> Self {
        do {
            return try .ready(AppServices.launch(), Settings(), SpeechModel())
        } catch {
            // Only a failure to open the *library* reaches here. A missing
            // or unreadable dictionary is handled inside `AppServices` and
            // degrades to a reader with no annotations, because refusing to
            // launch would turn a degraded reader into no reader.
            Log.error("launch", "could not open the library: \(error)")
            return .failed(error.localizedDescription)
        }
    }
}

private struct RootContent: View {
    @State private var launch = LaunchState.loading
    @State private var selection: TextID?

    var body: some View {
        switch launch {
        case .loading:
            // Opening a prepared dictionary container takes about a
            // millisecond, so there is nothing worth showing a spinner for.
            Color.clear
                .task { launch = LaunchState.start() }
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
