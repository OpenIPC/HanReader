// HanReader — MIT licensed. See LICENSE.

import Foundation
import HanReaderCore

/// Which words currently show their reading.
///
/// The fix for the prototype's single `revealedWords: Set<String>`, which
/// conflated two different things and so could express neither properly:
/// tapping 的 once put pinyin over all 467 instances in the document, and
/// tapping *any* of them removed it from all of them. The most jarring
/// consequence was that tapping a second instance of a word you had already
/// revealed appeared to do nothing at all.
///
/// Reveal is a property of a **word** or of an **instance**, depending on the
/// reader's setting, and it is separate from selection — which is always
/// exactly one token and drives the detail panel. Keeping both lets the
/// default behaviour match the prototype exactly while the interaction bug
/// disappears.
struct RevealSet: Equatable, Sendable {
    var mode: RevealMode
    /// Words revealed everywhere they appear.
    var lemmas: Set<String> = []
    /// Individual tokens revealed, for `.thisInstance`.
    var instances: Set<TokenID> = []

    init(mode: RevealMode, lemmas: Set<String> = [], instances: Set<TokenID> = []) {
        self.mode = mode
        self.lemmas = lemmas
        self.instances = instances
    }

    /// Whether a token's reading is shown.
    ///
    /// Answered per token rather than by materialising a set of revealed
    /// token ids. For a book-length text that set would be recomputed over
    /// every token in the document on each tap, and it would grow with the
    /// document rather than with the reader's vocabulary.
    func reveals(_ token: Token) -> Bool {
        switch mode {
        case .allOccurrences: lemmas.contains(token.text)
        case .thisInstance: instances.contains(token.id)
        }
    }

    /// Reveals a token, in whichever way the mode calls for.
    mutating func reveal(_ token: Token) {
        switch mode {
        case .allOccurrences: lemmas.insert(token.text)
        case .thisInstance: instances.insert(token.id)
        }
    }

    mutating func hide(_ token: Token) {
        switch mode {
        case .allOccurrences: lemmas.remove(token.text)
        case .thisInstance: instances.remove(token.id)
        }
    }

    mutating func removeAll() {
        lemmas.removeAll()
        instances.removeAll()
    }

    var isEmpty: Bool {
        lemmas.isEmpty && instances.isEmpty
    }
}
