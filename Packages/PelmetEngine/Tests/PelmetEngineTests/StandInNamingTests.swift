import CoreGraphics
import Testing
@testable import PelmetEngine

@Suite struct StandInNamingTests {
    /// An AXMenuBar as the walk reads it.
    struct Bar {
        let width: CGFloat?
        let subroles: [String?]
        let titles: [String?]
    }

    // Bars as probed 2026-10-13 with the LG active: each app's main menu is
    // framed across the LG bar, its entries carry no subrole; a status item
    // on the extras bar is an AXMenuExtra.
    static let veljaMainMenu = Bar(
        width: 3440, subroles: Array(repeating: nil, count: 6),
        titles: ["Apple", "Velja", "Edit", "View", "Window", "Help"]
    )
    static let oneIconExtras = Bar(width: 24, subroles: ["AXMenuExtra"], titles: [nil])
    static let pelmetExtras = Bar(
        width: 48, subroles: ["AXMenuExtra", "AXMenuExtra"], titles: ["Pelmet.StatusItem", "Pelmet.Shortcuts"]
    )
    static let emptyBar = Bar(width: 0, subroles: [], titles: [])

    /// The chain `statusExtras` runs: the bar the app names, else the
    /// fallback's, else none; then what its titles say.
    func naming(explicit: Bar?, bars: [Bar]) -> ItemEnumerator.StandInNaming {
        let bar = ItemEnumerator.extrasBar(explicit: explicit, among: bars) { ($0.width, $0.subroles) }
        return ItemEnumerator.standInNaming(titles: bar.map(\.titles))
    }

    func fallback(_ bars: [(width: CGFloat?, subroles: [String?])]) -> Int? {
        ItemEnumerator.extrasBarFallback(among: bars)
    }

    // MARK: - The chain

    @Test func theBarTheAppNamesWins() {
        #expect(naming(explicit: Self.pelmetExtras, bars: [Self.veljaMainMenu, Self.oneIconExtras]) == .byPosition)
    }

    @Test func withoutItTheBarOfStatusItemsIsRead() {
        #expect(naming(explicit: nil, bars: [Self.veljaMainMenu, Self.oneIconExtras]) == .named("Item-0"))
    }

    @Test func aMainMenuAloneIsNoExtrasBar() {
        // Velja and Pure Paste: AXExtrasMenuBar with no value, the main menu
        // the only bar. Read as the extras bar, its six distinct titles
        // passed for six icons and the stand-ins went unnamed.
        #expect(naming(explicit: nil, bars: [Self.veljaMainMenu]) == .unread)
        #expect(naming(explicit: nil, bars: []) == .unread)
    }

    @Test func anEmptyBarSaysNothingOfTheIconCount() {
        #expect(naming(explicit: Self.emptyBar, bars: [Self.veljaMainMenu]) == .unread)
        #expect(naming(explicit: nil, bars: [Self.veljaMainMenu, Self.emptyBar]) == .unread)
    }

    // MARK: - The fallback

    @Test func widthNeverOutranksTheEntries() {
        // A text item can make the extras bar wider than a main menu (#17),
        // and a bar with no frame was the narrowest by default.
        #expect(fallback([(200, [nil, nil]), (300, ["AXMenuExtra"])]) == 1)
        #expect(fallback([(nil, [nil, nil]), (24, ["AXMenuExtra"])]) == 1)
    }

    @Test func theNarrowestBarOfStatusItemsWins() {
        #expect(fallback([(80, ["AXMenuExtra", "AXMenuExtra"]), (3440, [nil]), (24, ["AXMenuExtra"])]) == 2)
    }

    // MARK: - The guard

    @Test func oneIdForEveryEntryNamesEveryGroup() {
        #expect(ItemEnumerator.standInNaming(titles: ["T"]) == .named("T"))
        #expect(ItemEnumerator.standInNaming(titles: ["T", "T"]) == .named("T"))
        #expect(ItemEnumerator.standInNaming(titles: [nil, nil, nil]) == .named("Item-0"))
    }

    @Test func anUntitledEntryIsAnIdOfItsOwn() {
        // Named "T" both, the untitled icon would take T's id.
        #expect(ItemEnumerator.standInNaming(titles: ["T", nil]) == .byPosition)
        #expect(ItemEnumerator.standInNaming(titles: ["T", "U"]) == .byPosition)
    }

    // MARK: - The walk, one bar

    static func groups(_ xs: [CGFloat]) -> [CGRect] { xs.map { CGRect(x: $0, y: 0, width: 38, height: 39) } }

    @Test func withNoBarALoneGroupIsTheAppsOneIcon() {
        #expect(ItemEnumerator.standInTitles(forGroups: Self.groups([1601]), naming: .unread, items: []) == ["Item-0"])
    }

    @Test func withNoBarSeveralGroupsStayUnnamed() {
        // Pelmet's sections key on the title: one phantom Item-0 for all
        // would be an item of its own.
        #expect(ItemEnumerator.standInTitles(forGroups: Self.groups([1492, 1601]), naming: .unread, items: [])
            == [nil, nil])
    }

    @Test func byPositionAnUntitledItemIsItem0() {
        let items: [(title: String?, frame: CGRect?)] = [
            ("T", CGRect(x: 5010, y: 2, width: 24, height: 24)),
            (nil, CGRect(x: 4901, y: 2, width: 24, height: 24)),
        ]
        #expect(ItemEnumerator.standInTitles(forGroups: Self.groups([1601, 1492]), naming: .byPosition, items: items)
            == ["T", "Item-0"])
    }

    @Test func aNameNamesEveryGroup() {
        #expect(ItemEnumerator.standInTitles(forGroups: Self.groups([1, 2]), naming: .named("T"), items: []) == ["T", "T"])
    }

    // MARK: A stand-in on its app's real button

    static func entry(_ pid: pid_t, x: CGFloat, width: CGFloat = 38, y: CGFloat = 0, standIn: Bool) -> (pid: pid_t, frame: CGRect, standIn: Bool) {
        (pid, CGRect(x: x, y: y, width: width, height: 33), standIn)
    }

    /// Live log 2026-11-10: Status Trio's button and its `Item-0` stand-in
    /// at one x on the one display, read as two icons behind the «.
    @Test func aStandInOnItsAppsButtonIsTheSameIcon() {
        let walk = [
            Self.entry(10, x: 1362, standIn: false),
            Self.entry(20, x: 1300, standIn: false),
            Self.entry(10, x: 1362, standIn: true),
        ]
        #expect(ItemEnumerator.echoedStandIns(walk) == [2])
    }

    /// The button can come after its stand-in in the walk (another bar's
    /// window first).
    @Test func theOrderOfTheWalkDoesNotMatter() {
        let walk = [Self.entry(10, x: 1362, standIn: true), Self.entry(10, x: 1362.5, standIn: false)]
        #expect(ItemEnumerator.echoedStandIns(walk) == [0])
    }

    /// Another display's bar has its own origin: its stand-ins are the
    /// item's copies there, and stay.
    @Test func aStandInOnAnotherDisplaysBarStays() {
        let walk = [Self.entry(10, x: 1362, standIn: false), Self.entry(10, x: 4802, standIn: true)]
        #expect(ItemEnumerator.echoedStandIns(walk).isEmpty)
    }

    @Test func anotherAppsButtonAtThatPlaceIsNotItsOwn() {
        let walk = [Self.entry(10, x: 1362, standIn: false), Self.entry(20, x: 1362, standIn: true)]
        #expect(ItemEnumerator.echoedStandIns(walk).isEmpty)
    }

    /// Icons behind the « are buttons at one x: still two icons, for
    /// `PlacementGeometry.overflowTrapped` to find.
    @Test func twoButtonsAtOnePlaceAreLeftAlone() {
        let walk = [Self.entry(10, x: 1044, standIn: false), Self.entry(10, x: 1044, standIn: false)]
        #expect(ItemEnumerator.echoedStandIns(walk).isEmpty)
    }

    @Test func twoStandInsAtOnePlaceAreLeftAlone() {
        let walk = [Self.entry(10, x: 4802, standIn: true), Self.entry(10, x: 4802, standIn: true)]
        #expect(ItemEnumerator.echoedStandIns(walk).isEmpty)
    }

    /// An app's second icon next to its first is a neighbour, not an echo.
    @Test func aNeighbourOfTheSameAppIsNotAnEcho() {
        let walk = [Self.entry(10, x: 1362, standIn: false), Self.entry(10, x: 1324, standIn: true)]
        #expect(ItemEnumerator.echoedStandIns(walk).isEmpty)
    }
}
