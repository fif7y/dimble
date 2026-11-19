import Foundation
import Testing
@testable import PelmetCore

@Suite struct LiveActivityDefaultsTests {
    let shield = (identifier: "live-activity-pill-com.apple.accessibility.AXVisualSupportAgent",
                  name: "System & App Protection Override")
    let sports = (identifier: "live-activity-pill-com.apple.tv", name: "Sports")

    @Test func theProtectionPillIsTurnedOffTheFirstTimeItShows() {
        let off = LiveActivityDefaults.toTurnOff(seen: [sports, shield], seeded: [])
        #expect(off.map(\.name) == ["System & App Protection Override"])
    }

    @Test func onceSeededTheUsersSwitchHolds() {
        // Turned back on by the user: never turned off again.
        #expect(LiveActivityDefaults.toTurnOff(seen: [shield], seeded: [shield.identifier]).isEmpty)
    }

    @Test func itsLocalizedNameIsWhatGetsTurnedOff() {
        let french = (identifier: shield.identifier, name: "Contournement de la protection du système et des apps")
        #expect(LiveActivityDefaults.toTurnOff(seen: [french], seeded: []).map(\.name) == [french.name])
    }

    @Test func twoCopiesOnTwoDisplaysCountOnce() {
        #expect(LiveActivityDefaults.toTurnOff(seen: [shield, shield], seeded: []).count == 1)
    }

    @Test func otherPillsStayOn() {
        #expect(LiveActivityDefaults.toTurnOff(seen: [sports], seeded: []).isEmpty)
    }

    @Test func seededDefaultsStartEmptyAndRoundTrip() throws {
        #expect(SettingsStore().seededLiveActivityDefaults.isEmpty)
        let legacy = try JSONDecoder().decode(SettingsStore.self, from: Data("{}".utf8))
        #expect(legacy.seededLiveActivityDefaults.isEmpty)
        var settings = SettingsStore()
        settings.seededLiveActivityDefaults = [shield.identifier]
        let back = try JSONDecoder().decode(SettingsStore.self, from: JSONEncoder().encode(settings))
        #expect(back.seededLiveActivityDefaults == [shield.identifier])
    }
}
