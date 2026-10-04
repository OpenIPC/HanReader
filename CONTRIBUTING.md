# Contributing to HanReader

Thanks for your interest. This guide covers what you need installed, how the
code is organised, and the few rules that CI enforces.

By participating you agree to abide by our
[Code of Conduct](CODE_OF_CONDUCT.md).

---

## Do not add dictionary data to this repository

This is the single most likely well-meaning contribution that would create a
licensing problem, so it gets its own section.

- **Never commit BKRS / 大БКРС files.** They are not freely licensed and are not
  ours to redistribute. HanReader ships an *importer*, not the data.
- **Never commit a generated dictionary database.** A database built from
  CC-CEDICT is an Adapted Work under CC BY-SA 4.0, so redistributing it carries
  obligations the repository's MIT license does not cover.
- **Do not hand-edit the pinned CC-CEDICT snapshot.** Run
  `Scripts/update-cedict.sh`, which re-downloads, verifies, and regenerates
  `SOURCE.json`.
- Test fixtures are the one exception, and they are deliberately tiny: a
  ~200-card slice of BKRS and a ~300-line slice of CC-CEDICT, both regenerable
  by a committed script so their provenance is documented.

If you want to add support for a *new* dictionary format, that is very welcome —
see [Adding a dictionary format](#adding-a-dictionary-format) below.

---

## Prerequisites

| | Build | Run |
|---|---|---|
| macOS | macOS 15.6+, Xcode 26.6 | macOS 14.0+ |
| iOS | Xcode 26.6 + an iOS 26.x simulator runtime | iOS 17.0+ |

Note that the build host requirement and the deployment target are different
numbers; conflating them causes confusion. Xcode 26.6 is pinned in
`.xcode-version`.

**You will need to download an iOS simulator runtime separately.** Xcode ships
the iOS SDK but not the runtimes, and this catches everyone out:

```sh
xcodebuild -downloadPlatform iOS      # roughly 10 GB
```

Without it, `make run-ios` fails with an opaque "Unable to find a destination"
error. You can skip this if you only intend to work on macOS.

You do **not** need Homebrew, an Apple Developer account, or any other tool.
`make bootstrap` downloads XcodeGen 2.46.0, SwiftLint 0.65.1 and SwiftFormat
0.63.1 as pinned, SHA-256-verified prebuilt binaries into `.tools/`. The
checksums live in `Scripts/tools.lock`, and bootstrap verifies each archive
*before* extracting it — so a tampered download never reaches disk, let alone
runs. To bump a tool, change its version and checksum together.

`make doctor` reports your toolchain, how it compares to the version CI uses,
and whether an iOS simulator runtime is installed.

---

## Getting started

```sh
git clone https://github.com/OpenIPC/HanReader.git
cd HanReader
make run              # bootstrap + generate + build + launch (macOS)
```

Other entry points:

```sh
make test             # swift test -- the fast lane, no simulator needed
make test-all         # + xcodebuild test on macOS and the iOS Simulator
make run-ios          # build, boot a simulator, install, launch
make open             # generate the project and open it in Xcode
make lint             # SwiftFormat --lint + SwiftLint
make format           # apply SwiftFormat
```

If you would rather not use `make`, **`open Package.swift`** works with nothing
but Xcode installed: you get every library target and the whole test suite.
You only need `make` to produce a runnable `.app`.

### The Xcode project is generated and not committed

`HanReader.xcodeproj` is produced from `project.yml` by XcodeGen and is
gitignored. Run `make generate` after changing targets or adding source
directories, and **never commit the project file**. Most code lives in SwiftPM
targets, so you will rarely need to touch `project.yml` at all.

---

## Where code goes

```
HanReaderCore          Foundation only -- builds on Linux
  HanReaderTokenization    + NaturalLanguage
  HanReaderPersistence     + GRDB
    HanReaderDictionaryImport
      hanreader-dictgen      (CLI)
  HanReaderPlayback        + AVFoundation / MediaPlayer
  HanReaderPlatform        + AppKit / UIKit
  HanReaderUI              SwiftUI only
    Apps/macOS, Apps/iOS
```

| I want to change… | Target |
|---|---|
| A dictionary format parser, pinyin, line breaking, the token model | `HanReaderCore` |
| Word segmentation using Apple's tokenizer | `HanReaderTokenization` |
| Database schema, migrations, queries | `HanReaderPersistence` |
| Dictionary import, streaming, progress, resume | `HanReaderDictionaryImport` |
| Audio playback, text-to-speech | `HanReaderPlayback` |
| Something that genuinely differs between macOS and iOS | `HanReaderPlatform` |
| Any view, any view model | `HanReaderUI` |
| The reader's visual constants | `HanReaderUI/Design/` |

### Dependency rules — these fail CI, not review

- `HanReaderCore` imports **only Foundation**. A Linux CI job builds it in
  isolation, which is what actually enforces this: `NaturalLanguage` and
  `AVFoundation` are just as Apple-only as AppKit, so "no AppKit" would be too
  weak a rule.
- No `AppKit` / `UIKit` outside `HanReaderPlatform`.
- No `NaturalLanguage` outside `HanReaderTokenization` — go through
  `HanReaderCore.Tokenizing`.
- No `GRDB` or `SQLite3` outside `HanReaderPersistence`. Its public API must not
  expose a GRDB type; `InternalImportsByDefault` makes a leak a compiler error.
- No `#if os(` outside `HanReaderUI/Platform/` and the app targets.
- No `print(` — use the logger in `HanReaderCore`.
- No raw design values in views: no `.font(.system(size: 17))`, no inline
  `Color.accentColor.opacity(0.12)`, no bare `.easeInOut(…)`. Add a token to
  `Design/` instead. The prototype scattered numbers like `panelHeight = 88` and
  `fontSize * 0.48`; a convention nobody can violate beats a style guide nobody
  reads.

### Two rules that are easy to get wrong

- **Never `await` inside a SwiftUI `body`.** Awaits belong in `.task`,
  `.task(id:)`, or a `Button` action.
- **A `Layout` conformance takes plain `Equatable` values, never a model
  reference.** Reading an `@Observable` property inside `Layout.sizeThatFits`
  registers an observation dependency in a scope you do not control.

---

## Tests

We use [Swift Testing](https://developer.apple.com/documentation/testing)
(`import Testing`, `@Test`, `#expect`) — not XCTest. The one exception is a small
XCTest target for performance measurement, since `XCTMetric` has no Swift
Testing equivalent yet.

- New logic needs a test in the corresponding `*Tests` target.
- Persistence tests use `DatabaseQueue()` with no arguments, which is in-memory.
- **Do not assert on `NLTokenizer` output.** It is a closed model whose
  segmentation can change with an OS update, so such a test is flaky by
  construction. Assert on `MaxMatchSegmenter`, which is deterministic, and
  verify only coarse invariants for `NLTokenizer`.
- Reader layout is tested by snapshotting the *layout result* (`[LineRun]`) as
  text goldens against a deterministic text measurer, not by comparing pixels.
  CJK glyph metrics shift between OS releases, and a suite that cries wolf gets
  ignored. Regenerate goldens with `--record` and review the diff.
- Fuzz corpora and crashing-input fixtures for the parsers are especially
  welcome — see [`SECURITY.md`](SECURITY.md).

---

## Adding a dictionary format

1. Write the parser in `HanReaderCore/Format/`, conforming to
   `DictionaryFormat` and `DictionaryRecordParser`.
2. Add the ingestion path in `HanReaderDictionaryImport`.
3. Add a `hanreader-dictgen` subcommand.
4. Commit a **small** fixture plus an extraction script, and tests covering
   malformed input, not just the happy path.

Two rules the existing parsers learned the hard way, both worth copying:
handle backslash escapes *before* recognising markup, and on encountering an
unknown tag emit it as text with a diagnostic — **never silently delete
content.**

---

## Pull requests

- Branch from `main`. Keep PRs focused.
- Run `make format` and `make test-all` before pushing.
- Formatting is owned by SwiftFormat and linting by SwiftLint, and they are
  configured not to contradict each other. If you find a case where `make
  format` produces something `make lint` rejects, that is a bug in our config
  rather than something to work around — please report it.
- Update the `[Unreleased]` section of [`CHANGELOG.md`](CHANGELOG.md) for any
  user-visible change.
- Commit messages follow [Conventional Commits](https://www.conventionalcommits.org/)
  (`feat:`, `fix:`, `docs:`, `refactor:`, `test:`, `chore:`, `build:`, `ci:`).
- **Sign off your commits** with `git commit -s`, certifying the
  [Developer Certificate of Origin](https://developercertificate.org/). We use a
  DCO rather than a CLA: it gives the provenance assertion we need without the
  paperwork.
