import CoreGraphics
import Testing
@testable import PelmetCore

struct SectionDividerTests {
    private func rect(_ x: CGFloat, y: CGFloat = 0, width: CGFloat = 24) -> CGRect {
        CGRect(x: x, y: y, width: width, height: 24)
    }

    @Test func separatesAlwaysHiddenFromHidden() {
        let frame = MenuBarGeometry.alwaysHiddenDivider(items: [
            (.visible, rect(20)), (.alwaysHidden, rect(44)),
            (.alwaysHidden, rect(68)), (.hidden, rect(96)), (.visible, rect(120)),
        ])
        #expect(frame == CGRect(x: 93, y: 6, width: 2, height: 12))
    }

    // Gab's bar, 2026-11-14: a 26pt slot holding a 23pt battery next to a
    // 38pt slot holding a 14pt glyph. Centred on the slot edge the line sat
    // 5pt from one icon and 16pt from the other.
    @Test func lopsidedSlotsCentreOnTheIconsNotTheSlotEdge() {
        let frame = MenuBarGeometry.alwaysHiddenDivider(items: [
            (.alwaysHidden, rect(1414, width: 26)), (.hidden, rect(1448, width: 38)),
        ])
        #expect(frame?.midX == 1447)
    }

    // However lopsided, the line never lands on top of an icon's slot.
    @Test func theLineStaysInTheGapBetweenTheSlots() {
        let narrowThenWide = MenuBarGeometry.alwaysHiddenDivider(items: [
            (.alwaysHidden, rect(0, width: 4)), (.hidden, rect(8, width: 100)),
        ])
        #expect(narrowThenWide?.midX == 8)
        let wideThenNarrow = MenuBarGeometry.alwaysHiddenDivider(items: [
            (.alwaysHidden, rect(0, width: 100)), (.hidden, rect(104, width: 4)),
        ])
        #expect(wideThenNarrow?.midX == 100)
    }

    @Test func separatesFromVisibleWhenHiddenIsEmpty() {
        #expect(MenuBarGeometry.alwaysHiddenDivider(items: [
            (.alwaysHidden, rect(44)), (.visible, rect(68)),
        ]) == CGRect(x: 67, y: 6, width: 2, height: 12))
    }

    @Test func noOrSingleSectionHasNoDivider() {
        #expect(MenuBarGeometry.alwaysHiddenDivider(items: []) == nil)
        #expect(MenuBarGeometry.alwaysHiddenDivider(items: [(.hidden, rect(44)), (.visible, rect(68))]) == nil)
        #expect(MenuBarGeometry.alwaysHiddenDivider(items: [(.alwaysHidden, rect(44)), (.alwaysHidden, rect(68))]) == nil)
        #expect(MenuBarGeometry.alwaysHiddenDivider(items: [(.visible, rect(20)), (.alwaysHidden, rect(44))]) == nil)
    }

    @Test func unsortedSecondaryDisplayFramesKeepTheirOrigin() {
        #expect(MenuBarGeometry.alwaysHiddenDivider(items: [
            (.hidden, rect(-100, y: -200)), (.alwaysHidden, rect(-124, y: -200)),
        ]) == CGRect(x: -101, y: -194, width: 2, height: 12))
    }

    @Test func toleratesAXPaddingButNotOverflowCopies() {
        #expect(MenuBarGeometry.alwaysHiddenDivider(items: [(.alwaysHidden, rect(44)), (.hidden, rect(66))]) != nil)
        #expect(MenuBarGeometry.alwaysHiddenDivider(items: [(.alwaysHidden, rect(44)), (.hidden, rect(48))]) == nil)
    }

    @Test func rejectsGapsAndDifferentBands() {
        #expect(MenuBarGeometry.alwaysHiddenDivider(items: [(.alwaysHidden, rect(44)), (.hidden, rect(100))]) == nil)
        #expect(MenuBarGeometry.alwaysHiddenDivider(items: [(.alwaysHidden, rect(44)), (.hidden, rect(68, y: 30))]) == nil)
    }

    @Test func displayLeftOfPrimaryKeepsItsNegativeOrigin() {
        // A display left of the built-in runs from x = -1728 to 0.
        #expect(MenuBarGeometry.alwaysHiddenDivider(items: [
            (.alwaysHidden, rect(-1700)), (.hidden, rect(-1672)), (.visible, rect(-1644)),
        ]) == CGRect(x: -1675, y: 6, width: 2, height: 12))
    }

    @Test func overflowTrappedPairHasNoDivider() {
        // Items the native « has trapped report stacked frames, not a 24pt run.
        #expect(MenuBarGeometry.alwaysHiddenDivider(items: [
            (.alwaysHidden, rect(1400)), (.hidden, rect(1400)),
        ]) == nil)
        #expect(MenuBarGeometry.alwaysHiddenDivider(items: [
            (.alwaysHidden, rect(1400)), (.hidden, rect(1412)),
        ]) == nil)
        // The same pair out on the bar is a boundary.
        #expect(MenuBarGeometry.alwaysHiddenDivider(items: [
            (.alwaysHidden, rect(1400)), (.hidden, rect(1424)),
        ]) == CGRect(x: 1423, y: 6, width: 2, height: 12))
    }

    @Test func ignoresZeroWidthItems() {
        #expect(MenuBarGeometry.alwaysHiddenDivider(items: [
            (.alwaysHidden, rect(44, width: 0)), (.hidden, rect(68)),
        ]) == nil)
    }
}
