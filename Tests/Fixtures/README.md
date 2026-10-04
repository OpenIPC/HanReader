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
[`../../Dictionaries/cc-cedict/README.md`](../../Dictionaries/cc-cedict/README.md)
for the full attribution, and
[`../../Dictionaries/cc-cedict/LICENSE`](../../Dictionaries/cc-cedict/LICENSE)
for the license text.

Keep fixtures small — CI fails any file here over 256 KB. If a test needs more
data than that, it wants a generator, not a bigger fixture.
