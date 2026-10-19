#!/usr/bin/env python3
"""Find characters whose dictionary evidence points at the wrong reading.

`ReadingComposer` has no part-of-speech information, so for a character with
several readings it prefers a neutral tone and then whichever reading the
dictionary says most about. Both are proxies, and for a handful of characters
both point at a reading no living text uses: CC-CEDICT documents 价 as `jiè`
("great, middleman") in four senses and as `jià` ("price") in three, so the
reader annotated 她叫我给个价 with `jiè`.

This reports the characters where that happens, by a criterion the dictionary
can answer on its own: a reading used by *no* multi-character headword, beside
one used by many. Compounds are the evidence because they are where a
character's living readings show up — 价格, 物价, 评价, 代价 are all `jià`,
and nothing is `jiè`.

Readings glossed as grammatical are excluded. A sentence-final particle is
unattested in compounds for a reason that has nothing to do with being
archaic: 吧, 呢, 啊 and 吗 would otherwise all be "corrected" to a toned
reading nobody wants.

Run against the pinned snapshot; paste the result into `HeteronymRules`:

    ./Scripts/heteronym-defaults.py Dictionaries/cc-cedict/cedict_ts.u8
"""

import argparse
import collections
import io
import re
import sys

ENTRY = re.compile(r"^(\S+) (\S+) \[([^\]]*)\] /(.*)/$")

# What CC-CEDICT writes when a reading is a function word rather than a word.
GRAMMATICAL = (
    "particle",
    "suffix",
    "suff.",
    "prefix",
    "marker",
    "interjection",
    "classifier",
    "onomatop",
)

# Below this, a rival reading is not well enough attested to overrule the
# dictionary's own emphasis. The gap this exists to catch is absolute — many
# against none — not narrow.
MINIMUM_RIVAL = 20


def is_han(character):
    return "一" <= character <= "鿿"


def read(path):
    """Single-character entries, and per-character reading counts in compounds."""
    entries = collections.defaultdict(list)
    compounds = collections.defaultdict(collections.Counter)
    with io.open(path, encoding="utf-8") as handle:
        for line in handle:
            if line.startswith("#"):
                continue
            matched = ENTRY.match(line.strip())
            if not matched:
                continue
            _, simplified, reading, definition = matched.groups()
            if len(simplified) == 1:
                entries[simplified].append((reading, definition.split("/")))
            syllables = reading.split()
            # Only where every character maps to exactly one syllable, which
            # is what makes the alignment below sound.
            if (
                len(simplified) >= 2
                and len(simplified) == len(syllables)
                and all(is_han(c) for c in simplified)
            ):
                for character, syllable in zip(simplified, syllables):
                    compounds[character][syllable.lower()] += 1
    return entries, compounds


def is_neutral(reading):
    return any(syllable[-1] == "5" for syllable in reading.split())


def is_capitalised(reading):
    return reading[0].isupper()


def chosen(readings):
    """What `ReadingComposer.isWeaker` picks: lowercase, neutral tone, senses."""
    return sorted(
        readings,
        key=lambda r: (is_capitalised(r[0]), not is_neutral(r[0]), -len(r[1]), r[0]),
    )[0]


def report(path):
    entries, compounds = read(path)
    rows = []
    for character, readings in sorted(entries.items()):
        usable = [r for r in readings if r[0] and "xx5" not in r[0]]
        if len({r[0].lower() for r in usable}) < 2:
            continue
        winner = chosen(usable)
        if compounds[character].get(winner[0].lower(), 0) != 0:
            continue
        rivals = [
            (reading, count)
            for reading, count in compounds[character].most_common()
            if reading != winner[0].lower()
        ]
        if not rivals or rivals[0][1] < MINIMUM_RIVAL:
            continue
        glosses = [g for r in usable if r[0].lower() == winner[0].lower() for g in r[1]]
        if any(mark in g.lower() for g in glosses for mark in GRAMMATICAL):
            continue
        rows.append((character, rivals[0][0], rivals[0][1], winner[0], glosses))

    for character, reading, count, instead, glosses in rows:
        print(
            '            // {} compounds say {}, none say {} "{}"'.format(
                count, reading, instead, "/".join(glosses)[:48]
            )
        )
        print('            "{}": "{}",'.format(character, reading))
    return 0 if rows else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("dictionary", help="path to cedict_ts.u8")
    return report(parser.parse_args().dictionary)


if __name__ == "__main__":
    sys.exit(main())
