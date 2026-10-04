# Fidelity

HanReader is a rebuild of a working macOS prototype, and "faithful to the
prototype" is one of its stated goals. Taken literally that goal is
incoherent: the prototype's identity includes an 1100×700 minimum window, an
88-point detail panel and a 110-point headword column, none of which exist on
a 390×844 phone. A rebuild that shipped on two platforms could not be faithful
in pixels even in principle.

So fidelity here is defined **behaviourally**. What follows is the contract.
Each invariant says what a reader can rely on, independently of how large the
window is or which device it is running on, and each one names where it is
actually enforced — because an invariant nothing checks is a wish.

## The invariants

### 1. Revealing a word never reflows or vertically shifts the body text

Tapping a word to see its reading must not move any other word. This is the
one that makes the app usable: a reading surface that reshuffles itself every
time you look something up is exhausting to read.

It holds **by construction** rather than by care. `ReaderStyle.rubyReservation`
is added to every token's height whether or not a reading is shown, and the
reading itself is always present in the view hierarchy with its visibility
carried by opacity — so the box being measured is always the box that will be
drawn. See `RubyStack`.

*Enforced by:* `ReaderLayoutRenderTests`, which renders the same token and the
same paragraph with and without readings and compares their sizes, across four
reading sizes, both spacing modes and a sweep of column widths.

> An earlier version of that test checked only one paragraph at one width, and
> it passed when the prototype's bug was deliberately reintroduced. Width is
> pinned by the column, so only the line *count* can move, and it happened not
> to. The tests are at the token level first for that reason.

### 2. A reading is rendered above its word, not inline

Pinyin is an annotation, not a parenthetical. It sits on its own band above the
glyphs, in a smaller face, and never displaces them.

*Enforced by:* `RubyStack`, which is the only thing that positions a reading,
and by invariant 1's tests — an inline reading would change the token's width.

### 3. The word-detail surface is always reachable, and never covers the word

A tapped word stays visible while its definition is on screen. The detail
surface is a fixed-height panel that the reading surface insets itself for,
not an overlay.

The panel's height is fixed deliberately. One that grew to fit its content
would push the body text down every time a word with a longer definition was
tapped — which is invariant 1 lost through the back door.

### 4. Tapping a word speaks it

Unless VoiceOver is running, in which case it does not: VoiceOver announces the
token itself on focus, and speaking as well says the word twice, over itself,
in two different voices.

### 5. Both spacing modes exist and are toggleable

Words separated by a visible gap, as a learner's edition prints them, and
continuous text as Chinese is actually written. Toggling between them is a
horizontal change only — nothing moves up or down.

*Enforced by:* `ReaderStyleTests.spacingToggleIsHorizontalOnly`.

### 6. Per-text audio plays in a persistent transport with a scrubber and speed control

Arrives in M7.

### 7. Reading position and reveal state survive relaunch

Position is stored as a UTF-16 offset into the text, never as a pixel offset.
A pixel offset is meaningless after a font-size change, a window resize, or
moving between a Mac and a phone — which is why the prototype's `scroll_offset`
column was written as zero and never read.

## Explicitly not invariant

- **Surface geometry.** Window sizes, panel placement, sidebar width.
- **Chrome placement.** A toolbar on macOS may be an overflow menu on iPhone.
- **Input modality.** Hover affordances exist where there is a pointer.
- **Where the expanded detail surface appears.** An inspector on a regular
  width, a sheet on a compact one.

## Known departures from the prototype

These are deliberate, and each is a fix rather than a regression.

| Prototype | HanReader | Why |
|---|---|---|
| Tapping a word reveals it everywhere, and tapping any instance hides it everywhere | Selection and reveal are separate; tapping a second instance selects it and leaves the reveal in place | `revealedWords: Set<String>` could not express "this one". Tapping a different instance appeared to do nothing. |
| `SegmentationMode { split, unsplit }` | `WordSpacing { separated, continuous }` | The setting never touched segmentation. It controls the gap drawn between tokens. |
| Spacing tuned as absolute points at one font size | Every measurement is a ratio of the font size | `lineSpacing: 16` was tuned at 22pt. At 48pt the text is cramped; at 14pt it is airy. |
| In-text drag selection | Paragraph and sentence copy commands, plus share | Separate `Text` views cannot be selected across. This is the one documented trigger for moving the renderer to TextKit 2 — see [ARCHITECTURE.md](ARCHITECTURE.md). |

## Tap targets are the size of the words

Apple's 44-point minimum cannot be met by a word in running text, and this is
worth stating plainly rather than leaving as an implied promise. A single Han
character at 14 points is 14 points wide; the word beside it starts a few
points later. Padding the target to 44 points would overlap the neighbouring
word's target, and an ambiguous target that selects the wrong word is worse
than a small one that selects the right one.

What the reader does instead:

- The target is the whole token box, which includes the ruby band above the
  glyphs — about 41 points tall at the default reading size, not 26.
- On a compact width the resolved reading size is floored at 18 points, which
  is the one lever that genuinely enlarges the target.

An earlier draft of the design system declared a `minimumHitTarget` constant
that nothing honoured. It has been removed: a named guarantee that no code
delivers is worse than an acknowledged limitation.

## Dynamic Type is asymmetric, on purpose

The chrome honours Dynamic Type uncapped, and every fixed dimension in it is a
`@ScaledMetric` — the prototype's 88-point panel clips its own content at AX3
and above, which is a real bug.

The reading surface does not. It uses the size the reader chose, nudged by
Dynamic Type's multiplier clamped to 0.9–1.45. Unclamped, 48pt at
`accessibility5` is roughly a 120-point glyph: one word per line, which is not
a reading surface. On a compact width the resolved size is floored at 18pt so
that tap targets stay at least 44 points.
