// HanReader — MIT licensed. See LICENSE.

import Foundation
import HanReaderCore
import HanReaderDictionaryImport
import HanReaderPersistence

/// Compiles a dictionary the reader picked, and says how far it has got.
///
/// A long operation by any standard — the set this was built for is 350 MB
/// and takes over a minute — so three things are not optional: progress the
/// reader can believe, a Cancel that leaves the work done so far intact, and
/// resuming where it stopped rather than starting again.
///
/// The import writes straight into the dictionaries directory under the name
/// the finished container will have. That is what makes resuming work: a
/// second run picks the same destination, finds the job row inside it, and
/// continues. Writing to a temporary file and moving it on success would
/// throw away a minute of work every time the reader changed their mind.
@Observable
@MainActor
final class DictionaryImportModel {
    enum Phase: Equatable {
        case idle
        /// Reading the set's headers to find out what it is.
        case preparing
        case importing(DSLImportProgress)
        /// Stopped at a card boundary, with everything so far committed.
        case cancelled(entries: Int)
        case finished(DSLImportSummary)
        case failed(String)
    }

    private(set) var phase: Phase = .idle

    /// What the reader is importing, as soon as the file says so.
    private(set) var name: String?

    private let services: AppServices
    private var task: Task<Void, Never>?
    /// Read by the importer on its own thread, written here. A box rather
    /// than a captured flag, because the importer asks for it from the thread
    /// doing the parsing.
    private let stopFlag = StopFlag()

    init(services: AppServices) {
        self.services = services
    }

    var isRunning: Bool {
        switch phase {
        case .preparing, .importing: true
        default: false
        }
    }

    // MARK: - Running

    /// - Parameter onFinished: run once, when the import stops for any
    ///   reason. The caller reads the dictionaries again there; doing it from
    ///   a view's `.task(id: phase)` instead would re-run ten times a second,
    ///   because progress *is* the phase.
    func start(_ url: URL, onFinished: @escaping () async -> Void) {
        guard !isRunning else { return }
        stopFlag.reset()
        phase = .preparing
        // The file the reader picked, straight away, replaced by what the
        // dictionary calls itself once its header has been read. A
        // three-volume set is picked by its first file and called something
        // else entirely, so the declared name is the better one — but it
        // takes a disk read to learn, and a reader should never be watching
        // an unnamed progress bar.
        name = url.lastPathComponent

        task = Task { [services, stopFlag] in
            do {
                // The reader picked this file, so access is scoped to that
                // choice. The importer reads it for a minute, which is well
                // past the point where an unscoped URL stops working.
                let scoped = url.startAccessingSecurityScopedResource()
                defer {
                    if scoped {
                        url.stopAccessingSecurityScopedResource()
                    }
                }

                let fileSet = try DSLFileSet.discover(from: url)
                let slug = DSLImporter.slug(for: fileSet)
                let directory = services.locations.dictionaryDirectory
                // Written under a name of its own until it is finished, so a
                // reader re-importing a dictionary they already have keeps
                // the one they have until the new one is complete.
                let destination = DictionaryCatalogue.partialFile(
                    forSlug: slug,
                    in: directory,
                )
                await MainActor.run {
                    self.name = DSLImporter.displayName(for: fileSet)
                }

                let importer = DSLImporter(
                    fileSet: fileSet,
                    destination: destination,
                    syllableBases: services.catalogue.syllableBases(),
                )
                let summary = try await Task.detached(priority: .utility) {
                    try importer.run(
                        progress: { progress in
                            Task { @MainActor in self.report(progress) }
                        },
                        shouldContinue: { !stopFlag.isSet },
                    )
                }.value

                if summary.completed {
                    try Self.install(destination, as: slug, in: directory)
                    phase = .finished(summary)
                } else {
                    phase = .cancelled(entries: summary.entriesWritten)
                }
            } catch {
                phase = .failed(String(describing: error))
            }
            // Always, including after a failure: a run that threw may still
            // have left a part-written container, and a list that does not
            // mention it is a list the reader cannot act on.
            await onFinished()
        }
    }

    /// Puts a finished container where the reader's dictionaries live,
    /// replacing any earlier copy in one step.
    ///
    /// `replaceItemAt` rather than remove-then-move: the moment between the
    /// two is a moment with no dictionary, and a crash in it loses one the
    /// reader already had.
    private static func install(_ partial: URL, as slug: String, in directory: URL) throws {
        let destination = DictionaryCatalogue.finishedFile(forSlug: slug, in: directory)
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: partial)
        } else {
            try FileManager.default.moveItem(at: partial, to: destination)
        }
    }

    /// Stops at the next card boundary.
    ///
    /// Not a cancellation: everything committed stays, the job row stays, and
    /// starting the same import again carries on from there. A reader who
    /// stops a minute-long import and restarts it should not pay for it
    /// twice.
    func stop() {
        stopFlag.set()
    }

    /// Reports a failure that happened before the import could start, such
    /// as the file picker handing back an error instead of a URL.
    func fail(_ message: String) {
        phase = .failed(message)
    }

    /// Forgets a finished or failed import, so the sheet can be used again.
    func reset() {
        task?.cancel()
        task = nil
        phase = .idle
        name = nil
    }

    private func report(_ progress: DSLImportProgress) {
        guard isRunning else { return }
        phase = .importing(progress)
    }
}

/// A flag set on one thread and read on another.
///
/// The importer asks whether to continue from the thread doing the parsing,
/// which is not the main actor; a lock is the smallest thing that makes that
/// sound.
private final nonisolated class StopFlag: Sendable {
    private let lock = NSLock()
    private nonisolated(unsafe) var value = false

    var isSet: Bool {
        lock.withLock { value }
    }

    func set() {
        lock.withLock { value = true }
    }

    func reset() {
        lock.withLock { value = false }
    }
}
