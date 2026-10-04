# HanReader

A reader for Chinese texts that gets out of your way: tap any word to see its
pinyin above the characters and its meaning below, and hear it spoken. For macOS
and iOS.

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
![Platforms](https://img.shields.io/badge/platforms-macOS%2014%2B%20%7C%20iOS%2017%2B-lightgrey)

> **Status: early development.** HanReader is being rebuilt from a working
> private prototype into something publishable. `make run` builds and launches
> on macOS and iOS today, but the window is still a placeholder — the reader
> itself arrives in milestone M5. See [Roadmap](#roadmap) for the order of
> work. There are no downloadable builds yet; see
> [Building from source](#building-from-source).

---

## What it does

Import a Chinese text and read it with the help one tap away, rather than in a
separate window:

- **Tap a word** to reveal its pinyin as a ruby annotation *above* the
  characters — the surrounding text never shifts or reflows when you do.
- **Definitions** appear in a panel that stays a fixed size, so the text below
  it never jumps as you move from word to word.
- **Hear it.** Tapping a word speaks it.
- **Follow along with audio.** Attach a narration file to a text and scrub it at
  0.75× to 1.5×.
- **Two reading modes** — visibly word-segmented, or continuous as it would
  actually be printed.
- **It remembers.** Your position and the words you have revealed survive
  relaunching, and your position survives changing the font size.

### Dictionaries

**CC-CEDICT (Chinese→English) is bundled, so HanReader works the moment you
launch it.** No downloads, no setup.

**BKRS / 大БКРС (Chinese→Russian) can be imported** if you have it. HanReader
ships the importer; it does not ship the data, which is not freely licensed.
Both dictionaries are first-class: install both and you see both glosses at
once, each attributed to its source. See [`Docs/DICTIONARIES.md`](Docs/DICTIONARIES.md).

---

## Building from source

```sh
git clone https://github.com/OpenIPC/HanReader.git
cd HanReader
make run
```

`make` bootstraps its own pinned, checksum-verified copies of XcodeGen,
SwiftLint, and SwiftFormat into `.tools/`. You do not need Homebrew, and you do
not need an Apple Developer account — local builds are ad-hoc signed.

Prefer Xcode? **`open Package.swift`** builds every library target and runs the
whole test suite with no additional tooling. You only need `make` to produce a
runnable application bundle.

| | Build | Run |
|---|---|---|
| macOS | macOS 15.6+, Xcode 26.6 | macOS 14.0+ |
| iOS | Xcode 26.6 + an iOS 26.x simulator runtime | iOS 17.0+ |

Working on iOS additionally needs a simulator runtime, which Xcode does not
install by default: `xcodebuild -downloadPlatform iOS` (~10 GB).

See [`CONTRIBUTING.md`](CONTRIBUTING.md) for the full developer guide.

---

## Architecture

The engine is platform-agnostic Swift with no UI framework anywhere in it, which
is what lets macOS and iOS share essentially everything but a handful of
platform shims.

```
HanReaderCore          Foundation only -- builds on Linux
  HanReaderTokenization    + NaturalLanguage
  HanReaderPersistence     + GRDB
    HanReaderDictionaryImport
      hanreader-dictgen      (CLI: compiles dictionaries)
  HanReaderPlayback        + AVFoundation / MediaPlayer
  HanReaderPlatform        + AppKit / UIKit  (deliberately tiny)
  HanReaderUI              SwiftUI only
    Apps/macOS, Apps/iOS
```

Those boundaries are enforced mechanically rather than by convention: a Linux CI
job builds `HanReaderCore` in isolation, `InternalImportsByDefault` turns a
leaked database type into a compile error, and SwiftLint rules reject stray
framework imports. Details in [`Docs/ARCHITECTURE.md`](Docs/ARCHITECTURE.md).

## Roadmap

- [x] **M0** — license boundary and repository scaffolding
- [x] **M1** — package skeleton, toolchain bootstrap, CI green on both platforms
- [ ] **M2** — pinyin engine, CC-CEDICT parser, database and migrations
- [ ] **M3** — dictionary pipeline and zero-setup first launch
- [ ] **M4** — word segmentation and the line-breaking core
- [ ] **M5** — **the macOS reader: first usable version**
- [ ] **M6** — BKRS DSL import
- [ ] **M7** — audio playback
- [ ] **M8** — iOS and iPadOS
- [ ] **M9** — accessibility and Russian localization
- [ ] **M10** — 1.0

Signed and notarized releases, a Homebrew cask, and TestFlight are deliberately
out of scope for now and tracked separately.

## Contributing

Contributions are welcome — see [`CONTRIBUTING.md`](CONTRIBUTING.md). One rule
worth stating up front: **please do not add dictionary data to this repository.**
HanReader imports dictionaries; it does not redistribute them.

## License

**Code: [MIT](LICENSE).**

**Bundled dictionary data: CC BY-SA.** CC-CEDICT lives in
[`Dictionaries/cc-cedict/`](Dictionaries/cc-cedict/) under its own license, and
a dictionary database generated from it is an adaptation that carries CC BY-SA
too — not MIT.

[`NOTICE`](NOTICE) states exactly where that boundary falls, and
[`THIRD-PARTY-NOTICES.md`](THIRD-PARTY-NOTICES.md) lists every component with
its attribution.

## Acknowledgements

- **[CC-CEDICT](https://www.mdbg.net/chinese/dictionary?page=cc-cedict)** and
  MDBG, continuing the CEDICT project begun by Paul Denisowski — the bundled
  dictionary, and also HanReader's pinyin and segmentation backbone.
- **[БКРС](https://bkrs.info/)** — the Chinese-Russian dictionary community
  whose data HanReader can import.
- **[GRDB.swift](https://github.com/groue/GRDB.swift)** by Gwendal Roué.
- The interaction model owes an obvious debt to Du Chinese.
