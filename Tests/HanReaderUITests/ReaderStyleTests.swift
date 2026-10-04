// HanReader — MIT licensed. See LICENSE.

import Testing
@testable import HanReaderUI

@Suite("Reader style")
struct ReaderStyleTests {
    /// The size the prototype's spacing was tuned at. Every ratio is checked
    /// against the absolute value it has to reproduce here, so a change to a
    /// ratio has to be a deliberate change to the design rather than a typo.
    private let prototypeSize = 22.0

    @Test("Reproduces the prototype's spacing at the size it was tuned for")
    func matchesPrototypeAtTwentyTwoPoints() {
        let style = ReaderStyle(fontSize: prototypeSize)
        #expect(abs(style.lineGap - 16) < 0.2)
        #expect(abs(style.wordSpacing - 4) < 0.1)
        #expect(abs(style.rubyFontSize - 10.56) < 0.01)
    }

    @Test("Scales every measurement with the font size", arguments: [14.0, 22.0, 36.0, 48.0])
    func scalesProportionally(size: Double) {
        let style = ReaderStyle(fontSize: size)
        #expect(abs(style.lineGap / size - ReaderStyle.Ratio.lineGap) < 1e-12)
        #expect(abs(style.wordSpacing / size - ReaderStyle.Ratio.wordSpacing) < 1e-12)
        #expect(abs(style.rubyFontSize / size - ReaderStyle.Ratio.ruby) < 1e-12)
    }

    @Test("Clamps the chosen font size to the reader's range")
    func clampsFontSize() {
        #expect(ReaderStyle(fontSize: 2).fontSize == ReaderStyle.fontSizeRange.lowerBound)
        #expect(ReaderStyle(fontSize: 400).fontSize == ReaderStyle.fontSizeRange.upperBound)
    }

    @Test("Clamps Dynamic Type's contribution to the reading surface")
    func clampsTextScale() {
        // Unclamped, 48pt at accessibility5 is roughly a 120pt glyph: one word
        // per line, which is not a reading surface.
        let huge = ReaderStyle(fontSize: 48, textScale: 3)
        #expect(huge.fontSize == 48 * ReaderStyle.textScaleRange.upperBound)

        let tiny = ReaderStyle(fontSize: 22, textScale: 0.2)
        #expect(tiny.fontSize == 22 * ReaderStyle.textScaleRange.lowerBound)
    }

    @Test("A compact floor raises a small size without lowering a large one")
    func compactFloor() {
        let small = ReaderStyle(
            fontSize: 14,
            minimumFontSize: ReaderStyle.compactFontSizeFloor,
        )
        #expect(small.fontSize == ReaderStyle.compactFontSizeFloor)

        let large = ReaderStyle(
            fontSize: 48,
            minimumFontSize: ReaderStyle.compactFontSizeFloor,
        )
        #expect(large.fontSize == 48)
    }

    /// Pins the reason `withSpacing` does not re-enter the clamping
    /// initializer. 48pt scaled by Dynamic Type's maximum resolves to 69.6pt,
    /// which is outside `fontSizeRange`; re-clamping it would shrink the text
    /// by a third as a side effect of toggling word spacing.
    @Test("Toggling spacing never changes the resolved font size")
    func spacingToggleKeepsSize() {
        let scaled = ReaderStyle(
            fontSize: 48,
            spacing: .separated,
            textScale: ReaderStyle.textScaleRange.upperBound,
        )
        #expect(scaled.fontSize > ReaderStyle.fontSizeRange.upperBound)

        let toggled = scaled.withSpacing(.continuous)
        #expect(toggled.fontSize == scaled.fontSize)
        #expect(toggled.spacing == .continuous)
    }

    /// Fidelity invariant 1, at the level of the style: toggling spacing is a
    /// horizontal change only. If the ruby reservation or the line gap moved
    /// with it, the whole page would shift vertically.
    @Test("Toggling spacing changes nothing vertical")
    func spacingToggleIsHorizontalOnly() {
        let separated = ReaderStyle(fontSize: 22, spacing: .separated)
        let continuous = separated.withSpacing(.continuous)

        #expect(continuous.rubyReservation == separated.rubyReservation)
        #expect(continuous.lineGap == separated.lineGap)
        #expect(continuous.paragraphGap == separated.paragraphGap)
        #expect(continuous.blankLineHeight == separated.blankLineHeight)
        #expect(continuous.wordSpacing == 0)
        #expect(separated.wordSpacing > 0)
    }

    @Test("Only separated spacing reserves width for a reading")
    func reservesRubyWidthOnlyWhenSeparated() {
        #expect(ReaderStyle(fontSize: 22, spacing: .separated).reservesRubyWidth)
        #expect(!ReaderStyle(fontSize: 22, spacing: .continuous).reservesRubyWidth)
    }

    @Test("The ruby band is tall enough for the glyphs it holds")
    func rubyReservationExceedsRubyFontSize() {
        // Pinyin carries diacritics above and descenders below, so a
        // reservation equal to the font size would clip ǖ and g.
        for size in [14.0, 22.0, 48.0] {
            let style = ReaderStyle(fontSize: size)
            #expect(style.rubyReservation > style.rubyFontSize)
        }
    }

    @Test("A line is taller than the glyphs on it by exactly the ruby band")
    func lineHeightIncludesTheReservation() {
        let style = ReaderStyle(fontSize: 22)
        let line = ReaderFlow.lineHeight(style)
        #expect(line > style.fontSize)
        let glyphs = line - style.rubyReservation
        #expect(abs(glyphs - style.fontSize * ReaderStyle.Ratio.hanLineHeight) < 1e-9)
    }
}
