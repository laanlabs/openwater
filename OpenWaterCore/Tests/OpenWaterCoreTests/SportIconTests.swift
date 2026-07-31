import Foundation
import Testing
@testable import OpenWaterCore

#if canImport(AppKit)
import AppKit
#endif

@Suite("Sport icons")
struct SportIconTests {

    /// Every sport's symbol must actually exist.
    ///
    /// An invalid SF Symbol name does not throw or warn — it renders as empty
    /// space, so a typo shows up as a row in the picker with no icon and nothing
    /// anywhere says why. `kite` shipped like that. This catches it at build
    /// time instead of in a screenshot.
    @Test("Every sport symbol resolves", arguments: Sport.allCases)
    func symbolExists(sport: Sport) {
        #if canImport(AppKit)
        let image = NSImage(systemSymbolName: sport.symbolName, accessibilityDescription: nil)
        #expect(image != nil, "\(sport.rawValue) uses \"\(sport.symbolName)\", which is not an SF Symbol")
        #endif
    }

    @Test("Sports that appear together are visually distinguishable")
    func windSportsHaveDistinctIcons() {
        // Five wind disciplines all showing the same `wind` glyph made the
        // picker unreadable — every row looked identical.
        let windSports: [Sport] = [.wingfoil, .parawing, .windsurf, .windfoil, .kitesurf, .kitefoil, .sail]
        let symbols = Set(windSports.map(\.symbolName))
        #expect(symbols.count == windSports.count,
                "wind sports share icons: \(windSports.map { "\($0.rawValue)=\($0.symbolName)" })")
    }

    @Test("Every sport offered for recording is a known sport")
    func recordableCoversAllSports() {
        #expect(Set(Sport.recordable).count == Sport.recordable.count, "duplicate in recordable list")
        #expect(Set(Sport.recordable) == Set(Sport.allCases), "recordable list is out of step with Sport")
    }
}
