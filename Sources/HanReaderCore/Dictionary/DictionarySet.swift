// HanReader — MIT licensed. See LICENSE.

import Foundation

/// An entry together with the dictionary it came from.
///
/// The source travels with the entry rather than being looked up later,
/// because it is not decoration: CC-CEDICT is CC BY-SA, and attribution has
/// to reach the reader at the point they read the gloss. It is also the only
/// way to render two dictionaries' answers for one word without implying they
/// are one dictionary's.
public struct AttributedEntry: Hashable, Sendable {
    /// The dictionary's slug, as its container records it.
    public let dictionary: String
    public let entry: DictionaryEntry

    public init(dictionary: String, entry: DictionaryEntry) {
        self.dictionary = dictionary
        self.entry = entry
    }
}

/// Every dictionary's entries for one word that share a reading.
///
/// Grouped by reading, and that is the crux of consulting several
/// dictionaries at once. 了 is `le` in one and `liǎo` in another; without
/// grouping, a reader tapping it sees four entries and no indication that two
/// of them are the same word said the same way.
public struct ReadingGroup: Hashable, Sendable {
    /// Numeric pinyin — the cross-dictionary merge key. BKRS writes
    /// diacritics and CC-CEDICT numerals, and both normalise to this.
    ///
    /// Empty for the group of entries that carry no reading at all, which is
    /// 77% of BKRS.
    public let readingKey: String
    public let entries: [AttributedEntry]

    public init(readingKey: String, entries: [AttributedEntry]) {
        self.readingKey = readingKey
        self.entries = entries
    }

    /// The reading as the reader should see it, taken from the first entry
    /// that has one.
    ///
    /// From an entry rather than converted back from the key, so the
    /// dictionary's own spelling is what shows — including the apostrophe in
    /// `tǔ'ěrqísītǎn`, which a round trip through the key would lose.
    public var readingDisplay: String {
        entries.first { !$0.entry.reading.isEmpty }?.entry.readingDisplay ?? ""
    }
}

/// The dictionaries a lookup consults, in the reader's order.
///
/// ### Nothing is ever deduplicated
///
/// Two dictionaries defining the same word are two answers, not one with a
/// duplicate. Merging them would mean choosing whose wording survives, which
/// is both a licensing problem — CC BY-SA attribution is per work — and a
/// usability one, since the reason to install a second dictionary is to read
/// what it says.
///
/// ### Glosses, readings and the word list are separate permissions
///
/// A reader can turn off CC-CEDICT's English glosses and still need it: 77%
/// of BKRS entries carry no reading, so CC-CEDICT's ten thousand
/// single-character headwords are what put pinyin on the page in *both*
/// language modes. Treating "enabled" as one switch would let a Russian
/// reader turn off the thing their ruby depends on. So the three uses are
/// three flags, and `providesReadings` stays on for a dictionary disabled as
/// a gloss source.
public struct DictionarySet: Sendable {
    /// One installed dictionary and what it is allowed to do.
    public struct Member: Sendable {
        public let slug: String
        public let lookup: any DictionaryLookup
        /// Whether its definitions are shown to the reader.
        public let providesGlosses: Bool
        /// Whether its readings feed the ruby above the text.
        public let providesReadings: Bool

        public init(
            slug: String,
            lookup: any DictionaryLookup,
            providesGlosses: Bool = true,
            providesReadings: Bool = true,
        ) {
            self.slug = slug
            self.lookup = lookup
            self.providesGlosses = providesGlosses
            self.providesReadings = providesReadings
        }
    }

    /// In the order the reader wants them, which decides which dictionary a
    /// detail panel shows first.
    public let members: [Member]

    public init(members: [Member]) {
        self.members = members
    }

    public var isEmpty: Bool {
        members.isEmpty
    }

    // MARK: - Looking up

    /// Every gloss-providing dictionary's entries for a word, grouped by
    /// reading.
    ///
    /// Groups come out in the order their reading was first seen, walking the
    /// dictionaries in the reader's order — so the first group is the first
    /// reading of the dictionary they put first, which is the one a detail
    /// panel should open on. Entries within a group keep that order too.
    ///
    /// A dictionary that throws is skipped rather than failing the lookup:
    /// one unreadable container should cost its own answers, not the answers
    /// of every other dictionary installed.
    public func groups(for headword: String) -> (groups: [ReadingGroup], failures: [String]) {
        var order: [String] = []
        var byKey: [String: [AttributedEntry]] = [:]
        var failures: [String] = []

        for member in members where member.providesGlosses {
            let entries: [DictionaryEntry]
            do {
                entries = try member.lookup.entries(for: headword)
            } catch {
                failures.append(member.slug)
                continue
            }
            for entry in entries {
                let key = entry.readingKey
                if byKey[key] == nil {
                    order.append(key)
                }
                byKey[key, default: []].append(
                    AttributedEntry(dictionary: member.slug, entry: entry),
                )
            }
        }
        return (
            order.map { ReadingGroup(readingKey: $0, entries: byKey[$0] ?? []) },
            failures,
        )
    }
}

// MARK: - Reading the set as one dictionary

/// So the reading composer, which only wants to know what a word sounds like,
/// can consult the whole set without knowing there is a set.
///
/// This path uses `providesReadings`, not `providesGlosses` — the distinction
/// the two flags exist for.
extension DictionarySet: DictionaryLookup {
    /// The entries a reading should be chosen from: the **first**
    /// reading-providing dictionary that has any, not every dictionary's
    /// concatenated.
    ///
    /// Concatenating them broke reading selection the moment a second
    /// dictionary was installed, and visibly: 遭打 went from `zāo dǎ` to
    /// `zāo dá`. The composer ranks candidates partly by how many senses
    /// carry them, which is a sound signal *within* one dictionary and
    /// meaningless across two — and especially so for BKRS, where one entry
    /// per reading shares a single sense run by design, so all of 打's
    /// readings have 57 senses and the tie falls to alphabetical order. A
    /// dictionary with more senses per entry would simply outvote a better
    /// answer from a dictionary the reader put first.
    ///
    /// So the reader's ordering decides, which is what they set it for, and
    /// each dictionary's own ranking is applied to its own entries.
    public func entries(for headword: String) throws -> [DictionaryEntry] {
        for member in members where member.providesReadings {
            if let entries = try? member.lookup.entries(for: headword), !entries.isEmpty {
                return entries
            }
        }
        return []
    }

    /// The first reading-providing dictionary that knows the character.
    ///
    /// First rather than merged: the ranking within a container is computed
    /// over that container's whole headword set, and interleaving two
    /// rankings produces an order neither dictionary would endorse. The
    /// reader's ordering decides, which is what they set it for.
    public func readings(forCharacter character: Character) throws -> [CharacterReading] {
        for member in members where member.providesReadings {
            if let readings = try? member.lookup.readings(forCharacter: character),
               !readings.isEmpty
            {
                return readings
            }
        }
        return []
    }
}
