// HanReader — MIT licensed. See LICENSE.

import HanReaderCore
import HanReaderPersistence
import SwiftUI
import UniformTypeIdentifiers

/// The dictionaries the reader has, and what each is allowed to do.
///
/// Also where attribution lives, which is not a detail: CC-CEDICT is CC BY-SA
/// and its licence and attribution have to reach the reader. Both are read
/// from each container's own `meta`, so this screen is correct for a
/// dictionary the reader imported as well as for the one shipped with the
/// app — including one whose licence the app has never heard of.
struct DictionariesScreen: View {
    let services: AppServices
    /// Owned above this sheet, deliberately. As sheet-local state, closing
    /// the sheet discarded the model and its Stop button while the import
    /// carried on writing — and reopening it offered a fresh model that
    /// would happily start the same import a second time, two writers
    /// resuming from one checkpoint into one file.
    let importModel: DictionaryImportModel
    let onChange: () async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var isFileImporterPresented = false
    @State private var removing: InstalledDictionary?

    private var installed: [InstalledDictionary] {
        services.catalogue.installed.sorted { $0.sortOrder < $1.sortOrder }
    }

    var body: some View {
        NavigationStack {
            // The import banner sits above the list rather than in it. A
            // list row on macOS is as tall as it believes its content to be,
            // and it does not believe a progress view with a label and a
            // button: the dictionary's name and the file-and-entry count
            // were clipped away above the bar, leaving an unlabelled line
            // creeping across the screen.
            VStack(spacing: 0) {
                if importModel.phase != .idle {
                    importStatus
                        .padding(.horizontal)
                        .padding(.vertical, 12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Divider()
                }
                List {
                    Section("Installed") {
                        ForEach(installed, id: \.slug) { entry in
                            row(for: entry)
                        }
                        // An ordinary row rather than a section footer: a
                        // footer in a macOS list is given one line and the
                        // rest of the sentence is simply cut off, which for
                        // the paragraph explaining the three switches is the
                        // whole of it.
                        Text("""
                        The order decides which dictionary answers first. A \
                        dictionary can supply definitions, readings, or the \
                        word list your text is split into — separately, \
                        because a dictionary you do not read can still be \
                        the one that knows how a character is pronounced.
                        """)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    problems
                }
            }
            .navigationTitle("Dictionaries")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem {
                    Button("Import…", systemImage: "plus") {
                        isFileImporterPresented = true
                    }
                    .disabled(importModel.isRunning)
                }
            }
            .fileImporter(
                isPresented: $isFileImporterPresented,
                allowedContentTypes: Self.dslTypes,
            ) { result in
                switch result {
                case let .success(url):
                    importModel.start(url) { await onChange() }
                case let .failure(error):
                    // Shown where an import failure is shown, because to the
                    // reader "I could not open that file" is one outcome
                    // however it arose.
                    importModel.fail(error.localizedDescription)
                }
            }
            .confirmationDialog(
                "Remove this dictionary?",
                isPresented: Binding(get: { removing != nil }, set: {
                    if !$0 {
                        removing = nil
                    }
                }),
                presenting: removing,
            ) { entry in
                Button("Remove \(entry.metadata.displayName)", role: .destructive) {
                    Task { await remove(entry) }
                }
            } message: { entry in
                Text("""
                \(entry.metadata.displayName) will be deleted from this \
                device. You can import it again from the original file.
                """)
            }
        }
        // A sheet on macOS sizes itself to its content, and a `List` has no
        // height to offer, so without this the sheet opens as a title bar
        // with nothing under it. Ideal rather than minimum width, because a
        // minimum wide enough to be useful on a Mac is wider than an iPhone
        // SE — and this screen needs no platform branch for anything else.
        .frame(idealWidth: 540, minHeight: 420, idealHeight: 620)
    }

    /// Files in the directory that are not usable dictionaries, kept apart
    /// by why. Listed rather than hidden: a reader whose dictionary stopped
    /// working should be told which one and what to do about it.
    @ViewBuilder
    private var problems: some View {
        if !services.catalogue.unfinished.isEmpty {
            Section("Unfinished") {
                ForEach(services.catalogue.unfinished, id: \.self) { file in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: file.lastPathComponent)
                        Text("""
                        This import stopped before it finished. \
                        Import the same file again to carry on from \
                        where it stopped.
                        """)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        if !services.catalogue.unreadable.isEmpty {
            Section("Not readable") {
                ForEach(services.catalogue.unreadable, id: \.file) { failure in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: failure.file.lastPathComponent)
                        Text(verbatim: failure.reason)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: - Changing things

    private func update(
        _ entry: InstalledDictionary,
        _ permission: LibraryRepository.DictionaryPermission,
        to value: Bool,
    ) async {
        do {
            try await services.library.setDictionaryPermission(
                permission,
                to: value,
                matching: DictionaryPreference(
                    slug: entry.slug,
                    providesGlosses: entry.providesGlosses,
                    providesReadings: entry.providesReadings,
                    providesLexicon: entry.providesLexicon,
                    sortOrder: entry.sortOrder,
                ),
            )
            await onChange()
        } catch {
            Log.error("dictionaries", "could not save a preference: \(error)")
        }
    }

    private func remove(_ entry: InstalledDictionary) async {
        removing = nil
        // Whatever happens below, the dictionaries are read again. Half a
        // removal — the file gone, the preference left, or the other way
        // round — still has to reach the open reader, which is otherwise
        // still answering from a container that is no longer there.
        defer { Task { await onChange() } }
        do {
            try FileManager.default.removeItem(at: entry.file)
        } catch {
            Log.error("dictionaries", "could not delete \(entry.slug): \(error)")
        }
        do {
            // And the reader's opinion about it, since they asked for it to
            // be gone rather than for it to be temporarily unavailable.
            try await services.library.forgetDictionary(entry.slug)
        } catch {
            Log.error("dictionaries", "could not forget \(entry.slug): \(error)")
        }
    }

    /// What a DSL dictionary looks like to the file picker.
    ///
    /// `.dsl` is not a type the system knows, so it is declared by extension
    /// rather than by identifier — and `.data` is included because a file the
    /// system cannot classify at all must still be choosable.
    static let dslTypes: [UTType] = [
        UTType(filenameExtension: "dsl") ?? .data,
        .data,
    ]
}

// MARK: - One dictionary, and the import running over it

/// The rows. Split out because the screen's job is the list and the sheet's
/// chrome, and these are what a row looks like.
extension DictionariesScreen {
    private func row(for entry: InstalledDictionary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: entry.metadata.displayName)
                    .font(.headline)
                Spacer()
                Text(entry.metadata.entryCount, format: .number)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(Text("\(entry.metadata.entryCount) entries"))
            }
            Text(verbatim: "\(entry.metadata.indexLanguage) → \(entry.metadata.glossLanguage)")
                .font(.caption)
                .foregroundStyle(.secondary)

            permission("Definitions", isOn: entry.providesGlosses) {
                await update(entry, .glosses, to: !entry.providesGlosses)
            }
            permission("Readings", isOn: entry.providesReadings) {
                await update(entry, .readings, to: !entry.providesReadings)
            }
            permission("Word list", isOn: entry.providesLexicon) {
                await update(entry, .lexicon, to: !entry.providesLexicon)
            }

            // The licence obligation, in the reader's hands rather than in a
            // file they will never open.
            DisclosureGroup("Licence and attribution") {
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: entry.metadata.licence)
                        .font(.caption.weight(.medium))
                    Text(verbatim: entry.metadata.attribution)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.caption)

            if !entry.isBuiltIn {
                Button("Remove…", role: .destructive) { removing = entry }
                    .font(.caption)
            }
        }
        .padding(.vertical, 4)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func permission(
        _ title: LocalizedStringKey,
        isOn: Bool,
        toggle: @escaping () async -> Void,
    )
        -> some View
    {
        Toggle(title, isOn: Binding(get: { isOn }, set: { _ in Task { await toggle() } }))
            .font(.callout)
            .toggleStyle(.switch)
            .controlSize(.mini)
    }

    private var importStatus: some View {
        // `.fixedSize` vertically, or the row is as tall as a list row and
        // the rest — the dictionary's name, the file and entry count — is
        // simply clipped away above the progress bar.
        VStack(alignment: .leading, spacing: 6) {
            if let name = importModel.name {
                Text(verbatim: name).font(.headline)
            }
            switch importModel.phase {
            case .idle:
                EmptyView()
            case .preparing:
                // Reading the headers of a three-volume set, which is a
                // chunk each rather than the whole file.
                ProgressView("Reading the dictionary…")
            case let .importing(progress):
                ProgressView(value: progress.fraction) {
                    Text("""
                    File \(progress.fileIndex + 1) of \(progress.fileCount), \
                    \(progress.entriesWritten) entries
                    """)
                    .font(.caption.monospacedDigit())
                }
                Button("Stop", role: .cancel) { importModel.stop() }
                    .font(.caption)
                // Said plainly, because a reader who stops a minute-long
                // import has every reason to assume they have lost it.
                Text("Stopping keeps what has been imported so far.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case let .cancelled(entries):
                Text("Stopped after \(entries) entries. Import it again to carry on.")
                    .font(.caption)
                Button("Dismiss") { importModel.reset() }.font(.caption)
            case let .finished(summary):
                Text("Imported \(summary.entriesWritten) entries.")
                    .font(.caption)
                ForEach(summary.discovery, id: \.text) { diagnostic in
                    // A volume an `#INCLUDE` named but that was not there
                    // means a dictionary missing part of itself, which is
                    // the failure a reader would never notice on their own.
                    Text(verbatim: diagnostic.text)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Button("Dismiss") { importModel.reset() }.font(.caption)
            case let .failed(message):
                Text(verbatim: message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                Button("Dismiss") { importModel.reset() }.font(.caption)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
