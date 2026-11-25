import Foundation
import Testing
@testable import PelmetCore

struct AutomationLinkTests {
    private func link(_ string: String) -> AutomationLink? {
        URL(string: string).flatMap(AutomationLink.init(url:))
    }

    @Test func readsEachAction() {
        #expect(link("dimble://show") == .show)
        #expect(link("dimble://show-all") == .showAll)
        #expect(link("dimble://hide") == .hide)
        #expect(link("dimble://toggle") == .toggle)
        #expect(link("dimble://search") == .search(nil))
    }

    // Alfred sends the typed text percent-encoded (#146).
    @Test func searchTakesTheTextTyped() {
        #expect(link("dimble://search?q=Tailscale") == .search("Tailscale"))
        #expect(link("dimble://search?q=Little%20Snitch") == .search("Little Snitch"))
        #expect(link("dimble://search?q=%20wifi%20") == .search("wifi"))
        #expect(link("dimble://search?q=") == .search(""))
    }

    @Test func longTextIsCut() {
        let long = String(repeating: "a", count: 500)
        #expect(link("dimble://search?q=\(long)") == .search(String(repeating: "a", count: AutomationLink.maxQueryLength)))
    }

    @Test func spellingsThatMeanTheSame() {
        #expect(link("dimble:show") == .show)
        #expect(link("DIMBLE://Show") == .show)
        #expect(link("dimble://show/") == .show)
    }

    @Test func unknownLinksDoNothing() {
        #expect(link("dimble://open?icon=Tailscale") == nil)
        #expect(link("dimble://") == nil)
        #expect(link("https://show") == nil)
    }

    @Test func moveTakesASectionOrAPlace() {
        #expect(link("dimble://move?icon=Tailscale&to=hidden") == .move(icon: "Tailscale", to: .hidden, place: nil))
        #expect(link("dimble://move?icon=Tailscale&to=always-hidden") == .move(icon: "Tailscale", to: .alwaysHidden, place: nil))
        #expect(link("dimble://move?icon=Tailscale&to=alwaysHidden") == .move(icon: "Tailscale", to: .alwaysHidden, place: nil))
        #expect(link("dimble://move?icon=Tailscale&after=HomeBar") == .move(icon: "Tailscale", to: nil, place: .after("HomeBar")))
        #expect(link("dimble://move?icon=Little%20Snitch&before=Wi-Fi") == .move(icon: "Little Snitch", to: nil, place: .before("Wi-Fi")))
    }

    // Moving nowhere, or to a section Dimble can't read, is a broken link,
    // not a move to Visible.
    @Test func moveWithoutADestinationDoesNothing() {
        #expect(link("dimble://move?icon=Tailscale") == nil)
        #expect(link("dimble://move?icon=Tailscale&to=hiddden") == nil)
        #expect(link("dimble://move?to=hidden") == nil)
        #expect(link("dimble://move?icon=&to=hidden") == nil)
    }

    @Test func separatorLinks() {
        #expect(link("dimble://add-separator?to=hidden") == .addSeparator(to: .hidden, place: nil))
        #expect(link("dimble://add-separator?after=HomeBar") == .addSeparator(to: nil, place: .after("HomeBar")))
        #expect(link("dimble://add-separator") == nil)
        #expect(link("dimble://remove-separator?after=HomeBar") == .removeSeparator(id: nil, place: .after("HomeBar")))
        #expect(link("dimble://remove-separator?id=abc") == .removeSeparator(id: "abc", place: nil))
        #expect(link("dimble://remove-separator") == nil)
    }

    // Combining marks make one character of any size: the cut counts scalars.
    @Test func combiningMarksAreCutToo() {
        let heavy = "e" + String(repeating: "\u{0301}", count: 10_000)
        guard case .search(let text) = link("dimble://search?q=" + heavy.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!) else {
            // Longer than any link Dimble reads: refused whole.
            #expect(link("dimble://search?q=" + heavy.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!) == nil)
            return
        }
        #expect((text?.unicodeScalars.count ?? 0) <= AutomationLink.maxQueryLength)
    }

    @Test func overlongLinksAreRefused() {
        #expect(link("dimble://show?pad=" + String(repeating: "a", count: AutomationLink.maxLinkLength)) == nil)
        let heavy = "e" + String(repeating: "\u{0301}", count: 300)
        guard case .search(let text) = link("dimble://search?q=" + heavy.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!) else {
            Issue.record("a 600-byte search link should open")
            return
        }
        #expect(text?.unicodeScalars.count == AutomationLink.maxQueryLength)
    }

    @Test func theLogNeverCarriesTheText() {
        #expect(AutomationLink.search("secret").name == "search")
    }
}

struct LayoutExportTests {
    @Test func kindsFollowTheOwner() {
        typealias Item = LayoutExport.Item
        #expect(Item(name: "Tailscale", id: ItemID(rawValue: "bundle:io.tailscale.ipn.macsys")).kind == .app)
        #expect(Item(name: "Wi-Fi", id: .status(bundle: PelmetBundle.agentID, title: "com.apple.menuextra.wifi")).kind == .apple)
        #expect(Item(name: "Media", id: .status(bundle: PelmetBundle.fallbackID, title: "Pelmet.MediaControls")).kind == .dimble)
        #expect(Item(name: "Separator", id: .status(bundle: PelmetBundle.fallbackID, title: "Pelmet.Separator.1")).kind == .separator)
    }

    // Dimble's own items carry no bundle id: it would only name Dimble.
    @Test func ownItemsLeaveOutTheBundle() {
        let app = LayoutExport.Item(name: "Tailscale", id: ItemID(rawValue: "bundle:io.tailscale.ipn.macsys"))
        let own = LayoutExport.Item(name: "Media", id: .status(bundle: PelmetBundle.fallbackID, title: "Pelmet.MediaControls"))
        #expect(app.bundleID == "io.tailscale.ipn.macsys")
        #expect(own.bundleID == nil)
    }

    @Test func jsonKeepsSectionsAndItemsInOrder() throws {
        let layout = LayoutExport(sections: [
            .init(section: .visible, items: [.init(name: "Wi-Fi", id: .status(bundle: PelmetBundle.agentID, title: "com.apple.menuextra.wifi"))]),
            .init(section: .hidden, items: [
                .init(name: "Tailscale", id: ItemID(rawValue: "bundle:io.tailscale.ipn.macsys")),
                .init(name: "Bartender", id: ItemID(rawValue: "bundle:com.example.b")),
            ]),
            .init(section: .alwaysHidden, items: []),
        ])
        let json = layout.json()
        let decoded = try JSONDecoder().decode(LayoutExport.self, from: Data(json.utf8))
        #expect(decoded == layout)
        #expect(decoded.sections.map(\.section) == [.visible, .hidden, .alwaysHidden])
        #expect(decoded.sections[1].items.map(\.name) == ["Tailscale", "Bartender"])
        #expect(json.contains("\"section\" : \"alwaysHidden\""))
        #expect(json.contains("\"format\" : 1"))
    }

    // Sorted keys: the same bar gives the same text, so a saved copy only
    // changes where the bar did.
    @Test func sameLayoutSameText() {
        let layout = LayoutExport(sections: [.init(section: .hidden, items: [.init(name: "A", id: ItemID(rawValue: "bundle:a.b"))])])
        #expect(layout.json() == layout.json())
        #expect(layout.json().range(of: "\"bundleID\"")!.lowerBound < layout.json().range(of: "\"name\"")!.lowerBound)
    }
}

struct IconMatchTests {
    private let bar = [
        IconMatch.Candidate(name: "Wi-Fi", id: "status:com.apple.MenuBarAgent::com.apple.menuextra.wifi"),
        IconMatch.Candidate(name: "Wi-Fi Signal", id: "bundle:com.example.signal"),
        IconMatch.Candidate(name: "Tailscale", id: "bundle:io.tailscale.ipn.macsys"),
        IconMatch.Candidate(name: "Separator", id: "status:app.fif7y.Pelmet::Pelmet.Separator.A"),
        IconMatch.Candidate(name: "Separator", id: "status:app.fif7y.Pelmet::Pelmet.Separator.B"),
        IconMatch.Candidate(name: "Café", id: "bundle:com.example.cafe"),
    ]

    private func names(_ text: String) -> [String] { IconMatch.matches(text, in: bar).map(\.name) }

    // An exact name wins over the names that contain it.
    @Test func exactNameFirst() {
        #expect(names("wi-fi") == ["Wi-Fi"])
        #expect(names("Signal") == ["Wi-Fi Signal"])
        #expect(names("cafe") == ["Café"])
    }

    @Test func theLayoutsIdNamesOneIcon() {
        #expect(IconMatch.matches("status:app.fif7y.Pelmet::Pelmet.Separator.B", in: bar).map(\.id) == ["status:app.fif7y.Pelmet::Pelmet.Separator.B"])
    }

    @Test func aBundleIdFindsItsApp() {
        #expect(names("io.tailscale") == ["Tailscale"])
    }

    // Two of a name come back as two: the caller decides, a link refuses.
    @Test func sameNamesStayTwo() {
        #expect(names("Separator").count == 2)
        #expect(names("nothing like it").isEmpty)
        #expect(names("  ").isEmpty)
    }
}

struct LayoutRestoreTests {
    private let wifi = ItemID.status(bundle: PelmetBundle.agentID, title: "com.apple.menuextra.wifi")
    private let clock = ItemID.status(bundle: PelmetBundle.agentID, title: "com.apple.menuextra.clock")
    private let tailscale = ItemID(rawValue: "bundle:io.tailscale.ipn.macsys")
    private let snib = ItemID(rawValue: "bundle:app.fif7y.Snib")
    private let stats = ItemID(rawValue: "bundle:eu.exelban.Stats")
    private let separator = ItemID.status(bundle: PelmetBundle.fallbackID, title: "Pelmet.Separator.A")

    private var board: [Section: [LayoutRestore.BoardItem]] {
        [
            .visible: [.init(key: wifi, name: "Wi-Fi"), .init(key: clock, name: "Clock")],
            .hidden: [.init(key: tailscale, name: "Tailscale"), .init(key: separator, name: "Separator"), .init(key: snib, name: "Snib")],
            .alwaysHidden: [.init(key: stats, name: "Stats")],
        ]
    }

    private func plan(_ json: String) throws -> LayoutRestore.Plan {
        LayoutRestore.plan(try LayoutRestore.read(json), board: board, movable: { $0 != clock })
    }

    // What Get Menu Bar Layout writes comes back as the same order.
    @Test func roundTripsTheExport() throws {
        let export = LayoutExport(sections: [
            .init(section: .visible, items: [.init(name: "Wi-Fi", id: wifi), .init(name: "Clock", id: clock)]),
            .init(section: .hidden, items: [.init(name: "Snib", id: snib), .init(name: "Tailscale", id: tailscale), .init(name: "Separator", id: separator)]),
            .init(section: .alwaysHidden, items: [.init(name: "Stats", id: stats)]),
        ])
        let result = try plan(export.json())
        #expect(result.order[.hidden] == [.item(snib), .item(tailscale), .item(separator)])
        #expect(result.order[.visible] == [.item(wifi)])
        #expect(result.order[.alwaysHidden] == [.item(stats)])
        #expect(result.missing.isEmpty)
    }

    // By hand: names, the section spellings links take, keys in any order.
    @Test func takesALayoutWrittenByHand() throws {
        let result = try plan(#"{"sections":[{"section":"always-hidden","items":[{"name":"tailscale"}]},{"section":"visible","items":[{"name":"Snib"}]}]}"#)
        #expect(result.order[.alwaysHidden] == [.item(tailscale), .item(stats)])
        #expect(result.order[.visible] == [.item(snib), .item(wifi)])
        #expect(result.order[.hidden] == [.item(separator)])
    }

    // Left out: stays in its section, after the icons the layout put there.
    @Test func leftOutIconsStayInTheirSection() throws {
        let result = try plan(#"{"format":1,"sections":[{"section":"hidden","items":[{"id":"bundle:app.fif7y.Snib"}]}]}"#)
        #expect(result.order[.hidden] == [.item(snib), .item(tailscale), .item(separator)])
        #expect(result.order[.alwaysHidden] == [.item(stats)])
    }

    @Test func pinnedIconsNeverMove() throws {
        let result = try plan(#"{"sections":[{"section":"hidden","items":[{"id":"status:com.apple.MenuBarAgent::com.apple.menuextra.clock"}]}]}"#)
        #expect(!(result.order[.hidden] ?? []).contains(.item(clock)))
        #expect(!(result.order[.visible] ?? []).contains(.item(clock)))
        #expect(result.missing.isEmpty)
    }

    // Another Mac's separator is made here; another Mac's app is reported.
    @Test func separatorsTravelAppsAreReported() throws {
        let result = try plan(#"{"sections":[{"section":"hidden","items":[{"id":"bundle:com.example.gone","name":"Gone"},{"id":"status:app.fif7y.Pelmet::Pelmet.Separator.Z","kind":"separator","name":"Separator"},{"name":"Snib"}]}]}"#)
        // This bar's own separator, which the layout doesn't name, stands in.
        #expect(result.order[.hidden]?.prefix(2) == [.item(separator), .item(snib)])
        #expect(result.newSeparators == 0)
        #expect(result.missing.map(\.label) == ["Gone"])
    }

    // Two separators from elsewhere, one spare here: one is made. Run again
    // on the bar that made it, none is.
    @Test func separatorsAreMadeOnlyWhenNoneIsSpare() throws {
        let two = #"{"sections":[{"section":"hidden","items":[{"id":"status:app.fif7y.Pelmet::Pelmet.Separator.Y","kind":"separator"},{"name":"Snib"},{"id":"status:app.fif7y.Pelmet::Pelmet.Separator.Z","kind":"separator"}]}]}"#
        let first = try plan(two)
        #expect(first.order[.hidden]?.prefix(3) == [.item(separator), .item(snib), .newSeparator])
        var after = board
        after[.hidden]?.append(.init(key: ItemID.status(bundle: PelmetBundle.fallbackID, title: "Pelmet.Separator.NEW"), name: "Separator"))
        let again = LayoutRestore.plan(try LayoutRestore.read(two), board: after, movable: { $0 != clock })
        #expect(again.newSeparators == 0)
    }

    // A separator this bar has, named by id, is never taken as a spare.
    @Test func aNamedSeparatorIsNotSpare() throws {
        let result = try plan(#"{"sections":[{"section":"hidden","items":[{"id":"status:app.fif7y.Pelmet::Pelmet.Separator.Y","kind":"separator"}]},{"section":"alwaysHidden","items":[{"id":"status:app.fif7y.Pelmet::Pelmet.Separator.A"}]}]}"#)
        #expect(result.order[.hidden]?.first == .newSeparator)
        #expect(result.order[.alwaysHidden]?.first == .item(separator))
    }

    // A separator from elsewhere never takes one from another section.
    @Test func aSpareStaysInItsSection() throws {
        let visibleSeparator = ItemID.status(bundle: PelmetBundle.fallbackID, title: "Pelmet.Separator.V")
        let bar: [Section: [LayoutRestore.BoardItem]] = [.visible: [.init(key: visibleSeparator, name: "Separator")], .hidden: [.init(key: snib, name: "Snib")]]
        let result = LayoutRestore.plan(try LayoutRestore.read(#"{"sections":[{"section":"hidden","items":[{"id":"status:app.fif7y.Pelmet::Pelmet.Separator.Y","kind":"separator"}]}]}"#),
                                        board: bar, movable: { _ in true })
        #expect(result.order[.hidden] == [.newSeparator, .item(snib)])
        #expect(result.order[.visible] == [.item(visibleSeparator)])
    }

    // One already placed by its name is not a spare too.
    @Test func aPlacedSeparatorIsNotSpare() throws {
        let result = try plan(#"{"sections":[{"section":"hidden","items":[{"name":"Separator"},{"id":"status:app.fif7y.Pelmet::Pelmet.Separator.Y","kind":"separator"}]}]}"#)
        #expect(result.order[.hidden]?.prefix(2) == [.item(separator), .newSeparator])
    }

    @Test func newSeparatorsAreCapped() throws {
        let many = (0..<30).map { #"{"id":"status:app.fif7y.Pelmet::Pelmet.Separator.X\#($0)","kind":"separator"}"# }.joined(separator: ",")
        let result = try plan(#"{"sections":[{"section":"hidden","items":["# + many + "]}]}")
        // One spare taken, then twenty made, the rest reported.
        #expect(result.newSeparators == LayoutRestore.maxNewSeparators)
        #expect(result.missing.count == 30 - 1 - LayoutRestore.maxNewSeparators)
    }

    // Two icons of a name: the name alone names neither.
    @Test func anAmbiguousNameIsReported() throws {
        var twoSnibs = board
        twoSnibs[.alwaysHidden]?.append(.init(key: ItemID(rawValue: "bundle:com.other.Snib"), name: "Snib"))
        let result = LayoutRestore.plan(try LayoutRestore.read(#"{"sections":[{"section":"visible","items":[{"name":"Snib"}]}]}"#),
                                        board: twoSnibs, movable: { _ in true })
        #expect(result.missing.map(\.label) == ["Snib"])
        #expect(result.order[.visible] == [.item(wifi), .item(clock)])
    }

    @Test func listedTwiceTheFirstPlaceWins() throws {
        let result = try plan(#"{"sections":[{"section":"visible","items":[{"name":"Snib"}]},{"section":"hidden","items":[{"name":"Snib"}]}]}"#)
        #expect(result.order[.visible]?.first == .item(snib))
        #expect(!(result.order[.hidden] ?? []).contains(.item(snib)))
    }

    @Test func refusesWhatIsntALayout() {
        #expect(throws: LayoutRestore.Failure.notALayout) { try LayoutRestore.read("hello") }
        #expect(throws: LayoutRestore.Failure.notALayout) { try LayoutRestore.read(#"{"sections":[]}"#) }
        #expect(throws: LayoutRestore.Failure.notALayout) { try LayoutRestore.read(#"{"sections":[{"section":"top","items":[]}]}"#) }
        #expect(throws: LayoutRestore.Failure.newerFormat(2)) { try LayoutRestore.read(#"{"format":2,"sections":[{"section":"hidden","items":[]}]}"#) }
        let huge = "{\"sections\":[{\"section\":\"hidden\",\"items\":[" + Array(repeating: #"{"name":"x"}"#, count: 1001).joined(separator: ",") + "]}]}"
        #expect(throws: LayoutRestore.Failure.notALayout) { try LayoutRestore.read(huge) }
        #expect(throws: LayoutRestore.Failure.notALayout) { try LayoutRestore.read(String(repeating: " ", count: LayoutRestore.maxLength + 1)) }
    }

    // An item with neither id nor name is skipped, not an error.
    @Test func emptyItemsAreSkipped() throws {
        let layout = try LayoutRestore.read(#"{"sections":[{"section":"hidden","items":[{},{"id":"  "},{"name":"Snib"}]}]}"#)
        #expect(layout.sections.first?.1 == [.init(id: nil, name: "Snib")])
    }

    /// beta.8: the same layout set again, with Q's app quit (stored, not on
    /// the bar), put Q at its section's left end.
    @Test func anIconNotOnTheBarKeepsItsPlaceInTheOrder() {
        func k(_ names: String...) -> [ItemID] { names.map { ItemID(rawValue: "bundle:\($0)") } }
        // The same layout changes nothing, wherever the quit apps sit.
        #expect(LayoutRestore.laid(k("a", "b", "c"), over: k("a", "q", "b", "c"), elsewhere: []) == k("a", "q", "b", "c"))
        #expect(LayoutRestore.laid(k("a", "b"), over: k("p", "q", "a", "b"), elsewhere: []) == k("p", "q", "a", "b"))
        #expect(LayoutRestore.laid(k("a", "b"), over: k("a", "p", "q", "b"), elsewhere: []) == k("a", "p", "q", "b"))
        #expect(LayoutRestore.laid(k("a", "b"), over: k("a", "b", "q"), elsewhere: []) == k("a", "b", "q"))
        // Reordered, it follows the icon it stood after.
        #expect(LayoutRestore.laid(k("c", "b", "a"), over: k("a", "b", "q", "c"), elsewhere: []) == k("c", "b", "q", "a"))
        // That icon goes to another section: the one before it, else the front.
        #expect(LayoutRestore.laid(k("a", "c"), over: k("a", "b", "q", "c"), elsewhere: Set(k("b"))) == k("a", "q", "c"))
        #expect(LayoutRestore.laid(k("b", "c"), over: k("a", "q", "b", "c"), elsewhere: Set(k("a"))) == k("q", "b", "c"))
        // Newcomers land where the layout has them.
        #expect(LayoutRestore.laid(k("n", "a", "m", "b"), over: k("a", "q", "b"), elsewhere: []) == k("n", "a", "q", "m", "b"))
        // Nothing of this section was here before.
        #expect(LayoutRestore.laid(k("n"), over: [], elsewhere: []) == k("n"))
    }

    /// The ones macOS pins are in no layout plan (`movable`): Visible still
    /// ends with them, reordered or joined by a new icon.
    @Test func thePinnedEndOfVisibleStaysTheEnd() {
        func k(_ names: String...) -> [ItemID] { names.map { ItemID(rawValue: "bundle:\($0)") } }
        #expect(LayoutRestore.laid(k("b", "a"), over: k("a", "b", "cc", "clock"), elsewhere: []) == k("b", "a", "cc", "clock"))
        #expect(LayoutRestore.laid(k("a", "n"), over: k("a", "b", "cc", "clock"), elsewhere: Set(k("b"))) == k("a", "n", "cc", "clock"))
        #expect(LayoutRestore.laid(k("n"), over: k("cc", "clock"), elsewhere: []) == k("n", "cc", "clock"))
    }
}
