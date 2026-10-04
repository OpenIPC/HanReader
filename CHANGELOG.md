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
  source and the CC BY-SA 4.0 bundled dictionary data, contribution guide,
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

[Unreleased]: https://github.com/OpenIPC/HanReader/commits/main
