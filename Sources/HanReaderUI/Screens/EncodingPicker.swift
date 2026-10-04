// HanReader — MIT licensed. See LICENSE.

import HanReaderCore
import SwiftUI

/// Asks the reader which encoding a file is in.
///
/// Shown only when detection could not decide. The detector handles
/// byte-order marks conclusively, UTF-8 almost conclusively, and separates
/// GB18030 from Big5 on the private-use characters the wrong one produces —
/// so this is the last resort rather than the normal path.
///
/// It works by **showing the text**, which is the only reliable way to
/// settle it and takes a person about a second. There is no clever
/// presentation here on purpose: the first few hundred characters in each
/// candidate, and the reader picks the one that is not nonsense.
struct EncodingPicker: View {
    let fileName: String
    let previews: [EncodingPreview]
    let onPick: (SourceTextEncoding) -> Void
    let onCancel: () -> Void

    @State private var chosen: SourceTextEncoding?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if previews.isEmpty {
                ContentUnavailableView(
                    "This file does not look like text",
                    systemImage: "doc.questionmark",
                    description: Text(
                        """
                        No text encoding could read it. It may be a PDF, an \
                        ebook or an archive rather than a plain text file.
                        """,
                    ),
                )
                .frame(maxHeight: .infinity)
            } else {
                list
            }
            Divider()
            footer
        }
        .frame(minWidth: 420, minHeight: 440)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Which encoding is this file?")
                .font(.headline)
            Text(verbatim: fileName)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("Pick the one that reads as Chinese rather than as nonsense.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
    }

    private var list: some View {
        List(previews, selection: $chosen) { preview in
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: preview.encoding.displayName)
                    .font(.headline)
                Text(verbatim: preview.preview)
                    .font(.callout)
                    .lineLimit(6)
                    .foregroundStyle(.primary)
            }
            .padding(.vertical, 4)
            .tag(preview.encoding)
            .contentShape(.rect)
            .onTapGesture { chosen = preview.encoding }
        }
    }

    private var footer: some View {
        HStack {
            Button("Cancel", role: .cancel, action: onCancel)
                .keyboardShortcut(.cancelAction)
            Spacer()
            Button("Import") {
                if let chosen {
                    onPick(chosen)
                }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(chosen == nil)
        }
        .padding(20)
    }
}
