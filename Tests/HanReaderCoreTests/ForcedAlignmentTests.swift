// HanReader — MIT licensed. See LICENSE.

import Testing
@testable import HanReaderCore

/// A transcript of three sentences, and a recogniser that heard them
/// perfectly, one word per segment with a tidy clock.
private let transcript = "山村的孩子需要他。我在一个山村学校当老师。教学任务很重。"

private func segment(_ text: String, _ start: Double, _ end: Double) -> RecognisedSpeech.Segment {
    RecognisedSpeech.Segment(text: text, start: start, end: end)
}

/// Exactly right: each sentence in its own two-second slot.
private let perfect = RecognisedSpeech(
    segments: [
        segment("山村的孩子需要他", 0, 2),
        segment("我在一个山村学校当老师", 2, 5),
        segment("教学任务很重", 5, 7),
    ],
    duration: 7,
)

private func phrases(_ text: String = transcript) -> [Range<Int>] {
    PhraseSplitter.phrases(in: text)
}

private func aligned(_ speech: RecognisedSpeech, _ text: String = transcript) -> [Phrase] {
    ForcedAlignment.align(phrases: phrases(text), in: text, to: speech)
}

@Suite("Forced alignment")
struct ForcedAlignmentTests {
    // MARK: - The invariants a transport depends on

    /// Times a transport can actually play: in order, never overlapping,
    /// never zero-length, never past the end of the recording. The alignment
    /// can produce all four honestly — a phrase anchored on one character
    /// has start equal to end — and a transport handed those plays silence
    /// or plays the neighbour's words, and the reader blames their ears.
    @Test(
        "Placed phrases are ordered, non-overlapping and inside the recording",
        arguments: [0, 1, 2, 3],
    )
    func timesArePlayable(damage: Int) {
        let speech = damaged(by: damage)
        let placed = aligned(speech)
        #expect(placed.count == phrases().count)

        // Hard guarantees, whatever the recogniser did.
        for phrase in placed {
            #expect(phrase.start >= 0)
            #expect(phrase.end <= speech.duration + 0.000_1)
        }
        for (earlier, later) in zip(placed, placed.dropFirst()) {
            #expect(earlier.end <= later.start + 0.000_1)
            #expect(earlier.index < later.index)
        }
        // And long enough to hear, which is only promised when the recording
        // has room for it — three phrases cannot each last a quarter-second
        // inside half a second of audio.
        if speech.duration >= Double(placed.count) * ForcedAlignment.minimumDuration {
            for phrase in placed {
                #expect(phrase.duration >= ForcedAlignment.minimumDuration - 0.000_1)
            }
        }
    }

    /// Four recognisers of descending quality, so the invariants above are
    /// checked against failure rather than only against success.
    private func damaged(by level: Int) -> RecognisedSpeech {
        switch level {
        case 0:
            perfect
        case 1:
            // Characters misheard: 村→春, 师→狮. Homophone-ish slips, which
            // is what a recogniser actually produces.
            RecognisedSpeech(segments: [
                segment("山春的孩子需要他", 0, 2),
                segment("我在一个山村学校当老狮", 2, 5),
                segment("教学任务很重", 5, 7),
            ], duration: 7)
        case 2:
            // A whole sentence lost — a cough, a bad patch of audio.
            RecognisedSpeech(segments: [
                segment("山村的孩子需要他", 0, 2),
                segment("教学任务很重", 5, 7),
            ], duration: 7)
        default:
            // Almost nothing recognised at all.
            RecognisedSpeech(segments: [segment("山", 0, 0.3)], duration: 7)
        }
    }

    // MARK: - Placing

    @Test("A clean recognition puts each phrase on its own sentence")
    func cleanRecognition() {
        let placed = aligned(perfect)
        #expect(placed.count == 3)
        #expect(placed.allSatisfy { $0.confidence > 0.99 })

        // Each phrase sits inside the segment that said it, give or take the
        // width of one character.
        #expect(abs(placed[0].start - 0) < 0.3)
        #expect(abs(placed[1].start - 2) < 0.4)
        #expect(abs(placed[2].start - 5) < 0.4)
        #expect(abs(placed[2].end - 7) < 0.4)
    }

    /// The whole point of forced alignment: the words are already known, so
    /// a recogniser's mistakes cost timing accuracy, not placement. The
    /// characters it got right carry the clock across the ones it did not.
    @Test("Misheard characters do not move a phrase")
    func misheardCharactersAreBridged() {
        let placed = aligned(damagedByCharacters)
        #expect(placed.count == 3)
        #expect(abs(placed[1].start - 2) < 0.5)
        #expect(abs(placed[2].start - 5) < 0.5)
        // And it says so: not every character was matched.
        #expect(placed[0].confidence < 1)
        #expect(placed[0].confidence > 0.5)
    }

    private var damagedByCharacters: RecognisedSpeech {
        RecognisedSpeech(segments: [
            segment("山春的孩子需要他", 0, 2),
            segment("我在一个山村学校当老狮", 2, 5),
            segment("教学任务很重", 5, 7),
        ], duration: 7)
    }

    /// A phrase the recogniser lost entirely still gets a slot between its
    /// neighbours, so the reader can play it and fix the boundary — rather
    /// than a zero-length one at the start of the recording, which is
    /// unplayable and looks like a bug.
    @Test("A phrase that was never recognised is still placed between its neighbours")
    func unrecognisedPhraseIsSlottedIn() {
        let speech = RecognisedSpeech(segments: [
            segment("山村的孩子需要他", 0, 2),
            segment("教学任务很重", 5, 7),
        ], duration: 7)
        let placed = aligned(speech)

        #expect(placed.count == 3)
        #expect(placed[1].confidence == 0)
        #expect(placed[1].start >= placed[0].end - 0.000_1)
        #expect(placed[1].end <= placed[2].start + 0.000_1)
        #expect(placed[1].duration > 0)
        // Its neighbours are unharmed.
        #expect(placed[0].confidence > 0.9)
        #expect(placed[2].confidence > 0.9)
    }

    /// Confidence is what the UI offers for review instead of silently
    /// believing, so it has to mean something: the share of a phrase's
    /// characters the recogniser actually matched.
    @Test("Confidence reports how much was matched rather than inferred")
    func confidenceIsMeaningful() {
        #expect(aligned(perfect).allSatisfy { $0.confidence > 0.99 })
        let hopeless = aligned(RecognisedSpeech(
            segments: [segment("完全不同的内容", 0, 7)],
            duration: 7,
        ))
        #expect(hopeless.allSatisfy { $0.confidence < 0.4 })
    }

    /// Review finding: anchoring a phrase on its first and last *matched*
    /// characters cuts off any it misheard at the edges — the character is
    /// still spoken in the recording, so the reader hears the phrase
    /// clipped. This is what a 97% round trip looked like on real audio.
    @Test("A misheard first character is still inside the phrase's audio")
    func misheardEdgesAreCovered() {
        let text = "山村的孩子。教学任务很重。"
        // 教 misheard as 交, so the second phrase's first character is not
        // an anchor. Its audio must still begin where 。 left off.
        var segments: [RecognisedSpeech.Segment] = []
        for (index, character) in Array("山村的孩子交学任务很重").enumerated() {
            let start = Double(index) * 0.5
            segments.append(.init(text: String(character), start: start, end: start + 0.5))
        }
        let speech = RecognisedSpeech(segments: segments, duration: 6)
        let placed = ForcedAlignment.align(
            phrases: PhraseSplitter.phrases(in: text),
            in: text,
            to: speech,
            maximumDuration: nil,
        )

        #expect(placed.count == 2)
        // 交 is spoken over 2.5–3.0, and the phrase must include it rather
        // than starting at 3.0 where 学 was matched.
        #expect(placed[1].start <= 2.51)
        #expect(placed[1].confidence < 1)
    }

    /// And at the other edge.
    @Test("A misheard last character is still inside the phrase's audio")
    func misheardTrailingEdgeIsCovered() {
        let text = "山村的孩子。教学任务很重。"
        var segments: [RecognisedSpeech.Segment] = []
        for (index, character) in Array("山村的孩紫教学任务很重").enumerated() {
            let start = Double(index) * 0.5
            segments.append(.init(text: String(character), start: start, end: start + 0.5))
        }
        let speech = RecognisedSpeech(segments: segments, duration: 6)
        let placed = ForcedAlignment.align(
            phrases: PhraseSplitter.phrases(in: text),
            in: text,
            to: speech,
            maximumDuration: nil,
        )
        #expect(placed.count == 2)
        // 紫 stands where 子 was said, over 2.0–2.5, so the first phrase has
        // to reach 2.5 rather than stopping at 2.0.
        #expect(placed[0].end >= 2.49)
    }

    // MARK: - Degenerate input

    /// No recognition at all — the model missing, or a recording of silence.
    /// Equal slices let the reader step through and place the boundaries by
    /// hand, and confidence zero is what tells the UI to offer that.
    @Test("With nothing recognised the phrases are spread evenly")
    func nothingRecognised() {
        let placed = aligned(RecognisedSpeech(segments: [], duration: 9))
        #expect(placed.count == 3)
        #expect(placed.allSatisfy { $0.confidence == 0 })
        #expect(abs(placed[0].end - 3) < 0.000_1)
        #expect(abs(placed[2].end - 9) < 0.000_1)
        for (earlier, later) in zip(placed, placed.dropFirst()) {
            #expect(earlier.end <= later.start + 0.000_1)
        }
    }

    @Test("A recogniser that heard only punctuation counts as nothing")
    func punctuationOnlyRecognition() {
        let placed = aligned(RecognisedSpeech(
            segments: [segment("，。！", 0, 7)],
            duration: 7,
        ))
        #expect(placed.count == 3)
        #expect(placed.allSatisfy { $0.confidence == 0 })
    }

    @Test("An empty transcript produces no phrases")
    func emptyTranscript() {
        #expect(ForcedAlignment.align(phrases: [], in: "", to: perfect).isEmpty)
    }

    /// A recording whose length is unknown must not collapse every phrase to
    /// zero, or nothing can be played at all.
    @Test("A recording of unknown length still yields playable phrases")
    func unknownDuration() {
        let placed = aligned(RecognisedSpeech(segments: perfect.segments, duration: 0))
        #expect(placed.count == 3)
        #expect(placed.allSatisfy { $0.duration > 0 })
    }

    // MARK: - Punctuation

    /// A recogniser invents its own punctuation, so matching the
    /// transcript's commas against it would be aligning two authors' habits
    /// rather than the same speech.
    @Test("Punctuation differences do not disturb the alignment")
    func punctuationIsIgnored() {
        let loose = RecognisedSpeech(segments: [
            segment("山村的孩子，需要他！", 0, 2),
            segment("我在一个山村学校，当老师", 2, 5),
            segment("教学任务很重", 5, 7),
        ], duration: 7)
        let placed = aligned(loose)
        #expect(placed.allSatisfy { $0.confidence > 0.99 })
        #expect(abs(placed[1].start - 2) < 0.4)
    }
}

@Suite("Alignment tidying")
struct ForcedAlignmentTidyTests {
    private func phrase(_ index: Int, _ start: Double, _ end: Double) -> Phrase {
        Phrase(index: index, start: start, end: end, textRange: index * 5 ..< index * 5 + 4)
    }

    @Test("Overlapping phrases are pushed apart")
    func overlapsAreRemoved() {
        let tidied = ForcedAlignment.tidy(
            [phrase(0, 0, 5), phrase(1, 3, 8), phrase(2, 6, 10)],
            duration: 10,
        )
        for (earlier, later) in zip(tidied, tidied.dropFirst()) {
            #expect(earlier.end <= later.start + 0.000_1)
        }
    }

    @Test("A phrase running backwards is given a forward span")
    func backwardsPhraseIsRepaired() {
        let tidied = ForcedAlignment.tidy([phrase(0, 5, 2), phrase(1, 6, 9)], duration: 10)
        #expect(tidied[0].end > tidied[0].start)
        #expect(tidied.allSatisfy { $0.duration >= ForcedAlignment.minimumDuration - 0.000_1 })
    }

    @Test("Times past the end of the recording are pulled back")
    func beyondTheEndIsClamped() {
        let tidied = ForcedAlignment.tidy([phrase(0, 0, 4), phrase(1, 8, 99)], duration: 10)
        #expect(tidied.allSatisfy { $0.end <= 10.000_1 })
    }

    /// Review finding: stretching a short final phrase backwards to reach
    /// the minimum could reach back over its predecessor, so two phrases
    /// replayed the same audio and the reader transcribed the same words
    /// twice without being told why.
    @Test("Reaching back for a minimum never overlaps the phrase before")
    func backwardStretchRespectsItsNeighbour() {
        // The last phrase is a sliver at the very end of the recording, so
        // the only room left is behind it.
        let tidied = ForcedAlignment.tidy(
            [phrase(0, 0, 9.95), phrase(1, 9.96, 9.97)],
            duration: 10,
        )
        for (earlier, later) in zip(tidied, tidied.dropFirst()) {
            #expect(earlier.end <= later.start + 0.000_1)
        }
        #expect(tidied.allSatisfy { $0.end <= 10.000_1 })
    }

    @Test("Tidying nothing yields nothing")
    func empty() {
        #expect(ForcedAlignment.tidy([], duration: 10).isEmpty)
    }
}

/// Re-cutting a phrase that turned out too long once its times were known.
@Suite("Alignment re-cutting")
struct ForcedAlignmentRecutTests {
    /// A character budget is only a proxy for duration, and a poor one on
    /// material with pauses. Measured on a real 听力 recording: eighteen
    /// characters came to ten seconds of audio, and six phrases in eighteen
    /// ran past the seven-second cap, the longest at thirty.
    @Test("A phrase that turns out too long is cut again at its punctuation")
    func overlongPhrasesAreRecut() {
        // One sentence, read slowly: eight seconds for what the character
        // budget took for four.
        let text = "我在一个山村学校当老师，教学任务很重。"
        let slow = RecognisedSpeech(
            segments: Array(text).enumerated().compactMap { index, character in
                let start = Double(index) * 0.45
                return .init(text: String(character), start: start, end: start + 0.45)
            },
            duration: 9,
        )
        let ranges = PhraseSplitter.phrases(in: text)
        #expect(ranges.count == 1)

        let placed = ForcedAlignment.align(
            phrases: ranges,
            in: text,
            to: slow,
            maximumDuration: 5,
        )
        #expect(placed.count > 1)
        #expect(placed.allSatisfy { $0.duration <= 5.5 })
        // And it cut at the comma rather than anywhere convenient.
        #expect(placed[0].text(in: text).hasSuffix("，"))
    }

    /// The pauses come free: a recogniser folds the silence before a
    /// character into that character's own span, so a character taking far
    /// longer than its neighbours is one that followed a gap. On the real
    /// recording this is what rescued the material — recognised punctuation
    /// is sparse, and cutting at punctuation alone left six phrases over.
    @Test("A phrase with no punctuation is cut where the speaker paused")
    func overlongPhrasesAreCutAtPauses() {
        // No punctuation at all, and a two-second gap in the middle, folded
        // into the span of the character that follows it.
        let text = "山村的孩子需要他我在一个山村学校"
        var segments: [RecognisedSpeech.Segment] = []
        for (index, character) in Array(text).enumerated() {
            let paused = index == 8
            let start = Double(index) * 0.25 + (index > 8 ? 2 : 0)
            segments.append(.init(
                text: String(character),
                start: start,
                end: start + (paused ? 2.25 : 0.25),
            ))
        }
        let speech = RecognisedSpeech(segments: segments, duration: 8)

        let placed = ForcedAlignment.align(
            phrases: [0 ..< text.utf16.count],
            in: text,
            to: speech,
            maximumDuration: 3,
        )
        #expect(placed.count == 2)
        #expect(placed[0].text(in: text) == "山村的孩子需要他")
        #expect(placed[1].text(in: text) == "我在一个山村学校")
    }

    /// A phrase with nothing to cut at stays long rather than being chopped
    /// somewhere arbitrary. The vocabulary list read at the end of an
    /// exercise is one unpunctuated minute, and a long phrase is a better
    /// unit there than a cut in the middle of a word.
    @Test("A phrase with nowhere to cut is left alone")
    func unsplittablePhrasesSurviveRecutting() {
        let text = "山村的孩子需要他"
        let speech = RecognisedSpeech(
            segments: Array(text).enumerated().map { index, character in
                .init(text: String(character), start: Double(index), end: Double(index) + 1)
            },
            duration: 8,
        )
        let placed = ForcedAlignment.align(
            phrases: [0 ..< text.utf16.count],
            in: text,
            to: speech,
            maximumDuration: 2,
        )
        #expect(placed.count == 1)
        #expect(placed[0].duration > 2)
    }

    @Test("Re-cutting can be switched off")
    func recuttingIsOptional() {
        let text = "我在一个山村学校当老师，教学任务很重。"
        let slow = RecognisedSpeech(
            segments: Array(text).enumerated().compactMap { index, character in
                let start = Double(index) * 0.45
                return .init(text: String(character), start: start, end: start + 0.45)
            },
            duration: 9,
        )
        let placed = ForcedAlignment.align(
            phrases: PhraseSplitter.phrases(in: text),
            in: text,
            to: slow,
            maximumDuration: nil,
        )
        #expect(placed.count == 1)
    }
}
