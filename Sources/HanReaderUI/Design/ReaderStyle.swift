// HanReader — MIT licensed. See LICENSE.

import Foundation

/// How words are spaced on the reading surface.
///
/// Renamed from the prototype's `SegmentationMode { split, unsplit }`, which
/// was actively misleading: it never touched segmentation, only the gap drawn
/// between tokens (`ReaderView.swift:103`). A reader toggling something called
/// "segmentation mode" reasonably expects the words to be grouped differently,
/// and a contributor reading the call site reasonably expects it to reach the
/// tokenizer. Neither was true.
nonisolated enum WordSpacing: String, CaseIterable, Sendable, Hashable, Codable {
    /// A visible gap between words, the way a learner's edition prints them.
    case separated
    /// Continuous text, the way Chinese is actually written.
    case continuous
}

/// Every measurement the reading surface needs, resolved once.
///
/// Three properties are deliberate and load-bearing:
///
/// - **A plain value.** `Layout` conformances take this and nothing else.
///   Reading an `@Observable` property inside `Layout.sizeThatFits` registers
///   an observation dependency in a scope nobody controls, so the only safe
///   shape for a layout's input is an `Equatable` value computed above it.
/// - **Ratios, not absolutes.** The prototype's `lineSpacing: 16` and
///   `wordSpacing: 4` were tuned at `fontSize = 22`. At 48pt the text is
///   cramped and at 14pt it is airy, because a gap that does not scale with
///   the glyphs is only correct at one size. Every derived measurement here is
///   a multiple of `fontSize`, with the prototype's numbers preserved as the
///   ratios they implied at 22pt.
/// - **Resolved once.** The prototype recomputed `max(10, fontSize * 0.48)`
///   inside every `WordTokenView.body`, thousands of times per layout pass.
nonisolated struct ReaderStyle: Hashable, Sendable {
    // MARK: - Ratios

    /// The em ratios every measurement derives from.
    ///
    /// The three taken from the prototype are recorded with the absolute value
    /// they were tuned at, so the provenance survives: these are not invented
    /// numbers, they are the prototype's own spacing expressed in a form that
    /// survives a font-size change.
    enum Ratio {
        /// Gap between lines. `16 / 22` in the prototype.
        static let lineGap = 0.72
        /// Gap between words in `.separated` mode. `4 / 22` in the prototype.
        static let wordSpacing = 0.18
        /// Ruby size relative to the base text. The prototype's `* 0.48`.
        static let ruby = 0.48
        /// Gap between the ruby and the glyphs below it.
        static let rubyGap = 0.1
        /// Ruby line height, as a multiple of the ruby font size. Pinyin is
        /// Latin with diacritics, so it needs ascender room above `ǖ` and
        /// descender room below `g`.
        static let rubyLineHeight = 1.25
        /// Space between paragraphs, over and above the line gap.
        static let paragraphGap = 0.6
        /// Height of a deliberate blank line in the source.
        static let blankLine = 0.9
        /// Nominal height of a line of Han text, for the places that need a
        /// line's worth of space with no text to measure.
        static let hanLineHeight = 1.18
    }

    // MARK: - Bounds

    /// The reader's own font-size range, independent of Dynamic Type.
    static let fontSizeRange = 14.0 ... 48.0

    /// Dynamic Type's contribution to the reading surface, clamped.
    ///
    /// The naive fix for "Dynamic Type should scale everything" is worse than
    /// the bug: 48pt at `accessibility5` is roughly a 120pt glyph, which is
    /// one word per line and unreadable as prose. The reader therefore honours
    /// Dynamic Type as a *nudge* on a size the reader has already chosen,
    /// while the surrounding chrome honours it uncapped. The asymmetry is
    /// intentional and documented in Docs/fidelity.md.
    static let textScaleRange = 0.9 ... 1.45

    /// The floor on a compact width, where a smaller glyph would shrink tap
    /// targets below the 44pt minimum.
    static let compactFontSizeFloor = 18.0

    // MARK: - Resolved values

    let spacing: WordSpacing
    /// The resolved base font size, in points.
    let fontSize: Double
    let rubyFontSize: Double
    /// Vertical space held for the ruby **unconditionally**, whether or not a
    /// reading is currently shown.
    ///
    /// This is what makes "revealing a word never reflows the body text" true
    /// by construction rather than by remembering to pad. The prototype got
    /// the same effect by rendering `Text(" ").opacity(0)` above every token
    /// forever — one extra view per token, and it reserved the width of a
    /// *space* rather than of the pinyin, so revealing a wide reading over a
    /// one-character word still moved the text.
    let rubyReservation: Double
    let wordSpacing: Double
    let lineGap: Double
    let paragraphGap: Double
    let blankLineHeight: Double

    /// Whether a token's width grows to fit its reading.
    ///
    /// Only in `.separated` mode. Reserving the width in `.continuous` mode
    /// would insert gaps between characters that are meant to run together,
    /// which destroys the entire point of that mode — so there, a revealed
    /// reading is allowed to overhang its neighbours instead.
    var reservesRubyWidth: Bool {
        spacing == .separated
    }

    // MARK: - Resolution

    /// Resolves a style from the reader's own settings.
    ///
    /// - Parameters:
    ///   - fontSize: the reader's chosen size, clamped to `fontSizeRange`.
    ///   - spacing: whether words are separated by a gap.
    ///   - textScale: Dynamic Type's multiplier, clamped to `textScaleRange`.
    ///   - minimumFontSize: a floor applied after scaling. Compact layouts
    ///     pass `compactFontSizeFloor` to keep tap targets large enough.
    init(
        fontSize: Double,
        spacing: WordSpacing = .separated,
        textScale: Double = 1,
        minimumFontSize: Double = Self.fontSizeRange.lowerBound,
    ) {
        let chosen = fontSize.clamped(to: Self.fontSizeRange)
        let scaled = chosen * textScale.clamped(to: Self.textScaleRange)
        // The floor is applied last and deliberately allowed to exceed
        // `fontSizeRange.upperBound` only downwards: a compact floor of 18
        // raises a 14pt choice, never lowers a 48pt one.
        let resolved = max(scaled, min(minimumFontSize, Self.fontSizeRange.upperBound))

        self.init(resolvedFontSize: resolved, spacing: spacing)
    }

    /// Derives every measurement from an already-resolved font size.
    ///
    /// Separate from the public initializer because that one clamps, and
    /// clamping is not idempotent: a 48pt choice scaled by Dynamic Type's
    /// 1.45 resolves to 69.6pt, which is outside `fontSizeRange`. Re-entering
    /// the public initializer with that value — as a `withSpacing` written the
    /// obvious way would — would quietly clamp it back to 48 and shrink the
    /// text as a side effect of toggling word spacing.
    private init(resolvedFontSize: Double, spacing: WordSpacing) {
        self.spacing = spacing
        fontSize = resolvedFontSize
        rubyFontSize = resolvedFontSize * Ratio.ruby
        // Computed from the ruby font size rather than measured, so that every
        // line in the document reserves exactly the same amount. Measuring
        // would make the reservation vary with whichever reading happened to
        // be longest on a line, and lines would then differ in height for a
        // reason the reader cannot see.
        rubyReservation = resolvedFontSize * Ratio.ruby * Ratio.rubyLineHeight
            + resolvedFontSize * Ratio.rubyGap
        wordSpacing = spacing == .separated ? resolvedFontSize * Ratio.wordSpacing : 0
        lineGap = resolvedFontSize * Ratio.lineGap
        paragraphGap = resolvedFontSize * Ratio.paragraphGap
        blankLineHeight = resolvedFontSize * Ratio.blankLine
    }

    /// The same style with a different spacing mode.
    ///
    /// Everything vertical is unchanged, which is the point: toggling spacing
    /// must not move the text up or down.
    func withSpacing(_ spacing: WordSpacing) -> Self {
        Self(resolvedFontSize: fontSize, spacing: spacing)
    }
}

extension Comparable {
    /// Clamps to a closed range.
    ///
    /// `nonisolated` because this module compiles with
    /// `defaultIsolation(MainActor.self)`, which would otherwise make even
    /// this `@MainActor` and so unreachable from a `Layout` conformance —
    /// whose methods SwiftUI calls without any isolation.
    nonisolated func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
