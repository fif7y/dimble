// EditorItemsBuilderTests.swift
// Locks the editor-board rules: twin collapse, concealed stand-ins, stored
// no-flash members, explicit-order sort with the frame-nil-rightmost
// tiebreak, and extras/separators representation.

import CoreGraphics
import Testing
import PelmetCore
import PelmetEngine
@testable import Pelmet

@MainActor
struct EditorItemsBuilderTests {
    @Test func weTypeAppearsInEditorAndSurvivesSourceSwitch() {
        let weType = ItemID.status(bundle: "com.apple.TextInputMenuAgent", title: "微信输入法")
        let abc = ItemID.status(bundle: "com.apple.TextInputMenuAgent", title: "ABC")
        #expect(build(section: .visible, items: [ObservedItem(id: weType, frame: frame(x: 2516), appName: "微信输入法")]).map(\.id) == [weType])
        let model = SectionModel(assignments: [weType.sectionKey: .hidden])
        #expect(build(items: [ObservedItem(id: abc, frame: frame(x: 2516), appName: "ABC")], model: model).map(\.id) == [abc])
    }

    @Test func inputMenuStaysInEditorDuringSnapshotGap() {
        let input = ItemID.status(bundle: "com.apple.TextInputMenuAgent", title: "微信输入法")
        let model = SectionModel(assignments: [input.sectionKey: .hidden])
        #expect(build(model: model, running: ["com.apple.TextInputMenuAgent"]).map(\.id) == [input.sectionKey])
    }

    @Test func storedSystemItemNeverSeenStaysOff() {
        // 2026-09-10: the input menu switched off in System Settings — its
        // agent keeps running, so "running" alone kept a Canadian tile on the
        // board for an item that no longer exists in the bar.
        let input = ItemID.status(bundle: "com.apple.TextInputMenuAgent", title: "Canadian")
        let model = SectionModel(assignments: [input.sectionKey: .hidden])
        #expect(build(model: model, running: ["com.apple.TextInputMenuAgent"], recentlySeen: false).isEmpty)
        // Concealed by Pelmet (in the engine's set) is presence, not absence.
        #expect(build(concealed: [input], model: model, running: ["com.apple.TextInputMenuAgent"], recentlySeen: false).map(\.id) == [input])
    }

    let pelmet = "app.fif7y.Pelmet"
    let velja = ItemID(rawValue: "status:com.sindresorhus.Velja::Item-0")
    let veljaTwin = ItemID(rawValue: "status:com.sindresorhus.Velja::Left arrows")
    let figma = ItemID(rawValue: "status:com.figma.Desktop::Item-0")

    func frame(x: CGFloat) -> CGRect {
        CGRect(x: x, y: 0, width: 30, height: 24)
    }

    func build(
        section: PelmetCore.Section = .hidden,
        items: [ObservedItem] = [],
        concealed: Set<ItemID> = [],
        extras: [ExtraItemSpec] = [],
        separators: [SeparatorSpec] = [],
        model: SectionModel = SectionModel(),
        running: Set<String> = [],
        names: [String: String] = [:],
        recentlySeen: Bool = true,
        destroyed: Set<ItemID> = []
    ) -> [ObservedItem] {
        EditorItemsBuilder.build(
            section: section,
            snapshotItems: items,
            concealed: concealed,
            extraItems: extras,
            separators: separators,
            model: model,
            pelmetBundleID: pelmet,
            isRunning: { running.contains($0) },
            appName: { names[$0] },
            recentlySeen: { _ in recentlySeen },
            destroyed: destroyed
        )
    }

    @Test func barKilledIconKeepsItsTileInItsDefaultSection() {
        // #30: iStat Menus is unassigned (so not in `stored`), Pelmet never
        // concealed it (so not in `concealed`), and the agent destroyed its
        // scenes (so no frame) — it belonged to no branch and the board lost
        // it under both Visible and Hidden. A confirmed casualty gets a tile.
        let istat = ItemID(rawValue: "status:com.bjango.istatmenus.status::CPU")
        #expect(build(section: .visible, running: ["com.bjango.istatmenus.status"]).isEmpty)
        let result = build(
            section: .visible,
            running: ["com.bjango.istatmenus.status"],
            names: ["com.bjango.istatmenus.status": "iStat Menus"],
            destroyed: [istat]
        )
        #expect(result.map(\.id) == [istat])
        #expect(result.first?.appName == "iStat Menus")
        #expect(result.first?.frame == nil)
        // Its app quit: no tile (the guard the concealed path uses too).
        #expect(build(section: .visible, destroyed: [istat]).isEmpty)
    }

    @Test func barKilledIconDoesNotDoubleUpWithALiveTile() {
        let istat = ItemID(rawValue: "status:com.bjango.istatmenus.status::CPU")
        let result = build(
            section: .visible,
            items: [ObservedItem(id: istat, frame: frame(x: 400), appName: "iStat Menus")],
            running: ["com.bjango.istatmenus.status"],
            destroyed: [istat]
        )
        #expect(result.count == 1)
        #expect(result.first?.frame != nil)
    }

    @Test func liveTwinsCollapseToLeftmostFrame() {
        var model = SectionModel()
        model.assignments[velja.sectionKey] = .hidden
        let result = build(
            items: [
                ObservedItem(id: velja, frame: frame(x: 300), appName: "Velja"),
                ObservedItem(id: veljaTwin, frame: frame(x: 200), appName: "Velja"),
            ],
            model: model
        )
        #expect(result.count == 1)
        #expect(result.first?.id == veljaTwin)
    }

    @Test func concealedItemGetsStandInWithAppName() {
        var model = SectionModel()
        model.assignments[velja.sectionKey] = .hidden
        let result = build(
            concealed: [velja],
            model: model,
            running: ["com.sindresorhus.Velja"],
            names: ["com.sindresorhus.Velja": "Velja"]
        )
        #expect(result.map(\.id) == [velja])
        #expect(result.first?.frame == nil)
        #expect(result.first?.appName == "Velja")
    }

    /// The engine's concealed set is "as of the last converge" — an app that
    /// quits stays in it, and its stand-in must NOT outlive the app on the
    /// board (Bitwarden quit while settings open, 2026-08-31).
    @Test func concealedStandInOfQuitAppDrops() {
        var model = SectionModel()
        model.assignments[velja.sectionKey] = .hidden
        let result = build(concealed: [velja], model: model)
        #expect(result.isEmpty)
    }

    @Test func staleConcealedTwinOfLiveBundleDrops() {
        var model = SectionModel()
        model.assignments[velja.sectionKey] = .hidden
        let result = build(
            items: [ObservedItem(id: velja, frame: frame(x: 300), appName: "Velja")],
            concealed: [veljaTwin],
            model: model
        )
        #expect(result.map(\.id) == [velja])
    }

    @Test func storedRunningMemberAppearsQuitAppStaysOff() {
        var model = SectionModel()
        model.assignments[velja.sectionKey] = .hidden
        model.assignments[figma.sectionKey] = .hidden
        let result = build(
            model: model,
            running: ["com.sindresorhus.Velja"],
            names: ["com.sindresorhus.Velja": "Velja"]
        )
        #expect(result.map(\.id) == [velja.sectionKey])
        #expect(result.first?.frame == nil)
    }

    @Test func explicitOrderOutranksFramesAndFrameNilSortsRightmost() {
        var model = SectionModel()
        model.assignments[velja.sectionKey] = .hidden
        model.assignments[figma.sectionKey] = .hidden
        model.order[.hidden] = [figma.sectionKey]
        let result = build(
            items: [ObservedItem(id: velja, frame: frame(x: 100), appName: nil)],
            concealed: [figma],
            model: model,
            running: ["com.figma.Desktop"]
        )
        // Figma is explicitly ordered first despite Velja's live frame.
        #expect(result.map(\.id) == [figma, velja])

        // Without explicit order, the frame-nil stand-in sorts rightmost.
        model.order[.hidden] = []
        let unordered = build(
            items: [ObservedItem(id: velja, frame: frame(x: 100), appName: nil)],
            concealed: [figma],
            model: model,
            running: ["com.figma.Desktop"]
        )
        #expect(unordered.map(\.id) == [velja, figma])
    }

    @Test func pelmetExtrasAndSeparatorsAreRepresented() {
        let extra = ExtraItemSpec(kind: .mediaControls)
        let separator = SeparatorSpec(style: .pipe)
        var model = SectionModel()
        model.assignments[ExtrasManager.itemID(for: extra)] = .hidden
        model.assignments[SeparatorManager.itemID(for: separator)] = .hidden
        let result = build(
            extras: [extra],
            separators: [separator],
            model: model
        )
        #expect(Set(result.map(\.id)) == [
            ExtrasManager.itemID(for: extra),
            SeparatorManager.itemID(for: separator),
        ])
    }

    /// The walk can list a removed separator for seconds. A new one was filed
    /// in front of it and landed on the wrong side (2026-11-24).
    @Test func aRemovedSeparatorStillOnTheBarLeavesTheBoard() {
        let gone = SeparatorSpec(style: .dot), kept = SeparatorSpec(style: .dot)
        let goneID = SeparatorManager.itemID(for: gone), keptID = SeparatorManager.itemID(for: kept)
        let hosted = ItemID(rawValue: goneID.rawValue.replacingOccurrences(of: "app.fif7y.Pelmet::", with: "app.fif7y.Pelmet.items.hidden::"))
        let model = SectionModel(assignments: [goneID: .hidden, keptID: .hidden, velja.sectionKey: .hidden])
        for id in [goneID, hosted] {
            let result = build(
                items: [
                    ObservedItem(id: velja, frame: frame(x: 100), appName: nil),
                    ObservedItem(id: id, frame: frame(x: 130), appName: nil),
                    ObservedItem(id: keptID, frame: frame(x: 160), appName: nil),
                ],
                separators: [kept],
                model: model
            )
            #expect(result.map(\.id) == [velja, keptID])
        }
    }

    @Test func appStandInCarriesItsAppNameAndBundlelessHostSurvives() {
        let launcher = ExtraItemSpec(kind: .appLauncher, bundleID: "com.openai.chat", appName: "ChatGPT")
        let helperItem = ItemID(rawValue: "status:com.openai.chat::Item-0")
        var model = SectionModel()
        model.assignments[ExtrasManager.itemID(for: launcher)] = .hidden
        model.assignments[helperItem.sectionKey] = .hidden
        let result = build(
            items: [
                ObservedItem(id: helperItem, frame: frame(x: 100), appName: "ChatGPT", hostIsBundleless: true),
                // Live in AX, named after its host — the spec's name wins.
                ObservedItem(id: ExtrasManager.itemID(for: launcher), frame: frame(x: 140), appName: "Dimble"),
            ],
            extras: [launcher],
            model: model,
            running: ["com.openai.chat"]
        )
        let tile = result.first { $0.id == ExtrasManager.itemID(for: launcher) }
        #expect(tile?.appName == "ChatGPT")
        #expect(tile?.frame != nil)
        #expect(result.first { $0.id == helperItem }?.hostIsBundleless == true)
    }

    @Test func onlyTheUndrawableAppleHostsStayOffTheBoard() {
        let clock = ItemID(rawValue: "status:com.apple.MenuBarAgent::com.apple.menuextra.clock")
        // Weather, not Siri: Siri.app lives in CoreServices, and the test
        // host's boot registers every running CoreServices agent as
        // unmanaged (47efc72) — Pelmet offers its own Siri item instead.
        let weather = ItemID(rawValue: "status:com.apple.weather.menu::Item-0")
        let bento = ItemID(rawValue: "status:com.apple.controlcenter::Item-0")
        var model = SectionModel()
        model.assignments[clock] = .hidden
        model.assignments[weather.sectionKey] = .hidden
        model.assignments[bento.sectionKey] = .hidden
        let result = build(
            items: [
                ObservedItem(id: clock, frame: frame(x: 100), appName: nil),
                ObservedItem(id: weather, frame: frame(x: 130), appName: "Weather"),
                ObservedItem(id: bento, frame: frame(x: 160), appName: "Control Center"),
            ],
            model: model
        )
        // The clock is assertion-controllable (SystemItem table) and an Apple
        // app with its own status item is an ordinary tile — both stay.
        // Control Center comes back under any assertion, so it never does.
        #expect(result.map(\.id) == [clock, weather])
    }
}
