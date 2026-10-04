# Changelog

All notable changes to HanReader are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Entries are curated by hand, not generated from commit messages: the release
workflow publishes a version's section verbatim as its GitHub Release body, so
it needs to read like release notes rather than a commit log.

## [Unreleased]

### Added

- Initial repository scaffolding: license boundary between the MIT-licensed
  source and the CC BY-SA bundled dictionary data, contribution guide,
  security policy, and editor/VCS configuration.
- SwiftPM package defining the nine-target module graph, with the architecture's
  boundaries enforced by the build: `HanReaderCore` imports only Foundation and
  is compiled on Linux in CI to prove it, and `InternalImportsByDefault` makes a
  leaked database type a compile error.
- `hanreader-dictgen` command-line target, which will compile dictionaries into
  the distributable container.
- Developer tooling that bootstraps itself: `make run` fetches pinned,
  checksum-verified copies of XcodeGen, SwiftLint and SwiftFormat into
  `.tools/`, so a clone builds with nothing installed but Xcode. Run `make` for
  the target list, or `make doctor` for an environment report.
- SwiftLint rules that enforce the module boundaries at edit time, including
  bans on AppKit outside the platform shim, `NaturalLanguage` outside the
  tokenization module, database imports outside persistence, and hard-coded
  design values in views.
- macOS and iOS application targets, generated from `project.yml` by XcodeGen
  and sharing one SwiftUI scene. `make run` and `make run-ios` build and launch
  them; the window is a placeholder until the reader lands in M5.
- Layered `.xcconfig` build settings with an optional per-machine
  `Local.xcconfig`, so the repository contains no team identifier and forks
  build without one.
- Pinyin engine: tone placement, conversion between CC-CEDICT's numeric form
  and display diacritics in both directions, parsing of the pinyin field
  including its separators and literals, and syllabification of run-together
  readings so the same word matches across dictionaries that spell it
  differently.
- CC-CEDICT parser and the dictionary model, with senses, cross-references
  extracted from gloss text, and entries keyed by headword *and* reading so
  that words with several pronunciations keep all of them.
- Line breaking as a pure function over measured items, with the CJK rule
  that matters most: a line never begins with a full stop or closing bracket,
  and never ends with an opening one. Being pure arithmetic rather than view
  code is what lets it be tested exhaustively without rendering anything.
- Word segmentation: paragraph and script-run handling, a deterministic
  maximum-matching segmenter over the dictionary's own lexicon, a wrapper
  around Apple's tokenizer, and a repair pass that rejoins compounds the
  tokenizer splits. Tokens now carry their position in the source, which is
  what makes restoring a reading position possible at all.
- The bundled dictionary itself: a pinned CC-CEDICT snapshot, compiled during
  the build so a clean clone launches with a working dictionary and no setup.
  `Scripts/update-cedict.sh` refreshes the pin, and CI fails if the committed
  data, its checksum and its declared licence ever disagree.
- Dictionary containers: a self-contained `.hanreaderdict` SQLite file per
  dictionary, carrying its own licence and attribution so the terms travel with
  the data. Compiled at build time rather than on first launch, which is what
  lets the app open a 32 MB dictionary in under a millisecond instead of
  spending nearly three seconds parsing text.
- `hanreader-dictgen cedict` and `verify`, which compile and check a
  dictionary and refuse to produce one that has silently lost entries.
- Derived from the dictionary rather than written by hand: the segmentation
  word list, per-character pinyin readings, and the syllable inventory.
- Library database on GRDB, with versioned migrations from the first release.
  Texts deduplicate on content rather than title, reading position is stored as
  a character offset so it survives a font-size change, revealed words are
  relational rather than a packed string, audio paths are relative so they
  survive an iOS restore, and deleting a text actually removes everything
  attached to it.

[Unreleased]: https://github.com/OpenIPC/HanReader/commits/main
