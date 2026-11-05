import Foundation
import Testing
@testable import PelmetCore

struct ShowRuleSettingsTests {
    // On battery power alone, or only once the charge is under 20%.
    @Test func batteryConditionsReadPowerAndCharge() {
        #expect(BatteryShowCondition.onBattery.isMet(onBattery: true, percent: 90))
        #expect(BatteryShowCondition.onBattery.isMet(onBattery: true, percent: nil))
        #expect(!BatteryShowCondition.onBattery.isMet(onBattery: false, percent: 5))

        #expect(BatteryShowCondition.below20.isMet(onBattery: true, percent: 19))
        #expect(!BatteryShowCondition.below20.isMet(onBattery: true, percent: 20))
        #expect(!BatteryShowCondition.below20.isMet(onBattery: true, percent: 80))
        // Plugged in, a low charge is already being fixed.
        #expect(!BatteryShowCondition.below20.isMet(onBattery: false, percent: 4))
        // A charge that can't be read says nothing.
        #expect(!BatteryShowCondition.below20.isMet(onBattery: true, percent: nil))
    }

    // A blob from before the rules existed decodes with every rule off.
    @Test func settingsDefaultOffAndRoundTrip() throws {
        let legacy = try JSONDecoder().decode(SettingsStore.self, from: Data("{}".utf8))
        #expect(legacy.showRules == ShowRuleSettings())
        #expect(legacy.showRules.battery == nil && !legacy.showRules.wifiOn)

        var settings = SettingsStore()
        settings.showRules.batteryOn = true
        settings.showRules.batteryCondition = .below20
        settings.showRules.wifiOn = true
        let back = try JSONDecoder().decode(SettingsStore.self, from: JSONEncoder().encode(settings))
        #expect(back.showRules == settings.showRules)
        #expect(back.showRules.battery == .below20)
    }

    // A blob from before the hotspot choice stays on "When it drops". The
    // choice is kept while the rule is off, and watched only while it is on.
    @Test func hotspotChoiceDefaultsOffAndIsKept() throws {
        let legacy = try JSONDecoder().decode(ShowRuleSettings.self, from: Data(#"{"wifiOn":true}"#.utf8))
        #expect(legacy.wifiOn && !legacy.wifiHotspot && !legacy.wifiWatchesHotspot)

        var rules = ShowRuleSettings()
        rules.wifiHotspot = true
        #expect(!rules.wifiWatchesHotspot)
        rules.wifiOn = true
        #expect(rules.wifiWatchesHotspot)
        let back = try JSONDecoder().decode(ShowRuleSettings.self, from: JSONEncoder().encode(rules))
        #expect(back == rules)
    }

    // One unreadable field resets that field alone, not the whole store.
    @Test func badFieldsFallBackOneByOne() throws {
        let blob = #"{"showRules":{"batteryOn":true,"batteryCondition":"nonsense","wifiOn":true},"autoRehide":false}"#
        let store = try JSONDecoder().decode(SettingsStore.self, from: Data(blob.utf8))
        #expect(store.showRules.batteryOn)
        #expect(store.showRules.batteryCondition == .onBattery)
        #expect(store.showRules.wifiOn)
        #expect(!store.autoRehide)
        let partial = try JSONDecoder().decode(ShowRuleSettings.self, from: Data(#"{"wifiOn":true}"#.utf8))
        #expect(partial.wifiOn && !partial.batteryOn)
    }

    // The row's "While a Focus is on" takes the idle moon off the bar and
    // still brings it out while on; the card's rule is kept apart, and a
    // blob from before it decodes as "Always shows". Only Focus and Time
    // Machine read it.
    @Test func onlyWhileActiveRidesBesideTheCardRule() throws {
        var focus = ExtraItemSpec(kind: .focus)
        #expect(!focus.isOnlyWhileActive && !focus.comesOutWhileActive)
        focus.onlyWhileActive = true
        #expect(focus.isOnlyWhileActive && focus.comesOutWhileActive)
        #expect(focus.resolvedShowRule == .always)

        var card = ExtraItemSpec(kind: .timeMachine, showRule: .whenActive)
        #expect(!card.isOnlyWhileActive && card.comesOutWhileActive)
        card.onlyWhileActive = true
        let back = try JSONDecoder().decode(ExtraItemSpec.self, from: JSONEncoder().encode(card))
        #expect(back == card && back.isOnlyWhileActive && back.resolvedShowRule == .whenActive)

        let legacy = #"{"id":"6F1B5C1E-0000-4000-8000-000000000001","kind":"focus"}"#
        #expect(try JSONDecoder().decode(ExtraItemSpec.self, from: Data(legacy.utf8)).onlyWhileActive == nil)

        let timer = ExtraItemSpec(kind: .timer, onlyWhileActive: true)
        #expect(!timer.isOnlyWhileActive && !timer.comesOutWhileActive)
    }

    // An upgrade keeps 0.3.1's Focus: out on the bar while a Focus is on,
    // from Hidden or Always Hidden. Visible and other kinds are left alone.
    @Test func focusMigrationKeepsItOutWhileActive() {
        var settings = SettingsStore()
        let focus = ExtraItemSpec(kind: .focus)
        let timeMachine = ExtraItemSpec(kind: .timeMachine)
        settings.extraItems = [focus, timeMachine]
        let key = ItemID.status(bundle: PelmetBundle.mainID, title: focus.itemTitle)
        let tmKey = ItemID.status(bundle: PelmetBundle.mainID, title: timeMachine.itemTitle)

        // Visible: on the bar either way, nothing to change.
        #expect(settings.keepFocusOutWhileActive().isEmpty)
        #expect(settings.extraItems[0].showRule == nil)

        settings.sectionModel.enroll(key, in: .alwaysHidden)
        settings.sectionModel.enroll(tmKey, in: .hidden)
        #expect(settings.keepFocusOutWhileActive() == [.alwaysHidden])
        #expect(settings.extraItems[0].resolvedShowRule == .whenActive)
        #expect(settings.extraItems[1].showRule == nil)
        // Already out while active: a second run has nothing to do.
        #expect(settings.keepFocusOutWhileActive().isEmpty)

        // A rule the old migration dropped to "always" comes back.
        settings.extraItems[0].showRule = .always
        settings.sectionModel.enroll(key, in: .hidden)
        #expect(settings.keepFocusOutWhileActive() == [.hidden])
        #expect(settings.extraItems[0].showRule == .whenActive)
    }

    // Switching the rule off keeps the condition for the next time.
    @Test func conditionSurvivesSwitchingOff() {
        var rules = ShowRuleSettings()
        rules.batteryCondition = .below20
        rules.batteryOn = true
        #expect(rules.battery == .below20)
        rules.batteryOn = false
        #expect(rules.battery == nil)
        #expect(rules.batteryCondition == .below20)
    }

    // An icon that isn't in the menu bar, or sits in Visible, has nothing to
    // come back from.
    @Test func availabilityFollowsPresenceAndSection() {
        #expect(ShowRuleAvailability(inMenuBar: true, section: .hidden) == .applies)
        #expect(ShowRuleAvailability(inMenuBar: true, section: .alwaysHidden) == .applies)
        #expect(ShowRuleAvailability(inMenuBar: true, section: .visible) == .inVisible)
        #expect(ShowRuleAvailability(inMenuBar: false, section: .hidden) == .notInMenuBar)
        // Not being in the bar outranks where the model filed it.
        #expect(ShowRuleAvailability(inMenuBar: false, section: .visible) == .notInMenuBar)
    }

    // The card lists these two; launchers keep their own rule on their row,
    // Media its indicator picker (an indicator again, 2026-10-12).
    @Test func onlyActivityDrivenItemsShowWhenItMatters() {
        let listed = ExtraKind.allCases.filter(\.showsWhenItMatters)
        #expect(Set(listed) == [.focus, .timeMachine])
        // Media comes out while playing, Focus and Time Machine stay put.
        #expect(ExtraKind.mediaControls.defaultShowRule == .whenActive)
        #expect(ExtraKind.focus.defaultShowRule == .always)
        #expect(ExtraKind.timeMachine.defaultShowRule == .always)
    }
}
