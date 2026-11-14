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

    @Test func ignoresZeroWidthItems() {
        #expect(MenuBarGeometry.alwaysHiddenDivider(items: [
            (.alwaysHidden, rect(44, width: 0)), (.hidden, rect(68)),
        ]) == nil)
    }
}
