# Test fixtures

## `cedict-sample.u8`

A small slice of real **CC-CEDICT** data, used by the parser tests.

Real data rather than hand-written lines, because the cases that break a parser
are the ones nobody thinks to invent — the eight entries for 和, the four `u:`
bases, `m2`, the interpunct in transliterated names.

Regenerate with:

```sh
./Scripts/extract-cedict-fixture.py path/to/cedict_ts.u8
```

That script records why each entry is included, so the slice can be rebuilt
rather than hand-edited when the parser grows new cases.

**Licensing.** This is CC-CEDICT data and carries the same terms as the bundled
snapshot: Creative Commons Attribution-ShareAlike 4.0 International. See
[`../../../Dictionaries/cc-cedict/README.md`](../../../Dictionaries/cc-cedict/README.md)
for the full attribution, and
[`../../../Dictionaries/cc-cedict/LICENSE`](../../../Dictionaries/cc-cedict/LICENSE)
for the license text.

## `bkrs-slice.dsl.txt`

203 cards of real **大БКРС** data, used by the DSL importer tests, with
`bkrs-slice.manifest.txt` recording why each one is in there.

Two kinds of card, because they catch different things. Thirteen are picked
deliberately — 爱, 了, 一 and 打 for their sense structure, plus one card for
each piece of markup the format uses, including the single card in 3,434,224
whose article breaks a line inside an open `[m1]`. The other 190 are a
contiguous run taken verbatim, which covers the shapes nobody thought to pick
at a realistic density.

Regenerate with:

```sh
./Scripts/extract-dsl-fixture.py path/to/dabkrs_1.dsl
```

**UTF-8 with no byte-order mark**, where the source files are UTF-16LE+BOM. A
UTF-8 file stays diffable in a pull request; the tests re-encode it to
UTF-16LE+BOM at runtime and assert both readings produce identical cards, so
the committed bytes are reviewable and the real encoding path is still
exercised. DSL has no comment syntax — a `#` line is a directive — which is
why the reasons are in the manifest rather than inline.

**Licensing.** 大БКРС is **not** freely licensed and is not ours to
redistribute; HanReader ships an importer, not the data. This slice exists
under the one exception
[`CONTRIBUTING.md`](../../../CONTRIBUTING.md#do-not-add-dictionary-data-to-this-repository)
names. Do not
enlarge it, and do not commit the source files.

---

Keep fixtures small — CI fails any file here over 256 KB. If a test needs more
data than that, it wants a generator, not a bigger fixture.
