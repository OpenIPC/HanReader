# Dictionaries

HanReader treats dictionaries as pluggable sources. Install several and you see
all of their glosses for a word at once, each attributed to where it came from.

## CC-CEDICT (Chinese→English) — bundled

Nothing to do. CC-CEDICT ships with HanReader as a prepared database, ready
the moment you launch it — no setup, no wait, no download.

It is compiled when the app is *built* rather than when it is first run. The
repository stores the dictionary as reviewable text, which takes a couple of
seconds to parse; doing that on first launch would be a couple of seconds you
spend staring at a progress bar, so the build does it once instead and the app
opens the result in under a millisecond.

It is licensed CC BY-SA; see
[`../Dictionaries/cc-cedict/`](../Dictionaries/cc-cedict/) for the version and
attribution.

CC-CEDICT also does two jobs beyond English definitions, which is why HanReader
keeps using it even if you prefer a different dictionary for glosses:

- **Pinyin.** It supplies readings for over ten thousand individual characters,
  which is how HanReader shows pinyin for words that no dictionary lists as a
  single entry. The Chinese-Russian dictionary, by contrast, has no reading at
  all for roughly 77% of its entries.
- **Word segmentation.** Its headwords are genuinely word-level, which makes
  them a good basis for deciding where one word ends and the next begins.

So if you disable CC-CEDICT as a *gloss* source in favour of a Russian
dictionary, HanReader still uses it quietly for pronunciation and segmentation.

## BKRS / 大БКРС (Chinese→Russian) — you supply the file

HanReader ships an importer for dictionaries in **ABBYY DSL format**, which is
how БКРС is distributed. It does not ship, download, or redistribute the data:
that data is not freely licensed, and obtaining it is up to you. The БКРС
project lives at <https://bkrs.info/>.

### Importing

1. Put the `.dsl` files somewhere you can reach them. A full БКРС set is
   typically three files of roughly 117 MB each, around 350 MB in total.
2. In HanReader, open **Dictionaries** and choose **Import…**, then select *any
   one* of the files. HanReader reads the `#INCLUDE` directives in the main file
   and finds its companions in the same folder automatically — you do not need
   to select all three.
3. The import streams through the files and takes roughly a minute and a half on
   an Apple-silicon Mac, producing a database of about 210–240 MB.

The import is **resumable**. If you quit the app, or iOS suspends it, the next
launch offers to carry on from where it stopped rather than starting over.

### On iOS

Importing 350 MB of source on a phone works, but it is not the pleasant path:
you need the source files *plus* room for the resulting database, and the import
takes several minutes during which iOS may suspend the app.

The better route is to import on a Mac and then move the finished result across:
**Dictionaries → Export…** writes a single compiled `.hanreaderdict` file that
iOS can import directly, with no parsing at all. Send it over AirDrop or put it
in iCloud Drive.

Note that HanReader excludes dictionary databases from your device backup. They
are large and fully regenerable, so backing them up would just inflate your
backup.

## Choosing which dictionary wins

When several dictionaries define the same word, HanReader shows all of them,
ordered by a list you can drag to rearrange. The initial order follows your
system language preferences, so a Russian-language system puts БКРС first
without you configuring anything.

Readings are matched *across* dictionaries, so a word with two pronunciations —
了 as `le` and as `liǎo`, say — groups the English and Russian senses under the
correct reading rather than interleaving them arbitrarily.

## Other formats

Support for additional formats is welcome. The parsers live behind a small
protocol in `HanReaderCore/Format/`; see
[`../CONTRIBUTING.md`](../CONTRIBUTING.md#adding-a-dictionary-format).
