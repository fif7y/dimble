import Foundation
import Testing
@testable import PelmetCore

struct SettingsStoreTests {
    // "Show while revealed" is overridden while a Pelmet replica of a
    // collateral extra is on (#39: the camera pill came back on every hover).
    @Test func collateralReplicaForcesTheSystemExtrasHold() {
        var settings = SettingsStore()
        settings.hideSystemExtras = false
        settings.extraItems = []
        #expect(!settings.effectiveHideSystemExtras)
        settings.extraItems = [ExtraItemSpec(kind: .siri)]
        #expect(!settings.effectiveHideSystemExtras)
        settings.extraItems = [ExtraItemSpec(kind: .cameraMicIndicator)]
        #expect(settings.replacesCollateralExtras)
        #expect(settings.effectiveHideSystemExtras)
        settings.hideSystemExtras = true
        settings.extraItems = []
        #expect(settings.effectiveHideSystemExtras)
    }

    // Pending order edits survive a quit (docs/CORE-SETS.md M1), and a blob
    // saved before the field existed decodes with none pending.
    @Test func orderEditsRoundTripAndDefault() throws {
        var settings = SettingsStore()
        let a = ItemID.bundleKey("com.a"), b = ItemID.bundleKey("com.b")
        settings.orderEdits = OrderEdits(
            order: [.hidden: [b, a]], previousSection: [a: .visible], previousOrder: [.hidden: [b], .visible: [a]],
            created: [b])
        let data = try JSONEncoder().encode(settings)
        let back = try JSONDecoder().decode(SettingsStore.self, from: data)
        #expect(back.orderEdits == settings.orderEdits)
        let legacy = try JSONDecoder().decode(SettingsStore.self, from: Data("{}".utf8))
        #expect(legacy.orderEdits.isEmpty)
        // An edit set saved before `previousSection` existed still decodes.
        let older = try JSONDecoder().decode(
            OrderEdits.self, from: Data(#"{"order":[]}"#.utf8))
        #expect(older.isEmpty)
        #expect(!OrderEdits(previousSection: [a: .hidden]).isEmpty)
        var edits = settings.orderEdits
        edits.clearOrder(for: .hidden)
        #expect(edits.order[.hidden] == nil && edits.previousOrder[.hidden] == nil && edits.previousOrder[.visible] == [a])
        // Placing the section that held the created item retires it from Discard.
        #expect(edits.created.isEmpty)
    }

    // The Always Hidden shortcut (#67) is never off: an upgraded blob and a
    // null both take ⌃⌥⌘, and a recorded one survives a save.
    @Test func alwaysHiddenHotkeyDefaultsAndRoundTrips() throws {
        let legacy = try JSONDecoder().decode(SettingsStore.self, from: Data("{}".utf8))
        #expect(legacy.alwaysHiddenHotkey == .alwaysHiddenDefault)
        let null = try JSONDecoder().decode(SettingsStore.self, from: Data(#"{"alwaysHiddenHotkey":null}"#.utf8))
        #expect(null.alwaysHiddenHotkey == .alwaysHiddenDefault)
        var settings = SettingsStore()
        settings.alwaysHiddenHotkey = HotkeySpec(keyCode: 0x2F, modifiers: 0x900, display: "⌥⌘.")
        let back = try JSONDecoder().decode(SettingsStore.self, from: JSONEncoder().encode(settings))
        #expect(back.alwaysHiddenHotkey == settings.alwaysHiddenHotkey)
    }

    // Live mode is on for everyone: a blob saved before the setting existed,
    // and a field that fails to decode, both take it on; off survives a save.
    @Test func showLiveActivitiesDefaultsOnAndRoundTrips() throws {
        #expect(SettingsStore().showLiveActivities)
        let legacy = try JSONDecoder().decode(SettingsStore.self, from: Data("{}".utf8))
        #expect(legacy.showLiveActivities)
        let broken = try JSONDecoder().decode(SettingsStore.self, from: Data(#"{"showLiveActivities":"yes"}"#.utf8))
        #expect(broken.showLiveActivities)
        var settings = SettingsStore()
        settings.showLiveActivities = false
        let back = try JSONDecoder().decode(SettingsStore.self, from: JSONEncoder().encode(settings))
        #expect(!back.showLiveActivities)
        let on = try JSONDecoder().decode(SettingsStore.self, from: Data(#"{"showLiveActivities":true}"#.utf8))
        #expect(on.showLiveActivities)
    }

    // Turned off on purpose (#79) survives a save; only a missing, null or
    // unreadable value falls back to the default.
    @Test func turnedOffHotkeyRoundTrips() throws {
        var settings = SettingsStore()
        settings.hotkey = .off
        settings.searchHotkey = .off
        let back = try JSONDecoder().decode(SettingsStore.self, from: JSONEncoder().encode(settings))
        #expect(back.hotkey?.isOff == true && back.searchHotkey?.isOff == true)
        #expect(back.settingsHotkey == .settingsDefault)
        #expect(!HotkeySpec.default.isOff)
    }

    // The command bar's shortcut (⌥⌘K) falls back to its default too.
    @Test func searchHotkeyDefaultsAndRoundTrips() throws {
        let legacy = try JSONDecoder().decode(SettingsStore.self, from: Data("{}".utf8))
        #expect(legacy.searchHotkey == .searchDefault)
        #expect(HotkeySpec.searchDefault.display == "⌥⌘K")
        let null = try JSONDecoder().decode(SettingsStore.self, from: Data(#"{"searchHotkey":null}"#.utf8))
        #expect(null.searchHotkey == .searchDefault)
        var settings = SettingsStore()
        settings.searchHotkey = HotkeySpec(keyCode: 0x25, modifiers: 0x900, display: "⌥⌘L")
        let back = try JSONDecoder().decode(SettingsStore.self, from: JSONEncoder().encode(settings))
        #expect(back.searchHotkey == settings.searchHotkey)
    }

    // Per-item shortcuts and aliases are new fields: an older blob has none,
    // and a bad value costs only that field.
    @Test func itemHotkeysAndAliasesDefaultEmptyAndRoundTrip() throws {
        let legacy = try JSONDecoder().decode(SettingsStore.self, from: Data("{}".utf8))
        #expect(legacy.itemHotkeys.isEmpty)
        #expect(legacy.itemAliases.isEmpty)
        let bad = try JSONDecoder().decode(
            SettingsStore.self, from: Data(#"{"itemHotkeys":"nope","itemAliases":[1],"autoRehide":false}"#.utf8))
        #expect(bad.itemHotkeys.isEmpty && bad.itemAliases.isEmpty)
        #expect(bad.autoRehide == false)
        var settings = SettingsStore()
        settings.itemHotkeys["bundle:com.example.app"] = HotkeySpec(keyCode: 0x0D, modifiers: 0x900, display: "⌥⌘W")
        settings.itemAliases["bundle:com.example.app"] = "work"
        let back = try JSONDecoder().decode(SettingsStore.self, from: JSONEncoder().encode(settings))
        #expect(back.itemHotkeys == settings.itemHotkeys)
        #expect(back.itemAliases == settings.itemAliases)
    }

    // Where hidden icons show up is a new field: an older blob has none and
    // keeps the menu bar. A target this build doesn't know reads as the menu
    // bar too, and the rest of the blob survives it.
    @Test func hiddenIconsInDefaultsFallsBackAndRoundTrips() throws {
        let legacy = try JSONDecoder().decode(SettingsStore.self, from: Data("{}".utf8))
        #expect(legacy.hiddenIconsIn == .menuBar)
        let unknown = try JSONDecoder().decode(
            SettingsStore.self, from: Data(#"{"hiddenIconsIn":"floatingBar","autoRehide":false}"#.utf8))
        #expect(unknown.hiddenIconsIn == .menuBar)
        #expect(unknown.autoRehide == false)
        let wrongType = try JSONDecoder().decode(
            SettingsStore.self, from: Data(#"{"hiddenIconsIn":3,"rehideDelay":9}"#.utf8))
        #expect(wrongType.hiddenIconsIn == .menuBar)
        #expect(wrongType.rehideDelay == 9)
        for target in RevealTarget.allCases {
            var settings = SettingsStore()
            settings.hiddenIconsIn = target
            let back = try JSONDecoder().decode(SettingsStore.self, from: JSONEncoder().encode(settings))
            #expect(back.hiddenIconsIn == target)
        }
    }

    // The per-display choice (#88) reads value by value: an unknown target
    // or a wrong type drops that display's entry alone (back to the Panel
    // tab's choice), never the others, and never the rest of the blob.
    @Test func displayRevealTargetsDecodeEachValueOnItsOwn() throws {
        let legacy = try JSONDecoder().decode(SettingsStore.self, from: Data("{}".utf8))
        #expect(legacy.displayRevealTargets.isEmpty)
        let mixed = try JSONDecoder().decode(SettingsStore.self, from: Data(#"""
            {"displayRevealTargets":{"A":"menuBar","B":"floatingBar","C":3,"D":"row","E":null},
             "hiddenIconsIn":"panel","rehideDelay":9}
            """#.utf8))
        #expect(mixed.displayRevealTargets == ["A": .menuBar, "D": .row])
        #expect(mixed.revealTarget(forDisplayUUID: "B") == .panel)
        #expect(mixed.hiddenIconsIn == .panel)
        #expect(mixed.rehideDelay == 9)
        let notAMap = try JSONDecoder().decode(
            SettingsStore.self, from: Data(#"{"displayRevealTargets":["row"],"autoRehide":false}"#.utf8))
        #expect(notAMap.displayRevealTargets.isEmpty)
        #expect(notAMap.autoRehide == false)

        var settings = SettingsStore()
        settings.displayRevealTargets = ["37D8832A-2D66-02CA-B9F7-8F30A301B230": .menuBar, "B": .panel, "C": .row]
        let back = try JSONDecoder().decode(SettingsStore.self, from: JSONEncoder().encode(settings))
        #expect(back.displayRevealTargets == settings.displayRevealTargets)
    }

    // The panel options are a new nested field: defaults for an older blob,
    // and one bad option inside costs only itself.
    @Test func panelOptionsDefaultFallBackAndRoundTrip() throws {
        let legacy = try JSONDecoder().decode(SettingsStore.self, from: Data("{}".utf8))
        #expect(legacy.panel == PanelOptions())
        let notAnObject = try JSONDecoder().decode(
            SettingsStore.self, from: Data(#"{"panel":"wide","hiddenIconsIn":"panel"}"#.utf8))
        #expect(notAnObject.panel == PanelOptions())
        #expect(notAnObject.hiddenIconsIn == .panel)
        let oneBad = try JSONDecoder().decode(
            SettingsStore.self,
            from: Data(#"{"panel":{"alwaysHidden":"tucked","showsNames":true,"columnsWithNames":4}}"#.utf8))
        #expect(oneBad.panel.alwaysHidden == .folded)
        #expect(oneBad.panel.showsNames && oneBad.panel.columnsWithNames == 4)

        var settings = SettingsStore()
        settings.hiddenIconsIn = .row
        settings.panel.showsNames = true
        settings.panel.columnsWithNames = 6
        settings.panel.columnsCompact = 3
        settings.panel.separatorsBreakRows = true
        settings.panel.alwaysHidden = .asLeft
        settings.panel.alwaysHiddenOpen = true
        let back = try JSONDecoder().decode(SettingsStore.self, from: JSONEncoder().encode(settings))
        #expect(back.panel == settings.panel)
        #expect(back == settings)
    }

    @Test func theLiveActivitiesItemOnlyHasAPlaceWhileLiveModeIsNotDrawing() {
        var settings = SettingsStore()
        settings.extraItems = [ExtraItemSpec(kind: .liveActivity), ExtraItemSpec(kind: .timer)]
        settings.showLiveActivities = true
        #expect(settings.barExtraItems(screenRecording: true).map(\.kind) == [.timer])
        #expect(settings.barExtraItems(screenRecording: false).map(\.kind) == [.liveActivity, .timer])
        settings.showLiveActivities = false
        #expect(settings.barExtraItems(screenRecording: true).map(\.kind) == [.liveActivity, .timer])
        #expect(settings.barExtraItems(screenRecording: false).map(\.kind) == [.liveActivity, .timer])
    }

    // A pill turned off has to have a way back, and the item is it: it brings
    // every pill out live, so it keeps its place while live mode draws.
    @Test func aPillTurnedOffKeepsTheLiveActivitiesItemOnTheBar() {
        var settings = SettingsStore()
        settings.extraItems = [ExtraItemSpec(kind: .liveActivity)]
        settings.showLiveActivities = true
        #expect(settings.barExtraItems(screenRecording: true).isEmpty)
        settings.hiddenLiveActivities = ["Now Playing"]
        #expect(settings.barExtraItems(screenRecording: true).map(\.kind) == [.liveActivity])
        settings.hiddenLiveActivities = []
        #expect(settings.barExtraItems(screenRecording: true).isEmpty)
    }

    // Nothing is turned off until the user says so, and the list survives a
    // save. A blob from before the field, or one with it unreadable, leaves
    // every pill drawn rather than hiding one nobody chose.
    @Test func hiddenLiveActivitiesStartEmptyAndRoundTrip() throws {
        #expect(SettingsStore().hiddenLiveActivities.isEmpty)
        let legacy = try JSONDecoder().decode(SettingsStore.self, from: Data("{}".utf8))
        #expect(legacy.hiddenLiveActivities.isEmpty)
        let broken = try JSONDecoder().decode(SettingsStore.self, from: Data(#"{"hiddenLiveActivities":"Sports"}"#.utf8))
        #expect(broken.hiddenLiveActivities.isEmpty)
        var settings = SettingsStore()
        settings.hiddenLiveActivities = ["Now Playing", "Sports"]
        let back = try JSONDecoder().decode(SettingsStore.self, from: JSONEncoder().encode(settings))
        #expect(back.hiddenLiveActivities == ["Now Playing", "Sports"])
        #expect(back == settings)
    }
}
