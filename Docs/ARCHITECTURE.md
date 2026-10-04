# Architecture

> This document grows as the rebuild lands. It currently records the decisions
> that shape the package layout; the per-module detail arrives with the modules
> themselves (milestone M1 onward — see the README roadmap).

## Shape

One SwiftPM package at the repository root defines the real target graph. Two
thin Xcode application targets, generated from `project.yml`, exist only to wrap
it in a bundle that can be launched.

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

## Why the core is Foundation-only

`HanReaderCore` holds the domain model, both dictionary parsers, the pinyin
engine, the token model, and the line-breaking algorithm. Keeping Apple
frameworks out of it buys three things:

1. **Testability.** `swift test` runs the bulk of the suite in seconds with no
   simulator and no Xcode project.
2. **Determinism.** `NLTokenizer` is a closed model whose segmentation can
   change with an OS update. A test asserting on its output is flaky by
   construction, so it sits behind `HanReaderCore.Tokenizing` alongside a
   deterministic maximum-matching segmenter that tests *can* assert on.
3. **A real boundary.** "No AppKit" is too weak a rule, because
   `NaturalLanguage` and `AVFoundation` are just as Apple-only. The meaningful
   constraint is *the core builds on Linux*.

## Enforcement is mechanical, not conventional

Architecture rules that live only in a style guide decay. Each of ours fails a
build instead:

| Rule | Enforced by |
|---|---|
| The core uses no Apple frameworks | A Linux CI job that builds `HanReaderCore` alone |
| Persistence does not leak GRDB types | `InternalImportsByDefault` — a leak is a compile error |
| No AppKit/UIKit outside `HanReaderPlatform` | SwiftLint custom rule, severity error |
| No `NaturalLanguage` outside `HanReaderTokenization` | SwiftLint custom rule, severity error |
| No `#if os(` outside `Platform/` | SwiftLint custom rule, severity error |
| No raw design values in views | SwiftLint custom rules on font sizes, padding, inline colour opacity, bare animations |

## Deployment targets: macOS 14 / iOS 17

These are Apple's own recommended values (from the SDK's `SDKSettings.plist`),
and they are also precisely the floors the rebuild needs: `@Observable`,
`ContentUnavailableView`, and `.scrollPosition(id:)` all require them.

The build toolchain is pinned separately, in `.xcode-version`. Build host and
deployment target are different numbers and conflating them causes confusion:
building needs Xcode 26.6 on macOS 15.6+, while the resulting app runs on
macOS 14.

## Decisions recorded elsewhere

- **Dictionary data licensing** — [`../Dictionaries/cc-cedict/README.md`](../Dictionaries/cc-cedict/README.md)
- **Threat model and parser risk** — [`../SECURITY.md`](../SECURITY.md)
- **Module boundaries as a contributor rule** — [`../CONTRIBUTING.md`](../CONTRIBUTING.md)

Architecture decision records land in `Docs/adr/` as the corresponding code
does.
