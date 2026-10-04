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

[Unreleased]: https://github.com/OpenIPC/HanReader/commits/main
