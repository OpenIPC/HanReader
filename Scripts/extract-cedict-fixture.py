#!/usr/bin/env python3
"""Extract the committed CC-CEDICT test fixture from a full dictionary file.

The fixture is a deliberately small slice of real CC-CEDICT data, chosen to
cover every shape the parser has to handle. It is committed so the tests are
hermetic and fast; this script exists so its provenance is documented and the
slice can be regenerated rather than hand-maintained.

    ./Scripts/extract-cedict-fixture.py path/to/cedict_ts.u8

Writes Tests/Fixtures/cedict-sample.u8.

The data is CC BY-SA 4.0. See Dictionaries/cc-cedict/README.md for attribution;
the fixture carries the same terms as the bundled snapshot.
"""

from __future__ import annotations

import pathlib
import re
import sys

GRAMMAR = re.compile(r"^(\S+) (\S+) \[([^\]]*)\] /(.*)/$")

# Headwords chosen for a specific reason, so a future edit can tell what each
# one is protecting. Anything whose purpose is not obvious gets a note.
WANTED: dict[str, str] = {
    # Homographs: one headword, several readings. The prototype's
    # `WHERE simplified = ? LIMIT 1` lookup destroyed all of these.
    "了": "homograph: le5 and liao3",
    "好": "homograph: hao3 and hao4",
    "和": "homograph with eight entries",
    "宿": "single character with four readings",
    # Traditional differing from simplified, and not differing.
    "中国": "trad != simp",
    "你好": "trad == simp",
    # The ü bases, all four of them.
    "女": "nu:3",
    "略": "lu:e4",
    "虐": "nu:e4",
    "旅": "lu:3",
    # Tone placement cases the renderer must get right.
    "六": "liu4 -> liù, mark on the u",
    "对": "dui4 -> duì, mark on the i",
    "北京": "capitalised proper noun",
    # Erhua and the neutral tone.
    "花儿": "erhua r5",
    "明白": "word-internal neutral tone",
    # Cross-references in glosses, with and without a pinyin annotation.
    "狮子": "gloss with a | cross-reference",
    # Reference-kind senses.
    "妳": "variant of",
    "薛": "surname",
    # Punctuation inside glosses.
    "爱": "common word, multiple senses",
    "一": "very common, many senses",
}


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__)
        return 2

    source = pathlib.Path(sys.argv[1])
    repo = pathlib.Path(__file__).resolve().parent.parent
    out_path = repo / "Tests" / "Fixtures" / "cedict-sample.u8"

    lines = source.read_text(encoding="utf-8").split("\n")

    header: list[str] = []
    picked: list[str] = []
    seen: set[str] = set()
    # Homographs must contribute EVERY entry, not just the first. Taking one
    # per headword would quietly remove the thing they are in the fixture to
    # protect: 了 has both le5 and liao3, and a parser that keeps only one
    # would still pass.
    multi = {"了", "好", "和", "宿"}

    # Non-syllable pinyin forms, the 22-sense maximum, and glosses containing
    # characters that could confuse a naive splitter. Collected by scanning
    # rather than by headword, since which entry carries them is incidental.
    specials = {
        "xx5": None,
        "comma": None,
        "interpunct": None,
        "latin": None,
        "m2": None,
        "max_senses": None,
        "quote": None,
        "semicolon": None,
        "bracket_xref": None,
    }

    for raw in lines:
        line = raw.rstrip("\r")
        if not line:
            continue
        if line.startswith("#"):
            # Keep the metadata header: entry counts and the version date are
            # asserted against the parsed result.
            if line.startswith("#!") or len(header) < 2:
                header.append(line)
            continue

        match = GRAMMAR.match(line)
        if not match:
            continue
        _, simplified, pinyin, defs = match.groups()
        senses = [s for s in defs.split("/") if s]

        if simplified in WANTED and (simplified in multi or simplified not in seen):
            seen.add(simplified)
            picked.append(line)

        if specials["xx5"] is None and "xx5" in pinyin.split():
            specials["xx5"] = line
        if specials["comma"] is None and "," in pinyin:
            specials["comma"] = line
        if specials["interpunct"] is None and "·" in pinyin:
            specials["interpunct"] = line
        if specials["latin"] is None and any(
            len(t) == 1 and t.isalpha() and t.isupper() for t in pinyin.split()
        ):
            specials["latin"] = line
        if specials["m2"] is None and "m2" in pinyin.split():
            specials["m2"] = line
        if specials["max_senses"] is None and len(senses) >= 20:
            specials["max_senses"] = line
        if specials["quote"] is None and '"' in defs:
            specials["quote"] = line
        if specials["semicolon"] is None and ";" in defs:
            specials["semicolon"] = line
        if specials["bracket_xref"] is None and "|" in defs and "[" in defs:
            specials["bracket_xref"] = line

    for key, line in specials.items():
        if line is None:
            print(f"warning: no entry found for {key}", file=sys.stderr)
        elif line not in picked:
            picked.append(line)

    missing = sorted(set(WANTED) - seen)
    if missing:
        print(f"warning: headwords not found: {missing}", file=sys.stderr)

    out_path.parent.mkdir(parents=True, exist_ok=True)
    body = "\r\n".join(header + sorted(picked)) + "\r\n"
    out_path.write_text(body, encoding="utf-8", newline="")

    print(f"wrote {out_path.relative_to(repo)}")
    print(f"  {len(header)} header lines, {len(picked)} entries, {len(body)} bytes")
    return 0


if __name__ == "__main__":
    sys.exit(main())
