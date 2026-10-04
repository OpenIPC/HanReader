# Security policy

## Reporting a vulnerability

Please report security issues through
[GitHub's private vulnerability reporting](https://github.com/OpenIPC/HanReader/security/advisories/new)
rather than opening a public issue. The report stays private between you and the
maintainers until a fix is released.

Please include a description of the issue, the steps or input needed to trigger
it, and the affected version. If a malformed file reproduces it, a minimal
sample is far more useful than a large one. We will acknowledge your report and
keep you informed as we work on a fix.

## Supported versions

Only the latest release receives security fixes.

## Threat model

HanReader is an offline reader. Being specific about where its risk actually
lies is more useful than a generic policy, so:

**The dictionary and text parsers are the highest-risk code in this project.**
HanReader parses large, untrusted, third-party binary and text files that users
obtain elsewhere:

- ABBYY DSL dictionary files (UTF-16 or UTF-8, routinely 350 MB and larger)
- CC-CEDICT `.u8` text files
- Imported text documents in several legacy Chinese encodings (GB18030, GBK,
  Big5) as well as UTF-8 and UTF-16
- Audio files, decoded by the system's AVFoundation

### In scope

- A crash, hang, unbounded memory growth, or unbounded disk growth triggered by
  a malformed or hostile dictionary, text, or audio file.
- Any input that escapes string-literal handling and reaches SQL as code.
- Path traversal or writes outside the application's container via a crafted
  filename or a dictionary `#INCLUDE` directive.
- Incorrect handling of security-scoped resources that would grant the app
  access it should not retain.

Parser robustness genuinely matters here: the predecessor prototype's DSL markup
stripper mutated a string while holding indices derived from it, which is
precisely this class of defect. **Fuzz corpora and crashing-input fixtures are
very welcome contributions** — see [`CONTRIBUTING.md`](CONTRIBUTING.md).

### Out of scope

- HanReader has no account system, no telemetry, and no server component.
- Its only outbound network requests are an optional check for a newer release
  and the optional download of a CC-CEDICT update. It never uploads user content.
- Local-only concerns that require an attacker to already have code execution or
  filesystem access as the user, such as reading the user's own library database.
- The *content* of a third-party dictionary. A wrong or offensive definition is
  an upstream data issue, not a HanReader vulnerability; please report those to
  the dictionary's maintainers. See
  [`.github/ISSUE_TEMPLATE/dictionary_issue.yml`](.github/ISSUE_TEMPLATE/dictionary_issue.yml).

### A note on bundled data

HanReader ships a pinned snapshot of CC-CEDICT and records its SHA-256 in
`Dictionaries/cc-cedict/SOURCE.json`, verified during the build. If you believe
that pinned data has been tampered with, treat it as a security issue and report
it privately.
