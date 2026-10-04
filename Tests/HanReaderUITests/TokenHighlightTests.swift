// HanReader — MIT licensed. See LICENSE.

import Testing
@testable import HanReaderUI

@Suite("Token highlight")
struct TokenHighlightTests {
    @Test("An unrevealed token draws nothing")
    func plainDrawsNothing() {
        let highlight = TokenHighlight.resolve(.plain)
        #expect(highlight.fillOpacity == 0)
        #expect(highlight.borderWidth == 0)
        #expect(!highlight.underlined)
    }

    /// The prototype's most jarring interaction bug, as an assertion.
    ///
    /// It drew every revealed word identically, so tapping a second instance
    /// of an already-revealed word changed nothing on screen — which is why it
    /// read as the tap having been ignored. The selected token has to be
    /// visibly different from the merely revealed ones at every contrast
    /// setting, not just at the default one.
    @Test("Selection is visibly stronger than reveal", arguments: [false, true])
    func selectionOutweighsReveal(increasedContrast: Bool) {
        let revealed = TokenHighlight.resolve(.revealed, increasedContrast: increasedContrast)
        let selected = TokenHighlight.resolve(.selected, increasedContrast: increasedContrast)

        #expect(selected.fillOpacity > revealed.fillOpacity)
        #expect(selected.borderWidth > revealed.borderWidth)
    }

    @Test(
        "Increased contrast strengthens both fills",
        arguments: [TokenEmphasis.revealed, .selected],
    )
    func increasedContrastStrengthensFills(emphasis: TokenEmphasis) {
        let normal = TokenHighlight.resolve(emphasis, increasedContrast: false)
        let increased = TokenHighlight.resolve(emphasis, increasedContrast: true)
        #expect(increased.fillOpacity > normal.fillOpacity)
    }

    /// The fill shipped at 0.08, which composites to a 1.11:1 contrast ratio
    /// against white and 1.08:1 against the macOS dark background — too
    /// faint to read as a marker. The floor here stops it drifting back
    /// without anyone noticing, since nothing else in the suite would fail.
    @Test("A revealed word is actually visible")
    func revealedIsVisible() {
        #expect(TokenHighlight.resolve(.revealed).fillOpacity >= 0.12)
        #expect(TokenHighlight.resolve(.selected).fillOpacity >= 0.25)
    }

    /// Quiet, though. The reading printed above the word is the primary
    /// signal; a page with two hundred revealed words should not become a
    /// wall of colour.
    @Test("A revealed word stays quieter than the selected one")
    func revealedStaysQuiet() {
        let revealed = TokenHighlight.resolve(.revealed)
        #expect(revealed.fillOpacity <= 0.20)
        #expect(TokenHighlight.resolve(.selected).fillOpacity > revealed.fillOpacity * 1.5)
    }

    /// Reveal state must survive a reader who has asked the system not to
    /// rely on colour. An 8%-opacity accent fill was the prototype's only
    /// signal, and it is invisible to exactly that reader.
    @Test(
        "Reveal state has a non-colour channel when asked for",
        arguments: TokenEmphasis.allCases,
    )
    func differentiateWithoutColorAddsAShapeChannel(emphasis: TokenEmphasis) {
        let plainColours = TokenHighlight.resolve(emphasis, differentiateWithoutColor: false)
        let shaped = TokenHighlight.resolve(emphasis, differentiateWithoutColor: true)

        #expect(!plainColours.underlined)
        #expect(shaped.underlined == (emphasis != .plain))
    }

    @Test("Only the selected token is bordered", arguments: TokenEmphasis.allCases)
    func borderMarksSelectionAlone(emphasis: TokenEmphasis) {
        let highlight = TokenHighlight.resolve(emphasis)
        #expect((highlight.borderWidth > 0) == (emphasis == .selected))
    }
}
