// HanReader — MIT licensed. See LICENSE.

import Foundation
import HanReaderCore
import HanReaderPersistence

/// `HanReaderCore.LibraryItem` under a name SwiftUI does not also use.
///
/// SwiftUI has a `LibraryItem` of its own, for Xcode's view library, so the
/// bare name is ambiguous in any file that imports both. Qualifying does not
/// help: this package's namespace enum is also called `HanReaderCore`, so
/// `HanReaderCore.LibraryItem` resolves to a member of the enum rather than
/// of the module. The alias is declared here because this file does not
/// import SwiftUI, which is the only place the name is unambiguous.
typealias LibraryListItem = LibraryItem

/// What happened when the reader imported a file.
///
/// A value rather than a thrown error for the duplicate case, because it is
/// not a failure: the text is in the library, and the right response is to
/// open it and say so.
enum LibraryImportResult: Sendable, Hashable {
    case imported(TextID)
    /// The same *content* was already there.
    ///
    /// Deduplicated on content, never on title. The prototype matched on
    /// title and then silently did nothing, so importing a second chapter
    /// saved as `chapter.txt` looked like the app had ignored the file.
    case alreadyPresent(TextID)
}

/// The library list, and what can be done to it.
@Observable
@MainActor
final class LibraryModel {
    private let services: AppServices

    private(set) var items: [LibraryItem] = []
    private(set) var isLoading = false

    /// Which load is the current one.
    ///
    /// A load can overlap an import or a delete — both of which reload — and
    /// the awaits make the finishing order independent of the starting one.
    /// Without this, an older snapshot resuming last puts the list back to
    /// how it was before the import, and whichever load finishes first turns
    /// the spinner off while the other is still running.
    private var loadGeneration = 0
    /// The most recent failure, for the UI to surface and dismiss.
    var error: (any Error)?

    init(services: AppServices) {
        self.services = services
    }

    func load() async {
        loadGeneration += 1
        let generation = loadGeneration
        isLoading = true
        defer {
            if generation == loadGeneration {
                isLoading = false
            }
        }
        do {
            let loaded = try await services.library.items()
            guard generation == loadGeneration else { return }
            items = loaded
        } catch {
            guard generation == loadGeneration else { return }
            Log.error("library", "could not read the library: \(error)")
            self.error = error
        }
    }

    /// Imports text that has already been read and decoded.
    ///
    /// Takes a string rather than a URL because reading and decoding is
    /// `FileIngest`'s job, and because the encoding picker sits between the
    /// two: a file that cannot be identified is decoded a second time with
    /// the reader's choice before it ever gets here.
    func importText(
        title: String,
        content: String,
        sourceName: String? = nil,
    ) async
        -> LibraryImportResult?
    {
        do {
            let outcome = try await services.library.importText(
                title: title,
                content: content,
                sourceName: sourceName,
            )
            await load()
            return switch outcome {
            case let .imported(id): .imported(id)
            case let .alreadyPresent(id): .alreadyPresent(id)
            }
        } catch {
            Log.error("library", "could not import \(title): \(error)")
            self.error = error
            return nil
        }
    }

    func delete(_ id: TextID) async {
        do {
            try await services.library.delete(id)
            await load()
        } catch {
            Log.error("library", "could not delete a text: \(error)")
            self.error = error
        }
    }

    /// A title for an imported file.
    ///
    /// The file's name without its extension, falling back to the first line
    /// of the text. Titles need not be unique — deduplication is on content —
    /// so there is no disambiguating suffix to invent here.
    static func title(forFileNamed name: String, content: String) -> String {
        let stem = (name as NSString).deletingPathExtension
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // A stem starting with a dot means the whole name was an extension
        // (`.txt`) or the file was hidden (`.notes.txt`). Either way the
        // first line of the text is a better title than a leading dot, which
        // in a sidebar just looks broken.
        if !stem.isEmpty, !stem.hasPrefix(".") {
            return stem
        }
        let firstLine = content
            .prefix(while: { !$0.isNewline })
            .trimmingCharacters(in: .whitespaces)
        return firstLine.isEmpty ? "Untitled" : String(firstLine.prefix(60))
    }
}
