// HanReader — MIT licensed. See LICENSE.

import HanReaderCore
import SwiftUI

/// The list of imported texts.
struct LibrarySidebar: View {
    let model: LibraryModel
    @Binding var selection: TextID?
    let onImport: () -> Void

    var body: some View {
        List(selection: $selection) {
            ForEach(model.items) { item in
                row(item)
                    .tag(item.id)
                    .contextMenu {
                        Button(role: .destructive) {
                            Task { await model.delete(item.id) }
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
            }
        }
        .overlay {
            if model.items.isEmpty, !model.isLoading {
                ContentUnavailableView {
                    Label("No texts yet", systemImage: "text.book.closed")
                } description: {
                    Text("Import a Chinese .txt file to start reading.")
                } actions: {
                    Button("Import a text…", action: onImport)
                }
            }
        }
        .navigationTitle(Text(verbatim: "HanReader"))
        .toolbar {
            ToolbarItem {
                Button(action: onImport) {
                    Label("Import a text…", systemImage: "plus")
                }
            }
        }
    }

    private func row(_ item: LibraryListItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(verbatim: item.title)
                    .font(.headline)
                    .lineLimit(1)
                if item.hasAudio {
                    Image(systemName: "waveform")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(Text("Has audio"))
                }
            }
            // The stored preview, never the content. The prototype selected
            // the full text of every row to render this line, so opening the
            // sidebar loaded the whole library.
            Text(verbatim: item.preview)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            if let progress = item.progress, progress > 0 {
                ProgressView(value: progress)
                    .controlSize(.mini)
                    .accessibilityLabel(Text("Reading progress"))
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}
