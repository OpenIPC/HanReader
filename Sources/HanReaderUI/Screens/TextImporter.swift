// HanReader — MIT licensed. See LICENSE.

import Foundation
import HanReaderCore
import HanReaderPlatform

/// Drives importing a file, including the encoding question.
///
/// A model rather than a pile of `@State` in the root view, because the flow
/// has three outcomes and two of them need to be remembered between
/// presentations: the file imported, the file needs a decision, the file is
/// not text at all.
@Observable
@MainActor
final class TextImporter {
    private let library: LibraryModel

    /// Set when a file could not be identified, which puts the picker on
    /// screen. Holds the URL so the chosen encoding can be applied to the
    /// same file rather than to a copy of its bytes.
    private(set) var pending: PendingImport?
    /// Set when something went wrong that the reader should see.
    var error: String?
    /// The text to open after a successful import.
    private(set) var imported: TextID?
    /// True when the import found the text already in the library, so the
    /// UI can say so rather than appearing to do nothing — which is exactly
    /// what the prototype did whenever two files shared a title.
    private(set) var wasAlreadyPresent = false

    struct PendingImport: Equatable {
        let url: URL
        let fileName: String
        let previews: [EncodingPreview]
    }

    init(library: LibraryModel) {
        self.library = library
    }

    /// Imports the file the reader picked.
    func open(_ url: URL) async {
        do {
            let detected = try FileIngest.readText(at: url)
            await store(detected.text, from: url)
        } catch let TextImportError.undeterminedEncoding(previews) {
            pending = PendingImport(
                url: url,
                fileName: url.lastPathComponent,
                previews: previews,
            )
        } catch {
            Log.error("import", "could not read \(url.lastPathComponent): \(error)")
            self.error = error.localizedDescription
        }
    }

    /// Imports the pending file with the encoding the reader chose.
    func resolve(as encoding: SourceTextEncoding) async {
        guard let pending else { return }
        self.pending = nil
        do {
            // Decoded again from the file rather than reusing the preview.
            // The preview is a truncated sample by design, so using it would
            // import the first few hundred characters of the book.
            let detected = try FileIngest.readText(at: pending.url, as: encoding)
            await store(detected.text, from: pending.url)
        } catch {
            Log.error("import", "could not read \(pending.fileName) as \(encoding): \(error)")
            self.error = error.localizedDescription
        }
    }

    func cancel() {
        pending = nil
    }

    func acknowledge() {
        imported = nil
        wasAlreadyPresent = false
    }

    private func store(_ content: String, from url: URL) async {
        let name = url.lastPathComponent
        let result = await library.importText(
            title: LibraryModel.title(forFileNamed: name, content: content),
            content: content,
            sourceName: name,
        )
        switch result {
        case let .imported(id):
            imported = id
            wasAlreadyPresent = false
        case let .alreadyPresent(id):
            imported = id
            wasAlreadyPresent = true
        case nil:
            error = library.error?.localizedDescription
        }
    }
}
