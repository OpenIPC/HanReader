// HanReader — MIT licensed. See LICENSE.

import Foundation
import HanReaderCore
import HanReaderPersistence

/// How far a text has got through opening.
enum ReaderPhase: Equatable, Sendable {
    case loading
    case ready
    case failed(String)
}

/// Everything known about the selected word.
struct WordDetail: Equatable, Sendable {
    let word: String
    let reading: TokenReading?
    let entries: [DictionaryEntry]
}

/// What the detail surface should show.
///
/// `loading` is a state in its own right because the prototype had no such
/// thing: it showed "Not found in dictionary" while the dictionary was still
/// being read, which is not a slow answer but a wrong one. A reader who taps
/// a word during startup is told the word does not exist.
enum DetailState: Equatable, Sendable {
    case empty
    case loading(String)
    case loaded(WordDetail)
    case notFound(String)
}

/// One open text.
///
/// Document-scoped, created by the reader screen through `.task(id:)` and
/// thrown away when the text changes. That scoping is not tidiness: it
/// deletes the manual reset bookkeeping the prototype did in `selectText`,
/// and it gives free cancellation of a load already in flight. The prototype
/// kicked off a `Task` from `.onChange` and never cancelled it, so
/// click-scrubbing down the sidebar raced several whole-document loads
/// against each other.
@Observable
@MainActor
final class ReaderModel {
    let textID: TextID
    private let services: AppServices
    private let settings: Settings

    private(set) var phase: ReaderPhase = .loading
    private(set) var document: SegmentedDocument?

    /// Readings keyed by **word**, not by token.
    ///
    /// Bounded by the reader's vocabulary rather than by the length of the
    /// book: a 200,000-character text has perhaps a hundred thousand tokens
    /// and a few thousand distinct words. Keying by token also implies that
    /// two instances of a word could be annotated differently, which nothing
    /// here can decide and so should not be able to express.
    private(set) var readings: [String: TokenReading] = [:]

    private(set) var selection: TokenID?
    private(set) var reveal: RevealSet
    private(set) var detail: DetailState = .empty

    /// The block at the top of the viewport, bound to the scroll position.
    var topBlock: Int? {
        didSet {
            // Only once the text is open. Restoring a saved position assigns
            // this during `load`, and without the phase check that assignment
            // schedules a reading refresh for a window `load` is about to
            // fetch anyway -- both seeing an empty `readings` map, so the
            // whole window is looked up twice every time a position is
            // restored. It would also save the position it had just read.
            guard topBlock != oldValue, phase == .ready else { return }
            scheduleReadingRefresh()
            schedulePositionSave()
        }
    }

    private var restoredAudioTime: Double?
    private var positionSaveTask: Task<Void, Never>?
    private var readingTask: Task<Void, Never>?
    private var detailTask: Task<Void, Never>?
    private let revealWrites = SerialTaskQueue()

    init(textID: TextID, services: AppServices, settings: Settings) {
        self.textID = textID
        self.services = services
        self.settings = settings
        reveal = RevealSet(mode: settings.revealMode)
    }

    // MARK: - Loading

    func load() async {
        phase = .loading
        do {
            guard let content = try await services.library.content(of: textID) else {
                phase = .failed("This text is no longer in your library.")
                return
            }

            // Off the main actor, but *structured*. A `nonisolated async`
            // function runs on the generic executor rather than the caller's
            // actor, which is what moves the work -- and unlike
            // `Task.detached` it stays part of this task tree, so cancelling
            // the load cancels it rather than orphaning it.
            //
            // Honest about the limit: the segmentation pass itself is one
            // synchronous call and nothing can interrupt it part-way.
            // Cancellation is observed either side of it. Making the pass
            // itself interruptible belongs to the segmenter, and would mean
            // deciding what a half-segmented document is -- which, given the
            // tiling invariant, is nothing.
            let segmented = try await Self.segment(content, with: services.segmenter)

            document = segmented
            reveal = try await RevealSet(
                mode: settings.revealMode,
                lemmas: services.library.revealedWords(in: textID),
            )
            let position = try await services.library.position(of: textID)
            restoredAudioTime = position?.audioTime
            topBlock = Self.restoredBlock(from: position, in: segmented)
            phase = .ready

            await refreshReadings()
            try await services.library.markOpened(textID)
        } catch is CancellationError {
            // Another text was opened. Nothing to report and nothing to undo:
            // this model is about to be discarded with the view that owns it.
        } catch {
            Log.error("reader", "could not open text \(textID.rawValue): \(error)")
            phase = .failed(error.localizedDescription)
        }
    }

    /// Segments off the main actor.
    ///
    /// `nonisolated` is what does the work here: this module defaults to
    /// `MainActor`, and a `nonisolated async` function hops to the generic
    /// executor instead of inheriting the caller's actor.
    nonisolated static func segment(
        _ content: String,
        with segmenter: DocumentSegmenter,
    ) async throws
        -> SegmentedDocument
    {
        try Task.checkCancellation()
        let document = segmenter.segment(content)
        try Task.checkCancellation()
        return document
    }

    /// Where to scroll to when a text is reopened.
    ///
    /// Resolved from the stored **character offset** first, and only from the
    /// stored block index if that fails. The offset is the durable anchor:
    /// block indices are a property of however the text was segmented last
    /// time, so an OS update that changes `NLTokenizer`'s output, or a
    /// dictionary update that changes the repair pass, would silently move
    /// every saved position. A character offset survives both.
    static func restoredBlock(from position: ReadingPosition?, in document: SegmentedDocument)
        -> Int?
    {
        guard let position else { return nil }
        if let token = document.token(atOffset: position.characterOffset) {
            return token.id.block
        }
        return document.blocks.indices.contains(position.blockIndex) ? position.blockIndex : nil
    }

    // MARK: - Readings

    /// How many blocks either side of the viewport get readings.
    ///
    /// Asymmetric because reading goes downwards: more is fetched ahead than
    /// behind. The prototype fetched an entry for every distinct token in the
    /// whole document before showing anything.
    static let readingWindowBefore = 2
    static let readingWindowAfter = 4

    private func scheduleReadingRefresh() {
        readingTask?.cancel()
        readingTask = Task { await refreshReadings() }
    }

    func refreshReadings() async {
        guard let document else { return }
        let range = Self.window(around: topBlock ?? 0, in: document)
        let words = Set(
            document.blocks[range]
                .flatMap(\.tokens)
                .filter(\.isLookupCandidate)
                .map(\.text),
        )
        // Only what is not already known, so scrolling back over text that
        // has been read costs nothing.
        let missing = words.subtracting(readings.keys)
        guard !missing.isEmpty else { return }

        let fetched = await services.dictionary.readings(for: missing)
        guard !Task.isCancelled else { return }
        readings.merge(fetched) { current, _ in current }
    }

    /// Both ends are clamped, not just the obvious one. Clamping only the
    /// upper bound leaves a block index past the end of the document
    /// producing a range that *starts* past the end — empty, so it looks
    /// harmless, but slicing `blocks` with it traps. A stale scroll position
    /// after a text is edited is exactly how that index arises.
    static func window(around block: Int, in document: SegmentedDocument) -> Range<Int> {
        let count = document.blocks.count
        guard count > 0 else { return 0 ..< 0 }
        let lower = min(max(0, block - readingWindowBefore), count)
        let upper = min(count, max(lower, block + readingWindowAfter + 1))
        return lower ..< upper
    }

    // MARK: - Selection

    /// Handles a tap on a word.
    ///
    /// Tapping the selected word again clears it. Tapping a *different*
    /// instance of a word that is already revealed moves the selection and
    /// leaves the reveal alone — the prototype toggled every instance off,
    /// which is why tapping a revealed word felt broken.
    func tap(_ id: TokenID) {
        guard let token = document?[id], token.isLookupCandidate else { return }
        if selection == id {
            clearSelection()
            reveal.hide(token)
            persistReveal(of: token.text, revealed: false)
        } else {
            selection = id
            reveal.reveal(token)
            persistReveal(of: token.text, revealed: true)
            loadDetail(for: token.text)
        }
    }

    func clearSelection() {
        // Cancelled, not merely overwritten. A lookup already in flight would
        // otherwise finish, pass its own cancellation check and write
        // `.loaded` -- leaving a definition on screen for a word that is no
        // longer selected.
        detailTask?.cancel()
        detailTask = nil
        selection = nil
        detail = .empty
    }

    private func loadDetail(for word: String) {
        detailTask?.cancel()
        detail = .loading(word)
        detailTask = Task {
            let entries = await services.dictionary.entries(for: word)
            // Both checks are needed. Cancellation covers the task being
            // torn down; the state check covers a result arriving for a word
            // that is no longer the one being asked about.
            guard !Task.isCancelled, detail == .loading(word) else { return }
            detail = entries.isEmpty
                ? .notFound(word)
                : .loaded(WordDetail(
                    word: word,
                    reading: readings[word] ?? ReadingComposer.reading(from: entries),
                    entries: entries,
                ))
        }
    }

    /// Remembers a reveal across launches.
    ///
    /// Only in `.allOccurrences` mode, because that is the only thing the
    /// store can express: `revealedWord` is keyed on `(text, word)`, so there
    /// is nowhere to record *which* 的 was revealed. Writing a lemma for a
    /// per-instance tap would be worse than not writing it — reopening would
    /// light up every occurrence of a word the reader revealed exactly once,
    /// and switching modes would expose the lot. Per-instance reveals are
    /// therefore session-only, which is noted in the setting's own
    /// documentation rather than discovered.
    ///
    /// Writes are chained rather than fired independently. Two taps on the
    /// same word produce a reveal and a hide, and unordered they can land in
    /// either order — leaving the store saying "revealed" after a tap that
    /// hid it.
    private func persistReveal(of word: String, revealed: Bool) {
        guard reveal.mode == .allOccurrences else { return }
        let library = services.library
        let id = textID
        revealWrites.submit {
            do {
                if revealed {
                    try await library.reveal(word, in: id)
                } else {
                    try await library.unreveal(word, in: id)
                }
            } catch {
                // The page is already correct; only the memory of it across
                // launches is lost. Not worth interrupting a reader for.
                Log.error("reader", "could not store reveal state: \(error)")
            }
        }
    }

    // MARK: - Reading position

    /// Debounced, because the position changes continuously while scrolling
    /// and a write per frame would be hundreds of transactions a second for
    /// a value only the next launch reads.
    static let positionSaveDelay = Duration.milliseconds(500)

    private func schedulePositionSave() {
        positionSaveTask?.cancel()
        positionSaveTask = Task {
            try? await Task.sleep(for: Self.positionSaveDelay)
            guard !Task.isCancelled else { return }
            await savePosition()
        }
    }

    /// Writes the position immediately.
    ///
    /// Called when the scene goes to the background or the text is closed:
    /// the debounce means there is almost always an unwritten position in
    /// flight, and losing it is the difference between reopening where you
    /// left off and reopening a page earlier.
    func flushPosition() async {
        positionSaveTask?.cancel()
        positionSaveTask = nil
        await savePosition()
    }

    private func savePosition() async {
        guard let document, let block = topBlock,
              document.blocks.indices.contains(block)
        else { return }
        let token = document.blocks[block].tokens.first
        let position = ReadingPosition(
            textID: textID,
            blockIndex: block,
            tokenIndex: token?.id.index ?? 0,
            characterOffset: token?.range.lowerBound
                ?? document.blocks[block].range.lowerBound,
            // Deliberately not written here. The repository preserves a
            // playhead it was not given, so passing nil leaves whatever the
            // audio player stored rather than clearing it on every scroll.
            audioTime: nil,
        )
        do {
            try await services.library.save(position)
        } catch {
            Log.error("reader", "could not save the reading position: \(error)")
        }
    }

    /// The playhead stored with the reading position, for the audio player to
    /// resume from. The prototype lost this on every relaunch.
    var storedAudioTime: Double? {
        restoredAudioTime
    }

    // MARK: - Teardown

    /// Stops everything in flight and writes the position.
    ///
    /// Called when the reader closes a text. `.task(id:)` cancels its own
    /// task when the view goes away, but the unstructured tasks held here —
    /// the debounced position save, the reading window, the detail lookup,
    /// the reveal write — have no such relationship and would otherwise
    /// outlive the model that owns them.
    ///
    /// Flushing is not optional either: the position save is debounced, so
    /// there is almost always one in flight, and losing it is the difference
    /// between reopening where you left off and reopening a page earlier.
    func close() async {
        readingTask?.cancel()
        detailTask?.cancel()
        readingTask = nil
        detailTask = nil
        await flushPosition()
        // Awaited rather than cancelled: these are the last writes of the
        // session and the whole point of chaining them was that they land in
        // order. Cancelling here would drop the final tap.
        await revealWrites.drain()
    }
}
