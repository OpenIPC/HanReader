// HanReader — MIT licensed. See LICENSE.

import Testing
@testable import HanReaderCore

private func text(_ source: String, _ range: Range<Int>) -> String {
    let utf16 = Array(source.utf16)
    return String(decoding: utf16[range], as: UTF16.self)
}

private func phrases(_ source: String, maximum: Int = 29, minimum: Int = 4) -> [String] {
    PhraseSplitter
        .phrases(
            in: source,
            splitting: PhraseSplitting(maximumLength: maximum, minimumLength: minimum),
        )
        .map { text(source, $0) }
}

@Suite("Phrase splitting")
struct PhraseSplitterTests {
    // MARK: - Sentences

    @Test("A text splits at its terminators")
    func sentences() {
        let source = "山村的孩子需要他。他重复了三次！任务不重？"
        #expect(phrases(source) == ["山村的孩子需要他。", "他重复了三次！", "任务不重？"])
    }

    /// 听力64 contains **39 half-width commas and no full-width ones** — it
    /// was typed by someone whose input method produced `,`. A splitter that
    /// knew only `，` and `。` would leave its longest sentence whole and the
    /// cap would silently not apply to the one text this was built for.
    @Test(
        "Half-width terminators end a sentence just as full-width ones do",
        arguments: [".", "!", "?", ";"],
    )
    func halfWidthTerminators(mark: String) {
        // Two sentences, or one if the mark is not recognised. Both clear the
        // minimum length, so nothing here can be explained by merging.
        let source = "第一个句子\(mark)第二个句子。"
        #expect(phrases(source).count == 2)
    }

    @Test("Half-width separators divide an over-long sentence")
    func halfWidthSeparators() {
        let halfWidth = "我在一个山村学校当老师,教学任务很重,而我的身体却很瘦弱。"
        let fullWidth = "我在一个山村学校当老师，教学任务很重，而我的身体却很瘦弱。"
        #expect(phrases(halfWidth, maximum: 12).count == phrases(fullWidth, maximum: 12).count)
        #expect(phrases(halfWidth, maximum: 12).count > 1)
    }

    /// 「说：“这是什么意思？”」 must not leave a phrase that is one closing
    /// quotation mark.
    @Test("A closing mark stays with the sentence it closes")
    func closingMarksDoNotStrandThemselves() {
        let source = "他说：“这是什么意思？”我不知道。"
        let result = phrases(source)
        #expect(result.count == 2)
        #expect(result.first?.hasSuffix("”") == true)
        #expect(result.allSatisfy { $0.count > 1 })
    }

    /// Review finding: 真的吗？！ is one question with an exclamation on it.
    /// Ending the sentence at ？ left ！ to start the next one, so the reader
    /// would be asked to transcribe a phrase consisting of a punctuation
    /// mark.
    @Test("Repeated terminators stay with the sentence they end")
    func repeatedTerminators() {
        // With the minimum switched off, so the boundary itself is what is
        // being tested. At the default minimum the stray ！ would be glued
        // back on by the merge and a wrong sentence boundary would look
        // right from the outside.
        #expect(phrases("真的吗？！接下来我们继续。", minimum: 0) == ["真的吗？！", "接下来我们继续。"])
        #expect(phrases("是吗?!我们继续下去。", minimum: 0) == ["是吗?!", "我们继续下去。"])
        // And the merge still covers it at the default, which is what a
        // reader actually sees.
        #expect(phrases("真的吗？！接下来我们继续。") == ["真的吗？！", "接下来我们继续。"])
    }

    /// Review finding: dividing an over-long sentence ended a clause at its
    /// terminator and left the closing quote as another. With the clause
    /// before it already over budget, neither packing nor the minimum-length
    /// merge would take it back.
    @Test("A closing mark never becomes a phrase of its own")
    func punctuationIsNeverAPhraseAlone() {
        let source = "他大声地说道这件事情非常重要我们一定要认真对待它？”"
        for phrase in phrases(source, maximum: 8, minimum: 4) {
            #expect(PhraseSplitter.characterCount(of: phrase, in: 0 ..< phrase.utf16.count) > 0)
        }
    }

    @Test("A final sentence with no terminator is still a phrase")
    func unterminatedTail() {
        #expect(phrases("第一句。没有句号的结尾") == ["第一句。", "没有句号的结尾"])
    }

    @Test("Whitespace between sentences is not part of either")
    func whitespaceIsDropped() {
        let result = phrases("第一个句子。   第二个句子。")
        #expect(result == ["第一个句子。", "第二个句子。"])
    }

    /// Two sentences too short to stand alone become one phrase, and the
    /// whitespace between them comes along: a phrase is a contiguous range
    /// of the stored text, not a reassembled string.
    @Test("Merging across a sentence boundary keeps the text contiguous")
    func mergeSpansTheGap() {
        #expect(phrases("第一句。 第二句。") == ["第一句。 第二句。"])
    }

    @Test("An empty text produces no phrases")
    func empty() {
        #expect(phrases("").isEmpty)
        #expect(phrases("   \n  ").isEmpty)
    }

    // MARK: - The duration cap

    /// The measured behaviour on 听力64: 22 sentences become 29 phrases at a
    /// 29-character budget, with the longest exactly at the cap. Sentences
    /// that fit are kept whole — splitting at every comma instead would give
    /// 61 fragments of three or four characters, which is not a listening
    /// test.
    @Test("A sentence within budget is kept whole")
    func shortSentencesAreNotCut() {
        let source = "卖主是位六十多岁的老太太,她叫我给个价,我就说五角钱一个。"
        #expect(phrases(source) == [source])
    }

    @Test("An over-long sentence is cut at its commas")
    func longSentencesAreCut() {
        let source = "我在一个山村学校当老师,教学任务很重,而我的身体却很瘦弱,每天吃的不是萝卜就是白菜。"
        let result = phrases(source)
        #expect(result.count > 1)
        #expect(result.joined() == source)
        for phrase in result {
            #expect(PhraseSplitter.characterCount(of: phrase, in: 0 ..< phrase.utf16.count) <= 29)
        }
    }

    /// Greedy packing, not one phrase per comma: five short clauses become
    /// two phrases that each fill the budget.
    @Test("Clauses are packed up to the budget rather than emitted one each")
    func clausesArePacked() {
        let source = "一二三四五,六七八九十,十一十二十三,十四十五十六,十七十八十九。"
        let result = phrases(source, maximum: 12)
        #expect(result.count < 5)
        #expect(result.joined() == source)
    }

    /// There is nothing left to cut at, and cutting mid-word would make it
    /// unreadable. One over-long phrase the reader can split by hand is the
    /// better failure.
    @Test("A clause longer than the budget with no punctuation is emitted whole")
    func unsplittableClauseSurvives() {
        let source = String(repeating: "山", count: 60) + "。"
        let result = phrases(source, maximum: 10)
        #expect(result == [source])
    }

    // MARK: - The minimum

    /// Without this, 听力64 opens with a two-character fragment that is
    /// neither a listening test nor recognisable as anything.
    @Test("A fragment below the minimum is glued to the phrase before it")
    func shortFragmentsAreMerged() {
        let source = "这是一个很长的句子需要切开,好。"
        let result = phrases(source, maximum: 20, minimum: 4)
        #expect(result.allSatisfy { !$0.hasPrefix("好") })
        #expect(result.joined() == source)
    }

    /// But never past the cap: a run of fragments must not quietly grow one
    /// phrase beyond the budget the whole feature rests on.
    @Test("Merging a fragment never exceeds the budget")
    func mergingRespectsTheBudget() {
        // Every clause here is splittable and under the cap on its own, so
        // the only way to exceed it would be an over-eager merge. The
        // unsplittable case is a separate rule and has its own test.
        // Seven characters then two: the tail is below the minimum of six and
        // would be glued on, except that 7 + 2 is over the cap of 8. The
        // fragment has to stay a phrase of its own.
        let source = "一二三四五六七,八九。"
        let result = phrases(source, maximum: 8, minimum: 6)
        #expect(result.count == 2)
        for phrase in result {
            #expect(PhraseSplitter.characterCount(of: phrase, in: 0 ..< phrase.utf16.count) <= 8)
        }
        #expect(result.joined() == source)
    }

    // MARK: - Cut points

    /// Review finding: offering a cut immediately after a terminator
    /// stranded the closing quote that follows it, and when the clause
    /// before was already over the duration cap nothing could merge it back
    /// — so re-cutting a long sentence handed back a practice phrase that
    /// was one 」.
    @Test("A cut after a terminator carries its closing quote along")
    func cutPointsCarryClosingMarks() {
        let source = "他说：“这是什么意思？”我不知道，真的不知道。"
        let points = PhraseSplitter.cutPoints(in: 0 ..< source.utf16.count, of: source)
        let utf16 = Array(source.utf16)
        for point in points {
            // Nothing after a cut may begin with a closing mark.
            guard point < utf16.count, let scalar = Unicode.Scalar(utf16[point]) else { continue }
            #expect(!PhraseSplitter.trailing.contains(Character(scalar)))
        }
        #expect(!points.isEmpty)
    }

    @Test("Cut points sit strictly inside the range they are asked for")
    func cutPointsStayInside() {
        let source = "第一句，第二句。第三句。"
        let range = 0 ..< source.utf16.count
        for point in PhraseSplitter.cutPoints(in: range, of: source) {
            #expect(point > range.lowerBound)
            #expect(point < range.upperBound)
        }
    }

    @Test("A range with no punctuation offers nowhere to cut")
    func noCutPoints() {
        let source = "山村的孩子需要他"
        #expect(PhraseSplitter.cutPoints(in: 0 ..< source.utf16.count, of: source).isEmpty)
    }

    // MARK: - Ranges

    /// Phrases are consumed as UTF-16 ranges into the stored text, the same
    /// unit as `Token.range` and `ReadingPosition.characterOffset`. They must
    /// be ordered, non-overlapping and inside the text, or a phrase shows the
    /// wrong words or traps.
    @Test(
        "Ranges are ordered, non-overlapping and within the text",
        arguments: [
            "山村的孩子需要他。我在一个山村学校当老师,教学任务很重。",
            "第一句。   第二句！第三句？",
            "没有标点的文本",
            "他说：“这是什么意思？”我不知道。",
        ],
    )
    func rangesTile(source: String) {
        let ranges = PhraseSplitter.phrases(in: source)
        let length = source.utf16.count
        for range in ranges {
            #expect(range.lowerBound >= 0)
            #expect(range.upperBound <= length)
            #expect(!range.isEmpty)
        }
        for (earlier, later) in zip(ranges, ranges.dropFirst()) {
            #expect(earlier.upperBound <= later.lowerBound)
        }
    }

    /// A supplementary-plane character is two UTF-16 units. The offsets here
    /// are computed by accumulating `utf16.count` per character, so a rare
    /// ideograph is exactly the input that would expose an arithmetic slip —
    /// and rare ideographs are the ones a learner most wants to re-hear.
    @Test("Ranges are correct across a surrogate pair")
    func surrogatePairsAreCounted() {
        let source = "一𠀋二三。四𠀋五六。"
        let ranges = PhraseSplitter.phrases(
            in: source,
            splitting: PhraseSplitting(maximumLength: 29, minimumLength: 0),
        )
        #expect(ranges.count == 2)
        #expect(ranges.map { text(source, $0) } == ["一𠀋二三。", "四𠀋五六。"])
        // And the offsets really are UTF-16: each 𠀋 is two units, so a
        // splitter counting Characters would report four fewer here.
        #expect(ranges.last?.upperBound == source.utf16.count)
    }

    // MARK: - Measuring

    /// The budget counts what a learner has to type. Counting punctuation
    /// would shrink a heavily-punctuated phrase, which has nothing to do
    /// with how long it takes to say.
    @Test("Punctuation and spaces do not count towards the budget")
    func punctuationIsNotCounted() {
        let source = "一,二。"
        #expect(PhraseSplitter.characterCount(of: source, in: 0 ..< source.utf16.count) == 2)
        let spaced = "a b 1"
        #expect(PhraseSplitter.characterCount(of: spaced, in: 0 ..< spaced.utf16.count) == 3)
    }

    // MARK: - Turning seconds into characters

    /// 听力64 measured: 609 characters over about 147 seconds is 4.1 a
    /// second, so WorkAudioBook's seven-second default is 29 characters.
    @Test("A duration budget converts using the recording's own rate")
    func durationBecomesCharacters() {
        let splitting = PhraseSplitting.forAudio(characters: 609, duration: 147)
        #expect(splitting.maximumLength == 29)
        #expect(splitting.minimumLength == 4)
    }

    /// A rate cannot be measured from a recording with no length, and a
    /// budget of zero would make every phrase over-long.
    @Test("A missing duration falls back to the standard budget")
    func degenerateAudioFallsBack() {
        #expect(PhraseSplitting.forAudio(characters: 0, duration: 0) == .standard)
        #expect(PhraseSplitting.forAudio(characters: 100, duration: 0) == .standard)
        #expect(PhraseSplitting(maximumLength: 0).maximumLength == 1)
    }
}
