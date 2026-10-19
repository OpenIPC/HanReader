// HanReader — MIT licensed. See LICENSE.

import Foundation

/// A closed class of function word that constrains how its neighbour is being
/// used.
///
/// Closed classes only, and that restriction is the whole point. A rule built
/// on an open class — "a noun precedes" — needs a tagger and a lexicon and is
/// wrong at the edges; a rule built on a list of twenty-odd particles and
/// adverbs is a finite, checkable fact about the grammar. These are the ones
/// whose membership can be written down and argued about in a review.
public enum FunctionWordClass: UInt8, Sendable, Hashable, CaseIterable {
    /// 很, 太, 非常, 最 — a word whose only job is to intensify.
    ///
    /// A degree adverb modifies a stative predicate: the thing after it is
    /// being used as an adjective, never as a transitive verb, a noun or a
    /// classifier. That is a grammatical constraint rather than a frequency
    /// guess, which is what makes it worth encoding — it does not merely say
    /// which reading is commoner, it says which readings are impossible.
    case degreeAdverb

    /// 不, 并不 — a word that negates the predicate after it.
    ///
    /// A weaker signal than a degree adverb, and deliberately treated as a
    /// separate class rather than folded in with it. A negator takes verbs as
    /// readily as adjectives — 不去, 不吃 — so it says nothing on its own
    /// about which reading applies. It earns its place only because, for a
    /// few specific characters, both of the readings it admits happen to
    /// point the same way: 不重 is "not heavy" and 不差 is "not bad", because
    /// the other reading would be said as 不重复 and 不差别. Its table is
    /// correspondingly shorter than the degree adverb's.
    case negator

    /// The class of a word, or nil if it is not in one this can act on —
    /// which is nearly every word, by design.
    public init?(word: String) {
        if Self.degreeAdverbs.contains(word) {
            self = .degreeAdverb
            return
        }
        if Self.negators.contains(word) {
            self = .negator
            return
        }
        return nil
    }

    /// Both scripts throughout, because the reader's text may be either and
    /// the token is matched as written. A traditional text saying 很長 has to
    /// reach the same rule as 很长.
    ///
    /// 好 and 够 are here as the degree adverbs they are in 好重 ("so heavy")
    /// and 够长 ("long enough"). Both are also ordinary words, but a
    /// *separate preceding token* 好 before an adjective is the adverb in
    /// practically all running text.
    static let degreeAdverbs: Set = [
        "很", "太", "挺", "真", "好", "最", "更", "够", "夠", "蛮", "蠻", "颇", "頗",
        "非常", "特别", "特別", "比较", "比較", "十分", "相当", "相當",
        "极", "極", "极其", "極其", "格外", "尤其", "异常", "異常",
        "这么", "這麼", "那么", "那麼", "多么", "多麼",
        "稍微", "有点", "有點", "有点儿", "有點兒", "有些",
        "过于", "過於", "越来越", "越來越", "不太",
    ]

    /// 不 only, plus its emphatic forms. 没 is absent because it negates
    /// aspect rather than a predicate, and 没重 is not something anyone says.
    static let negators: Set = ["不", "并不", "並不"]
}

/// What the words around a token say about how it is being used.
///
/// Deliberately tiny, and deliberately *classified* rather than raw. Holding
/// the neighbouring words verbatim would make this the key to a cache with one
/// entry per phrase in the book; holding their class makes the key space the
/// vocabulary times a handful of cases, which is what lets a reading stay
/// cached per word the way it was before context existed.
public struct ReadingContext: Hashable, Sendable {
    /// The class of the word immediately before, where it is one of the few
    /// this can act on. Punctuation counts as a word for this purpose, so a
    /// context does not reach across 很，重.
    public let preceding: FunctionWordClass?

    /// No usable context: the word stands alone, or its neighbours say
    /// nothing. The overwhelming majority of tokens.
    public static let none = Self(preceding: nil)

    public init(preceding: FunctionWordClass?) {
        self.preceding = preceding
    }

    /// Classifies a token's neighbour.
    public init(precedingWord: String?) {
        preceding = precedingWord.flatMap(FunctionWordClass.init(word:))
    }

    public var isEmpty: Bool {
        preceding == nil
    }

    /// The context of every token in a block, aligned one-to-one with
    /// `tokens`.
    ///
    /// Computed over a block rather than a document, which is what stops a
    /// context reaching across a paragraph break. Whitespace is skipped —
    /// `很 重` with a space between is still a degree adverb modifying 重 —
    /// but punctuation is not, so it severs the relation, correctly.
    ///
    /// Shared by the two callers that need it: the model, deciding what to
    /// fetch, and the paragraph view, deciding what to look up. One function
    /// so the two can never disagree about what a token's context is, which
    /// they would otherwise express as pinyin flickering between two values.
    /// The context of one token, for a caller holding a position rather than
    /// a paragraph — a tap, which has no reason to classify every word around
    /// it to annotate one.
    public static func context(at index: Int, in tokens: [Token]) -> Self {
        guard tokens.indices.contains(index) else { return .none }
        var cursor = index - 1
        while cursor >= 0, tokens[cursor].kind == .whitespace {
            cursor -= 1
        }
        return Self(precedingWord: cursor >= 0 ? tokens[cursor].text : nil)
    }

    public static func contexts(in tokens: [Token]) -> [Self] {
        var contexts: [Self] = []
        contexts.reserveCapacity(tokens.count)
        var previous: String?
        for token in tokens {
            contexts.append(Self(precedingWord: previous))
            if token.kind != .whitespace {
                previous = token.text
            }
        }
        return contexts
    }
}

/// A word together with the context it appeared in.
///
/// The unit a context-sensitive reading is fetched and cached by. It replaces
/// the bare word as a cache key, which it has to: with context in the
/// picture, "what does 重 sound like" no longer has one answer per book.
public struct ReadingRequest: Hashable, Sendable {
    public let word: String
    public let context: ReadingContext

    public init(word: String, context: ReadingContext = .none) {
        self.word = word
        self.context = context
    }
}

/// Which reading a character takes in a given grammatical context.
///
/// ### Why a table at all
///
/// `ReadingComposer` ranks a character's readings by rules that know nothing
/// about the sentence — prefer lowercase, prefer a neutral tone, then prefer
/// whichever reading the dictionary says more about. That last step is a
/// frequency proxy, and it is wrong for exactly the characters where the
/// readings are different words: CC-CEDICT gives 重 five senses under `chóng`
/// ("to repeat") and three under `zhòng` ("heavy"), so 很重 — plainly "very
/// heavy" — was annotated `chóng`.
///
/// No context-free default can fix that, because both readings are right
/// somewhere. 重 is `chóng` in 重复 and `zhòng` in 很重, and the only thing
/// that separates them is what sits next to it.
///
/// ### Why it is small, and why it stays small
///
/// Each entry is a claim about one character under one grammatical
/// constraint, with the phrase that justifies it. The table holds only the
/// cases where the context *overturns* the context-free answer — 好, 难, 累,
/// 大 and 少 are already ranked correctly, and listing them would be noise
/// that hides the five real claims. `ReadingComposerTests` asserts those stay
/// correct, so if the generic ranking ever changes under them it fails there
/// rather than quietly needing a rule here.
///
/// This is not a part-of-speech tagger and is not a step towards one. It is a
/// finite set of statements of the form "after 很, 重 is `zhòng`", each of
/// which a reader of Chinese can check in a second.
public enum HeteronymRules {
    /// The numeric reading to prefer, or nil if nothing applies.
    ///
    /// Numeric because that is the cross-dictionary merge key: a rule written
    /// as `zhong4` picks the right entry out of CC-CEDICT, which stores
    /// numerals, and out of BKRS, which stores diacritics.
    public static func preferredReading(
        for headword: Headword,
        in context: ReadingContext,
    )
        -> String?
    {
        guard let preceding = context.preceding else { return nil }
        // Single characters only. A multi-character word's reading comes from
        // its own entry, where the dictionary has already resolved which of
        // its characters' readings applies — 重复 is `chóngfù` because the
        // dictionary says so, not because anything here decided.
        for script in headword.bothScripts where script.count == 1 {
            guard let character = script.first else { continue }
            if let reading = table[preceding]?[character] {
                return reading
            }
        }
        return nil
    }

    /// The reading a character takes when the sentence says nothing either
    /// way, for the few whose dictionary evidence points at a dead reading.
    ///
    /// Separate from the context rules above, and needed for a different
    /// reason. 重 needs context because both its readings are live: it is
    /// `chóng` in 重复 and `zhòng` in 很重, and only the neighbours separate
    /// them. 价 needs no context at all — `jiè` is simply not a reading of
    /// modern Chinese — but every signal available to the ranking points at
    /// it, because CC-CEDICT documents the archaic sense more thoroughly
    /// than the living one: four glosses for `jiè` "great, middleman"
    /// against three for `jià` "price", and a neutral tone besides. So 她叫
    /// 我给个价 was annotated `jiè`.
    ///
    /// The criterion is mechanical and the table is generated, not curated:
    /// a reading used by *no* multi-character headword, beside one used by
    /// many. Compounds are the evidence because that is where a character's
    /// living readings appear. Readings glossed as grammatical are excluded,
    /// or every sentence-final particle would qualify — 吧, 呢, 啊 and 吗 are
    /// all absent from compounds, and for a reason that has nothing to do
    /// with being archaic.
    ///
    /// Regenerate with `Scripts/heteronym-defaults.py`, which prints these
    /// lines verbatim.
    public static func defaultReading(for headword: Headword) -> String? {
        for script in headword.bothScripts where script.count == 1 {
            if let character = script.first, let reading = defaults[character] {
                return reading
            }
        }
        return nil
    }

    /// Internal rather than private so a test can check it against the
    /// context table: the two must stay disjoint, or the tier order starts
    /// deciding answers and someone has to argue it is the right one.
    static let defaults: [Character: String] = [
        // 161 compounds say jia4, none say jie5 "great/good/middleman/servant"
        "价": "jia4",
        "價": "jia4",
        // 21 compounds say zhui1, none say chui2 "a hammer"
        "椎": "zhui1",
        // 65 compounds say pao4, none say bao1 "to sauté/to fry/to dry by heating"
        "炮": "pao4",
        // 87 compounds say luo4, none say lao4 "small net"
        "络": "luo4",
        "絡": "luo4",
        // 38 compounds say gao1, none say gao4 "to moisten/to grease/to apply"
        "膏": "gao1",
    ]

    /// A degree adverb forces the stative reading. Each line is the phrase
    /// that justifies it, and the reading the context-free ranking picked
    /// instead.
    static let table: [FunctionWordClass: [Character: String]] = [
        .degreeAdverb: [
            // 很重 "very heavy", not chóng "to repeat"
            "重": "zhong4",
            // 很长 "very long", not zhǎng "chief, to grow". Both scripts
            // spelled out because an entry may carry only one of them, in
            // which case `bothScripts` cannot supply the other.
            "长": "chang2",
            "長": "chang2",
            // 很空 "very empty", not kòng "vacancy, free time"
            "空": "kong1",
            // 很差 "very poor", not chā "difference"
            "差": "cha4",
            // 很薄 "very thin", not bó "meagre, slight"
            "薄": "bao2",
        ],
        // Only where negating either reading lands on the same answer. 长 and
        // 薄 are deliberately absent: 不长 can be "does not grow" and 待我不薄
        // is `bó`, so a negator does not settle them the way a degree adverb
        // does.
        .negator: [
            // 不重 "not heavy" — "does not repeat" would be 不重复
            "重": "zhong4",
            // 不差 "not bad", also 不差钱 — never chā "difference"
            "差": "cha4",
            // 不空 "not empty" — free time is 没空, not 不空
            "空": "kong1",
        ],
    ]
}
