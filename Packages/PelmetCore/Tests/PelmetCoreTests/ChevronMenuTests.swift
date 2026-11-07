import Foundation
import Testing
@testable import PelmetCore

@Suite struct ChevronMenuDrawingTests {
    private func menu(_ slots: [ChevronMenuSlot], hidden: Set<ChevronMenuEntry> = []) -> ChevronMenu {
        ChevronMenu(order: slots, hidden: hidden)
    }

    @Test func separatorTokenIsNotAnEntry() {
        #expect(ChevronMenuEntry(rawValue: ChevronMenuSlot.separatorToken) == nil)
    }

    @Test func theStandardMenuDrawsWhatShippedBeforeItCouldBeEdited() {
        #expect(ChevronMenu().drawn == [
            .entry(.search), .entry(.settings),
            .separator,
            .entry(.toggle), .entry(.showAll),
            .separator,
            .entry(.animation), .entry(.revealTarget),
            .separator,
            .entry(.quit),
        ])
    }

    @Test func anEmptiedGroupLosesItsSeparator() {
        let trimmed = menu(ChevronMenu.standardOrder, hidden: [.toggle, .showAll, .checkForUpdates, .editMenuBar])
        #expect(trimmed.drawn == [
            .entry(.search), .entry(.settings),
            .separator,
            .entry(.animation), .entry(.revealTarget),
            .separator,
            .entry(.quit),
        ])
    }

    @Test func theEditorSeesWhichSeparatorCollapses() {
        let trimmed = menu(ChevronMenu.standardOrder, hidden: [.toggle, .showAll, .checkForUpdates, .editMenuBar])
        let separators = zip(trimmed.order, trimmed.drawnFlags).filter { $0.0 == .separator }.map(\.1)
        // The first divider still parts Settings from Animation; the second
        // had the emptied group above it and goes.
        #expect(separators == [true, false, true])
    }

    @Test func twoSeparatorsInARowDrawAsOne() {
        let doubled = menu([.entry(.search), .separator, .separator, .entry(.quit)])
        #expect(doubled.drawn == [.entry(.search), .separator, .entry(.quit)])
    }

    @Test func leadingAndTrailingSeparatorsAreDropped() {
        let edged = menu([.separator, .entry(.search), .entry(.quit), .separator])
        #expect(edged.drawn == [.entry(.search), .entry(.quit)])
    }

    @Test func aMenuWithEverythingUntickedStillOpensSettingsAndQuit() {
        let bare = menu(ChevronMenu.standardOrder, hidden: Set(ChevronMenuEntry.allCases))
        #expect(bare.drawn == [.entry(.settings), .separator, .entry(.quit)])
    }

    @Test func hidingSettingsOrQuitDoesNothing() {
        let bare = menu(ChevronMenu.standardOrder, hidden: [.settings, .quit])
        #expect(bare.isHidden(.settings) == false)
        #expect(bare.isHidden(.quit) == false)
    }
}

@Suite struct ChevronMenuNormalizeTests {
    @Test func aRepeatedEntryKeepsItsFirstPlace() {
        let doubled = ChevronMenu(order: [.entry(.search), .entry(.quit), .entry(.search)], hidden: [])
        #expect(doubled.normalized().order.filter { $0 == .entry(.search) }.count == 1)
        #expect(doubled.normalized().order.first == .entry(.search))
    }

    @Test func anEntryThisBuildAddedJoinsBeforeTheLastSeparator() {
        // A blob written before `editMenuBar` existed.
        let old = ChevronMenu(order: [.entry(.search), .entry(.settings), .separator, .entry(.quit)], hidden: [])
        let order = old.normalized().order
        let separator = order.lastIndex(of: .separator)!
        let added = order.lastIndex(of: .entry(.editMenuBar))!
        #expect(added < separator)
        #expect(order.last == .entry(.quit))
    }

    @Test func anEntryAddedSinceTheBlobComesInOffWhenItShipsOff() {
        let old = ChevronMenu(order: [.entry(.search), .entry(.settings), .separator, .entry(.quit)], hidden: [])
        #expect(old.normalized().isHidden(.editMenuBar))
        // One that shipped on stays on.
        #expect(old.normalized().isHidden(.toggle) == false)
    }

    @Test func settingsAndQuitNeverStayHidden() {
        let bare = ChevronMenu(order: ChevronMenu.standardOrder, hidden: [.settings, .quit, .search])
        #expect(bare.normalized().hidden == [.search])
    }

    @Test func aRowDroppedOnAnotherTakesItsPlaceGoingDown() {
        let menu = ChevronMenu(order: [.entry(.search), .entry(.settings), .entry(.toggle), .entry(.quit)], hidden: [])
        // Search dropped on toggle sits where toggle was, toggle moves along.
        #expect(menu.moving(from: 0, to: 2).order == [.entry(.settings), .entry(.search), .entry(.toggle), .entry(.quit)])
    }

    @Test func aRowDroppedOnAnotherTakesItsPlaceGoingUp() {
        let menu = ChevronMenu(order: [.entry(.search), .entry(.settings), .entry(.toggle), .entry(.quit)], hidden: [])
        #expect(menu.moving(from: 2, to: 0).order == [.entry(.toggle), .entry(.search), .entry(.settings), .entry(.quit)])
    }

    @Test func aMoveOutsideTheOrderChangesNothing() {
        let menu = ChevronMenu()
        #expect(menu.moving(from: 0, to: 99) == menu)
        #expect(menu.moving(from: -1, to: 0) == menu)
        #expect(menu.moving(from: 2, to: 2) == menu)
    }

    @Test func anEmptyOrderFallsBackToTheStandardMenu() {
        #expect(ChevronMenu(order: [], hidden: []).normalized().order == ChevronMenu.standardOrder)
    }
}

@Suite struct ChevronMenuCodingTests {
    private func decode(_ json: String) -> ChevronMenu? {
        try? JSONDecoder().decode(ChevronMenu.self, from: Data(json.utf8))
    }

    @Test func aRoundTripKeepsTheOrderAndThePicks() throws {
        // A complete order, the shape anything stored has after normalizing:
        // the arrangement must come back exactly as the person left it.
        var edited = ChevronMenu()
        edited.order = ChevronMenu.standardOrder.reversed()
        edited.hidden = [.search, .animation]
        let data = try JSONEncoder().encode(edited)
        let back = try JSONDecoder().decode(ChevronMenu.self, from: data)
        #expect(back.order == edited.order)
        #expect(back.hidden == edited.hidden)
    }

    @Test func aBlobFromBeforeThisSettingGivesTheStandardMenu() throws {
        let back = decode("{}")
        #expect(back?.order == ChevronMenu.standardOrder)
        #expect(back?.hidden == ChevronMenu.standardHidden)
    }

    @Test func anUnknownRowIsDroppedAndTheRestSurvives() throws {
        let back = decode(#"{"order":["search","teleport","quit"],"hidden":["search"]}"#)
        #expect(back?.order.contains(.entry(.search)) == true)
        #expect(back?.order.contains(.entry(.quit)) == true)
        #expect(back?.isHidden(.search) == true)
    }

    @Test func anUnknownHiddenRowIsDroppedWithoutLosingTheOthers() throws {
        let back = decode(#"{"order":["search","settings","quit"],"hidden":["teleport","search"]}"#)
        #expect(back?.hidden.contains(.search) == true)
    }
}
