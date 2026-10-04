// HanReader — MIT licensed. See LICENSE.

import SwiftUI

/// Colour roles for the reading surface.
///
/// Every colour the reader draws is named here and nowhere else. SwiftLint's
/// `no_inline_color_opacity` rule makes that a build error rather than a
/// convention, which is what makes the backing swappable: these resolve from
/// semantic system colours today, and M9 moves them to an asset catalog with
/// light, dark and High Contrast variants. That is a one-file change precisely
/// because no view spells a colour out for itself.
nonisolated enum ReaderColor {
    /// The accent used for selection and reveal highlights.
    static let highlight = Color.accentColor
    /// Base glyph colour.
    static let text = Color.primary
    /// Ruby pinyin that came from the dictionary for this exact word.
    static let ruby = Color.secondary
    /// Ruby pinyin composed character by character, which is an approximation
    /// and will be wrong for heteronyms. Rendered more faintly so the reader
    /// can tell the difference without being told.
    static let composedRuby = Color.secondary.opacity(0.65)
    /// Punctuation and whitespace, which are never looked up.
    static let inertText = Color.primary.opacity(0.75)

    /// The fill behind a highlighted token.
    ///
    /// Takes the resolved `TokenHighlight` rather than an opacity, so that the
    /// accessibility rules stay in one testable place and no view applies an
    /// opacity of its own. SwiftLint's `no_inline_color_opacity` enforces that
    /// by rejecting `…Color.<role>.opacity(` anywhere outside this directory.
    static func highlightFill(_ highlight: TokenHighlight) -> Color {
        self.highlight.opacity(highlight.fillOpacity)
    }
}

/// Fonts for the reading surface.
///
/// No bundled font. The system font resolves Han glyphs through PingFang SC on
/// both platforms, which is the face a Chinese reader expects and which gets
/// OS-level metric fixes for free.
///
/// Three things this must never do, all of which the system will happily do if
/// asked, and all of which are wrong for Hanzi:
///
/// - `.italic()` — there is no italic Hanzi. The system synthesises one by
///   slanting the glyphs, which looks like a rendering fault.
/// - synthetic bold below `.semibold` — PingFang has real weights; asking for
///   something between them produces smeared strokes.
/// - `.monospaced()` — substitutes a Latin monospace face and loses the Han
///   glyphs entirely for any text that mixes the two.
nonisolated enum ReaderFont {
    /// The base reading face.
    static func base(_ style: ReaderStyle) -> Font {
        .system(size: style.fontSize)
    }

    /// The ruby annotation face.
    ///
    /// Pinyin is Latin, so it may use the full range of system styling — but
    /// it is kept regular here, because a bold annotation competes with the
    /// glyphs it annotates.
    static func ruby(_ style: ReaderStyle) -> Font {
        .system(size: style.rubyFontSize)
    }
}

/// Fixed dimensions in the chrome around the reader.
///
/// These are the prototype's own numbers, kept as the *base* values they were:
/// each is scaled by Dynamic Type at the point of use via `@ScaledMetric`.
/// Left unscaled, the 88pt detail panel clips its own content at AX3 and
/// above, which is a real bug in the prototype and not a cosmetic one.
nonisolated enum ReaderMetrics {
    /// Height of the always-visible word-detail panel.
    ///
    /// Fixed on purpose. A panel that grows to fit its content pushes the body
    /// text down every time a word with a longer definition is tapped, which
    /// is the single most disruptive thing a reading surface can do. The
    /// prototype got this right and it is preserved exactly.
    static let detailPanelHeight = 88.0
    /// Width of the headword column inside the detail panel.
    static let detailHeadwordWidth = 110.0
    /// Width of the library sidebar on a regular-width layout.
    static let sidebarWidth = 260.0
    /// The reading column stops widening here. Beyond roughly this width a
    /// line holds too many characters to track back to the start of the next.
    static let readingColumnMaxWidth = 720.0
    /// Padding around the reading column.
    static let readingColumnPadding = 24.0
    /// Minimum hit target. Apple's guideline is 44pt, and a tapped word is
    /// this app's primary interaction.
    static let minimumHitTarget = 44.0
    /// Corner radius on a token's highlight.
    static let tokenCornerRadius = 4.0
}

/// Animations, with reduce-motion handled once.
///
/// SwiftLint's `no_raw_animation` rule confines animation curves to this
/// directory, so there is no path by which a view animates without passing
/// through a function that takes `reduceMotion`. The prototype animated
/// unconditionally; "honour Reduce Motion" was one forgotten modifier away
/// from being false in any new view.
nonisolated enum ReaderAnimation {
    /// Revealing or hiding a reading.
    ///
    /// Returns `nil` rather than a zero-duration animation under reduce
    /// motion: a `nil` animation makes the change instant, while a
    /// zero-duration one still schedules a transaction.
    static func reveal(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeOut(duration: 0.18)
    }

    /// Moving the detail panel's contents as the selection changes.
    static func detail(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeInOut(duration: 0.22)
    }

    /// Presenting or dismissing the expanded detail surface.
    static func surface(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .spring(duration: 0.3, bounce: 0.1)
    }
}
