// HanReader — MIT licensed. See LICENSE.

import Foundation

/// How a text is cut into units a learner can hold in their head long enough
/// to type back.
public struct PhraseSplitting: Hashable, Sendable {
    /// Longest unit, in characters.
    ///
    /// Expressed in characters rather than seconds because the splitter never
    /// sees the audio. The caller converts: a recording's characters divided
    /// by its duration gives a rate, and the rate turns a target of seconds
    /// into this. For 听力64 — 609 characters over about 147 seconds, so 4.1
    /// a second — WorkAudioBook's seven-second default comes to 29.
    public let maximumLength: Int

    /// Shortest unit worth keeping on its own.
    ///
    /// A clause below this is glued to the one before it rather than offered
    /// as a phrase of its own. Without it, 「其实,我暗暗地…」 opens the exercise
    /// with a two-character fragment that is neither a listening test nor
    /// recognisable as anything.
    public let minimumLength: Int

    public init(maximumLength: Int = 29, minimumLength: Int = 4) {
        self.maximumLength = max(1, maximumLength)
        self.minimumLength = max(0, min(minimumLength, max(1, maximumLength)))
    }

    /// The default: WorkAudioBook's seven seconds, at a typical rate for
    /// clearly-read listening material.
    public static let standard = Self()

    /// Converts a target duration into a character budget, given what the
    /// recording actually contains.
    ///
    /// Measured from the material rather than assumed, because the rate is
    /// the whole conversion and it differs by a factor of two between a
    /// graded listening exercise and a native-speed audiobook.
    public static func forAudio(
        characters: Int,
        duration: Double,
        seconds: Double = 7,
        minimumSeconds: Double = 1,
    )
        -> Self
    {
        guard duration > 0, characters > 0 else { return .standard }
        let rate = Double(characters) / duration
        return Self(
            maximumLength: Int((seconds * rate).rounded()),
            minimumLength: Int((minimumSeconds * rate).rounded()),
        )
    }
}

/// Cuts a text into practice phrases.
///
/// ### Sentences first, then clauses, and only where needed
///
/// A sentence is the natural unit and is kept whole wherever it fits. The
/// ones that do not fit are cut again at internal punctuation — which is
/// what WorkAudioBook does with its seven-second cap, and what a teacher does
/// when dictating.
///
/// 听力64 is the case this was measured against: 22 sentences running 9 to 42
/// characters. At a 29-character budget it yields 32 phrases, none over the
/// cap. Splitting at *every* comma instead would give 61, most of them three
/// or four characters long — not a listening test, just a slow way to read.
///
/// ### Half-width punctuation is not an edge case
///
/// 听力64 contains **39 half-width commas and no full-width ones**: it was
/// typed or scanned by someone whose input method produced `,`. A splitter
/// that only knew `，` would leave its 42-character sentence whole and the
/// cap would silently not apply. Both widths are therefore first-class, for
/// terminators and separators alike.
public enum PhraseSplitter {
    /// Ends a sentence.
    static let terminators: Set<Character> = [
        "。", "！", "？", "…", "；",
        ".", "!", "?", ";",
    ]

    /// Divides a sentence without ending it.
    static let separators: Set<Character> = [
        "，", "、", "：",
        ",", ":",
    ]

    /// Marks that belong to the phrase they follow and must never start one.
    ///
    /// Closing quotes and brackets, which a split at the terminator inside
    /// them would otherwise strand: 「说：“这是什么意思？”」 must not leave a
    /// phrase consisting of `”`.
    static let trailing: Set<Character> = [
        "”", "’", "）", "】", "》", "」", "』", "〉", "］", "｝",
        "\"", "'", ")", "]", "}",
    ]

    /// Phrase ranges, as UTF-16 offsets into `text`.
    ///
    /// UTF-16 because that is what every position in this app is measured in
    /// — `Token.range`, `ReadingPosition.characterOffset`, `NSRange` — and
    /// mixing units is how an off-by-one becomes a crash in a different file.
    public static func phrases(
        in text: String,
        splitting: PhraseSplitting = .standard,
    )
        -> [Range<Int>]
    {
        var phrases: [Range<Int>] = []
        for sentence in sentences(in: text) {
            let length = characterCount(of: text, in: sentence)
            if length <= splitting.maximumLength {
                phrases.append(sentence)
                continue
            }
            phrases.append(contentsOf: divide(sentence, in: text, splitting: splitting))
        }
        return merge(phrases, in: text, splitting: splitting)
    }

    // MARK: - Sentences

    /// Splits at terminators, keeping the terminator and any closing marks
    /// with the sentence they end, and dropping the whitespace between.
    static func sentences(in text: String) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        var start: Int?
        var offset = 0
        var pendingEnd: Int?

        for character in text {
            let width = character.utf16.count
            let isTerminator = terminators.contains(character)
            let isTrailing = trailing.contains(character)
            let isBlank = character.unicodeScalars.allSatisfy(\.properties.isWhitespace)

            if pendingEnd != nil, isTrailing {
                // A closing quote after the full stop still belongs to the
                // sentence it closes.
                pendingEnd = offset + width
                offset += width
                continue
            }
            if let end = pendingEnd, let began = start {
                ranges.append(began ..< end)
                start = nil
                pendingEnd = nil
            }
            if isBlank, start == nil {
                offset += width
                continue
            }
            if start == nil {
                start = offset
            }
            if isTerminator {
                pendingEnd = offset + width
            }
            offset += width
        }

        if let end = pendingEnd, let began = start {
            ranges.append(began ..< end)
        } else if let began = start {
            // A final sentence with no terminator, which is most transcripts'
            // last line and every heading.
            let trimmed = trimmingTrailingWhitespace(text, from: began, to: offset)
            if trimmed > began {
                ranges.append(began ..< trimmed)
            }
        }
        return ranges
    }

    // MARK: - Clauses

    /// Cuts an over-long sentence at its internal punctuation, greedily
    /// filling each phrase up to the budget.
    ///
    /// Greedy rather than balanced on purpose: a learner dictating works
    /// front to back, and a phrase that ends where the speaker paused is
    /// easier to hold than one trimmed to make the arithmetic even.
    private static func divide(
        _ sentence: Range<Int>,
        in text: String,
        splitting: PhraseSplitting,
    )
        -> [Range<Int>]
    {
        var clauses: [Range<Int>] = []
        var clauseStart = sentence.lowerBound
        var offset = sentence.lowerBound

        for character in characters(of: text, in: sentence) {
            let width = character.utf16.count
            offset += width
            if separators.contains(character) || terminators.contains(character) {
                clauses.append(clauseStart ..< offset)
                clauseStart = offset
            }
        }
        if clauseStart < sentence.upperBound {
            clauses.append(clauseStart ..< sentence.upperBound)
        }

        // Then pack clauses back up to the budget, so a sentence of five
        // short clauses becomes two phrases rather than five.
        var packed: [Range<Int>] = []
        for clause in clauses {
            guard let last = packed.last else {
                packed.append(clause)
                continue
            }
            let combined = last.lowerBound ..< clause.upperBound
            if characterCount(of: text, in: combined) <= splitting.maximumLength {
                packed[packed.count - 1] = combined
            } else {
                packed.append(clause)
            }
        }
        // A clause longer than the budget on its own is emitted as it is.
        // Cutting mid-word would make it unreadable, and there is no
        // punctuation left to cut at — better one long phrase the reader can
        // split by hand than a phrase ending in the middle of a word.
        return packed
    }

    // MARK: - Minimum length

    /// Glues a too-short phrase onto its predecessor.
    private static func merge(
        _ phrases: [Range<Int>],
        in text: String,
        splitting: PhraseSplitting,
    )
        -> [Range<Int>]
    {
        guard splitting.minimumLength > 0 else { return phrases }
        var merged: [Range<Int>] = []
        for phrase in phrases {
            guard characterCount(of: text, in: phrase) < splitting.minimumLength,
                  let last = merged.last
            else {
                merged.append(phrase)
                continue
            }
            // Only when the result still fits, or a run of short fragments
            // would quietly grow one phrase past the cap.
            let combined = last.lowerBound ..< phrase.upperBound
            if characterCount(of: text, in: combined) <= splitting.maximumLength {
                merged[merged.count - 1] = combined
            } else {
                merged.append(phrase)
            }
        }
        return merged
    }

    // MARK: - Measuring

    /// Characters a learner would have to type: Han, Latin and digits. A
    /// budget counted in punctuation would shrink the phrase that happens to
    /// be heavily punctuated, which has nothing to do with how long it takes
    /// to say.
    static func characterCount(of text: String, in range: Range<Int>) -> Int {
        characters(of: text, in: range).count { character in
            character.unicodeScalars.contains { scalar in
                switch ScalarClass.classify(scalar) {
                case .han, .latin, .number: true
                case .punctuation, .whitespace, .other: false
                }
            }
        }
    }

    private static func characters(of text: String, in range: Range<Int>) -> [Character] {
        let utf16 = Array(text.utf16)
        guard range.lowerBound >= 0, range.upperBound <= utf16.count else { return [] }
        return Array(String(decoding: utf16[range], as: UTF16.self))
    }

    private static func trimmingTrailingWhitespace(
        _ text: String,
        from start: Int,
        to end: Int,
    )
        -> Int
    {
        let utf16 = Array(text.utf16)
        var cursor = end
        while cursor > start,
              let scalar = Unicode.Scalar(utf16[cursor - 1]),
              scalar.properties.isWhitespace
        {
            cursor -= 1
        }
        return cursor
    }
}
