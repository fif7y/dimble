import Foundation
import Testing
@testable import PelmetCore

@Suite struct RevealRoutingTests {
    @Test func showAllDisplaysIgnorePanelClicksOnly() {
        let reasons: [RevealReason] = [.click, .doubleClick, .statusItem, .hover,
                                      .hotkey, .barDrag, .displayPolicy, .settingsPreview, .itemInBar]
        for target in RevealTarget.allCases {
            for reason in reasons {
                let isClick = reason == .click || reason == .doubleClick || reason == .statusItem
                #expect(RevealRouting.suppressesPanelClick(reason, behavior: .alwaysShowAll, target: target)
                        == (target != .menuBar && isClick))
                #expect(!RevealRouting.suppressesPanelClick(reason, behavior: .collapse, target: target))
            }
        }
    }

    @Test func clickSuppressionFollowsTheDisplaysOwnBehaviorAndLayout() {
        var settings = SettingsStore()
        settings.hiddenIconsIn = .panel
        settings.displayOverrides["external"] = .alwaysShowAll
        settings.displayOverrides["builtin"] = .collapse
        func suppressed(_ uuid: String) -> Bool {
            RevealRouting.suppressesPanelClick(.click,
                behavior: settings.behavior(forDisplayUUID: uuid),
                target: settings.revealTarget(forDisplayUUID: uuid))
        }
        #expect(suppressed("external"))
        #expect(!suppressed("builtin"))
        settings.displayRevealTargets["external"] = .row
        #expect(suppressed("external"))
        settings.displayRevealTargets["external"] = .menuBar
        #expect(!suppressed("external"))
    }

    @Test func clickCenteringIsOptInAndNeverMovesAnOpenPanel() {
        let reasons: [RevealReason?] = [nil, .click, .doubleClick, .statusItem, .hover,
                                      .hotkey, .barDrag, .displayPolicy, .settingsPreview, .itemInBar]
        for reason in reasons {
            #expect(!RevealRouting.centersPanelOnClick(reason, enabled: false, isOpen: false))
            #expect(!RevealRouting.centersPanelOnClick(reason, enabled: true, isOpen: true))
            #expect(RevealRouting.centersPanelOnClick(reason, enabled: true, isOpen: false)
                    == (reason == .click || reason == .doubleClick))
        }
    }

    // A reveal a person asks for follows the setting; the menu bar target is
    // the bar for every reason.
    private func followsTheSetting(_ reason: RevealReason) {
        #expect(RevealRouting.destination(for: reason, target: .menuBar) == .bar)
        #expect(RevealRouting.destination(for: reason, target: .panel) == .panel)
        #expect(RevealRouting.destination(for: reason, target: .row) == .panel)
    }

    // These need the real bar whatever the setting says.
    private func alwaysTheBar(_ reason: RevealReason) {
        for target in RevealTarget.allCases {
            #expect(RevealRouting.destination(for: reason, target: target) == .bar)
        }
    }

    @Test func hoverFollowsTheSetting() { followsTheSetting(.hover) }
    @Test func clickFollowsTheSetting() { followsTheSetting(.click) }
    @Test func doubleClickFollowsTheSetting() { followsTheSetting(.doubleClick) }
    @Test func hotkeyFollowsTheSetting() { followsTheSetting(.hotkey) }
    @Test func statusItemFollowsTheSetting() { followsTheSetting(.statusItem) }
    // A ⌘-drag drops where hidden icons show: the hidden run, or the panel.
    @Test func barDragFollowsTheSetting() { followsTheSetting(.barDrag) }

    // Apply and the editor's preview measure and drag icons that are on the bar.
    @Test func settingsPreviewIsAlwaysTheBar() { alwaysTheBar(.settingsPreview) }
    // "Always show everything here" is the bar by definition.
    @Test func displayPolicyIsAlwaysTheBar() { alwaysTheBar(.displayPolicy) }
    // Pelmet's own extras and "show in bar" ask for the bar itself.
    @Test func itemInBarIsAlwaysTheBar() { alwaysTheBar(.itemInBar) }

    @Test func rowTargetUsesThePanelPresenterInItsRowLayout() {
        #expect(RevealTarget.menuBar.panelLayout == nil)
        #expect(RevealTarget.panel.panelLayout == .panel)
        #expect(RevealTarget.row.panelLayout == .row)
    }

    // #88: each display can pick its own "Show hidden icons in"; the rest
    // follow the Panel tab. A display that shows all icons keeps its own:
    // a chevron click there opens Always Hidden in it (#96).
    @Test func eachDisplayFollowsItsOwnChoiceOrThePanelTab() {
        var settings = SettingsStore()
        settings.hiddenIconsIn = .panel
        settings.displayRevealTargets = ["LG": .menuBar, "BenQ": .row]
        #expect(settings.revealTarget(forDisplayUUID: "LG") == .menuBar)
        #expect(settings.revealTarget(forDisplayUUID: "BenQ") == .row)
        #expect(settings.revealTarget(forDisplayUUID: "Built-in") == .panel)
        #expect(settings.revealTarget(forDisplayUUID: nil) == .panel)
        #expect(settings.ownRevealTarget(forDisplayUUID: "Built-in") == nil)
        #expect(RevealRouting.destination(for: .hover, target: settings.revealTarget(forDisplayUUID: "LG")) == .bar)
        #expect(RevealRouting.destination(for: .hover, target: settings.revealTarget(forDisplayUUID: "Built-in")) == .panel)
        settings.displayOverrides["LG"] = .alwaysShowAll
        #expect(settings.revealTarget(forDisplayUUID: "LG") == .menuBar)
        #expect(settings.ownRevealTarget(forDisplayUUID: "LG") == .menuBar)
        settings.displayOverrides["BenQ"] = .alwaysShowAll
        settings.displayRevealTargets["BenQ"] = nil
        #expect(settings.revealTarget(forDisplayUUID: "BenQ") == .panel)
    }

    private func deciding(
        _ reason: RevealReason, pointer: String?, active: String?, bars: Set<String>
    ) -> String? {
        RevealRouting.decidingDisplay(
            atBar: RevealRouting.startsAtBar(reason), pointer: pointer, active: active, primary: "Built-in",
            hasBar: bars.contains)
    }

    // The bar under the pointer decides, bright or dimmed: a hover on the
    // external while the built-in is active is the external's reveal.
    @Test func theBarUnderThePointerDecidesWhateverIsActive() {
        let bars: Set = ["Built-in", "LG"]
        for reason in [RevealReason.hover, .click, .doubleClick, .statusItem, .barDrag, .displayPolicy] {
            #expect(deciding(reason, pointer: "LG", active: "Built-in", bars: bars) == "LG")
            #expect(deciding(reason, pointer: "Built-in", active: "LG", bars: bars) == "Built-in")
        }
        // Started on a bar, its display counts even when the read missed it.
        #expect(deciding(.hover, pointer: "LG", active: "Built-in", bars: ["Built-in"]) == "LG")
    }

    // A shortcut follows the pointer's display while a bar is drawn there;
    // over a full-screen app (no bar) the active display's, then the primary.
    @Test func aShortcutFallsBackToTheActiveDisplayThenThePrimary() {
        for reason in [RevealReason.hotkey, .itemInBar, .settingsPreview] {
            #expect(deciding(reason, pointer: "LG", active: "Built-in", bars: ["Built-in", "LG"]) == "LG")
            #expect(deciding(reason, pointer: "LG", active: "BenQ", bars: ["Built-in", "BenQ"]) == "BenQ")
            #expect(deciding(reason, pointer: "LG", active: "LG", bars: ["Built-in"]) == "Built-in")
            #expect(deciding(reason, pointer: "LG", active: nil, bars: ["Built-in"]) == "Built-in")
            #expect(deciding(reason, pointer: nil, active: "BenQ", bars: ["BenQ"]) == "BenQ")
            #expect(deciding(reason, pointer: nil, active: nil, bars: []) == "Built-in")
        }
    }

    // The external reveals in its bar, the built-in in the panel, the
    // shortcut over a full-screen app on the external lands on the built-in
    // it fell back to.
    @Test func routingPerDisplayEndToEnd() {
        var settings = SettingsStore()
        settings.hiddenIconsIn = .panel
        settings.displayRevealTargets = ["LG": .menuBar]
        func destination(_ reason: RevealReason, pointer: String, active: String, bars: Set<String>) -> RevealRouting.Destination {
            let display = deciding(reason, pointer: pointer, active: active, bars: bars)
            return RevealRouting.destination(for: reason, target: settings.revealTarget(forDisplayUUID: display))
        }
        let both: Set = ["Built-in", "LG"]
        #expect(destination(.hover, pointer: "LG", active: "Built-in", bars: both) == .bar)
        #expect(destination(.hover, pointer: "Built-in", active: "LG", bars: both) == .panel)
        #expect(destination(.hotkey, pointer: "LG", active: "Built-in", bars: both) == .bar)
        #expect(destination(.hotkey, pointer: "LG", active: "LG", bars: ["Built-in"]) == .panel)
        #expect(destination(.itemInBar, pointer: "Built-in", active: "Built-in", bars: both) == .bar)
    }

    @Test func needsBarIsTheReasonsThatIgnoreTheSetting() {
        #expect(RevealRouting.needsBar(nil))
        for reason in [RevealReason.settingsPreview, .displayPolicy, .itemInBar] { #expect(RevealRouting.needsBar(reason)) }
        for reason in [RevealReason.hover, .click, .doubleClick, .hotkey, .statusItem, .barDrag] {
            #expect(!RevealRouting.needsBar(reason))
        }
    }

    // A downgrade, or a hand-edited blob, lands on the menu bar.
    @Test func unknownTargetDecodesAsTheMenuBar() throws {
        func decode(_ raw: String) throws -> RevealTarget {
            try JSONDecoder().decode([RevealTarget].self, from: Data("[\"\(raw)\"]".utf8))[0]
        }
        #expect(try decode("panel") == .panel)
        #expect(try decode("row") == .row)
        #expect(try decode("menuBar") == .menuBar)
        #expect(try decode("floatingBar") == .menuBar)
        #expect(try decode("") == .menuBar)
        let back = try JSONDecoder().decode([RevealTarget].self, from: JSONEncoder().encode(RevealTarget.allCases))
        #expect(back == RevealTarget.allCases)
    }

    @Test func clickOnAShowAllDisplayWidensToAlwaysHidden() {
        #expect(RevealRouting.clickWidensToAlwaysHidden(.statusItem, sections: [.hidden], behavior: .alwaysShowAll))
        // A hiding display, a hover, or a reveal already asking for more: unchanged.
        #expect(!RevealRouting.clickWidensToAlwaysHidden(.statusItem, sections: [.hidden], behavior: .collapse))
        #expect(!RevealRouting.clickWidensToAlwaysHidden(.hover, sections: [.hidden], behavior: .alwaysShowAll))
        #expect(!RevealRouting.clickWidensToAlwaysHidden(.hotkey, sections: [.hidden], behavior: .alwaysShowAll))
        #expect(!RevealRouting.clickWidensToAlwaysHidden(.statusItem, sections: [.hidden, .alwaysHidden], behavior: .alwaysShowAll))
    }
}
