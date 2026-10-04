# CC-CEDICT

**This directory is not covered by the repository's MIT license.** The data
here is third-party material licensed under Creative Commons
Attribution-ShareAlike — see [Why 3.0 and not 4.0](#why-30-and-not-40) below
for which version, and why. The full license text, matching the pinned
snapshot, is in [`LICENSE`](LICENSE).

## Required attribution

CC BY-SA obliges us to carry the following, and to keep it reaching end
users — not just readers of this repository. HanReader satisfies the latter
through its in-app Acknowledgements screen, which renders this attribution from
each installed dictionary's own metadata.

> **Title:** CC-CEDICT — a bilingual Chinese-English dictionary
> **Creator:** The CC-CEDICT Project (originally MDBG, continuing the CEDICT
> project begun by Paul Denisowski)
> **Source:** <https://www.mdbg.net/chinese/dictionary?page=cc-cedict>
> **License:** Creative Commons Attribution-ShareAlike **3.0** Unported
> (<http://creativecommons.org/licenses/by-sa/3.0/>)
> **Changes made:** The dictionary was parsed from its distributed `.u8` text
> format and converted into a SQLite database for lookup. Numeric-tone pinyin
> (`ai4`) was additionally rendered into diacritic form (`ài`) for display, and
> per-character readings and a segmentation word list were derived from the
> headword set. No entry content was altered, removed, or added.

That "Changes made" statement is a license requirement for adaptations, not a
courtesy. Keep it accurate if the conversion pipeline changes.

## Why 3.0 and not 4.0

Current upstream CC-CEDICT is licensed CC BY-SA **4.0**. The snapshot pinned
here declares **3.0**, because it came from a GitHub mirror: mdbg.net was
serving at roughly 12 KB per 8 minutes when this was pinned, which made a
direct download impractical.

The attribution above therefore states 3.0, because **that is what the pinned
data actually declares**, and attribution must describe the material shipped
rather than the material we would prefer to ship. `SOURCE.json` records the
mirror URL alongside the canonical upstream one.

Two consequences worth knowing:

- This snapshot is from 2013 and carries 107,619 entries, where current
  upstream carries roughly 125,000. Perfectly usable, but older.
- `hanreader-dictgen` reads the licence from the file's `#! license=` header
  rather than assuming one, so a container built from this snapshot correctly
  records BY-SA 3.0, and one built from a refreshed snapshot will correctly
  record 4.0.

Refresh with `./Scripts/update-cedict.sh` once mdbg.net is reachable. The
script prints a reminder to update the licence quoted above when it changes,
and a CI check fails if this file and the data ever disagree.

## ShareAlike consequence

A dictionary database generated from this data is an **Adapted Work** under
CC BY-SA and is therefore itself licensed CC BY-SA, at the version the source
declares — *not* MIT. This
matters the moment anyone publishes a prebuilt `.hanreaderdict` as a release
artifact or distributes a built app: the data and any database derived from it
carry BY-SA, while HanReader's own source code remains MIT. The two licenses
coexist; they do not merge.

## Snapshot, not a live fetch

CC-CEDICT is updated upstream almost daily. This directory pins a specific
snapshot so that builds are reproducible and so that every update to the
bundled data arrives as a reviewable pull request. `SOURCE.json` records the
upstream URL, the byte size, the SHA-256, the entry count, and the retrieval
date of the pinned file.

Do not replace the pinned file by hand. Run `Scripts/update-cedict.sh`, which
re-downloads, re-verifies, regenerates `SOURCE.json`, and leaves the result for
review. A scheduled CI job does the same thing monthly and opens the PR for you.

## Why this dictionary is load-bearing beyond English glosses

CC-CEDICT is not merely "the English dictionary." It is also HanReader's pinyin
and segmentation backbone, for every language mode:

- **Pinyin.** 77% of entries in the BKRS Chinese-Russian dictionary (2,650,218
  of 3,434,222) store no reading at all. CC-CEDICT supplies 10,494 distinct
  single-character headwords, which is what makes a per-character pinyin
  fallback possible for words no dictionary lists as a unit.
- **Segmentation.** CC-CEDICT's ~125,000 headwords are genuinely word-level.
  BKRS has 532,881 headwords of seven characters or more — idioms, proper nouns
  and phrase-level entries — so maximum-matching over its raw headword set
  would swallow whole clauses.

Consequently CC-CEDICT remains installed as a phonetic and lexical source even
when a user disables it as a *gloss* source in favour of a Russian dictionary.
