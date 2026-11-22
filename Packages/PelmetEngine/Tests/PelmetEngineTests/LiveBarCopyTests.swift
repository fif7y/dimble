import Foundation
import Testing
@testable import PelmetEngine

/// Which copy of an item the walk keeps (`ItemEnumerator.prefers`): the
/// main display's, and on it the copy from the bar window with the apps'
/// real buttons, since the agent's stand-in bar on that display can lag.
@Suite struct LiveBarCopyTests {
    static let agent: pid_t = 633

    /// MenuHog run, 2026-11-21: right after the « expanded the stand-in bar,
    /// listed first, kept Snib at x1566 and the buttons' bar drew it at
    /// x1534. The buttons' copy is kept.
    @Test func theButtonsBarWinsOverTheStandInBarOnOneDisplay() {
        let standInBar = ItemEnumerator.realButtons(
            [(pid: 904, standIn: true), (pid: 926, standIn: true), (pid: Self.agent, standIn: false)], agentPID: Self.agent)
        let buttonsBar = ItemEnumerator.realButtons(
            [(pid: 904, standIn: false), (pid: 926, standIn: false), (pid: Self.agent, standIn: false)], agentPID: Self.agent)
        #expect(standInBar == 0)
        #expect(buttonsBar == 2)
        #expect(ItemEnumerator.prefers((main: true, buttons: buttonsBar), over: (main: true, buttons: standInBar)))
        #expect(!ItemEnumerator.prefers((main: true, buttons: standInBar), over: (main: true, buttons: buttonsBar)))
    }

    /// Two bars that read alike, or a bar of the agent's own items alone:
    /// the first copy stays, as before.
    @Test func aTieKeepsTheFirstCopy() {
        #expect(!ItemEnumerator.prefers((main: true, buttons: 3), over: (main: true, buttons: 3)))
        #expect(!ItemEnumerator.prefers((main: true, buttons: 0), over: (main: true, buttons: 0)))
    }

    /// #27: another display's copy never replaces the main display's, however
    /// many buttons its bar hosts, and the main display's always replaces it.
    @Test func theMainDisplaysCopyComesFirst() {
        #expect(ItemEnumerator.prefers((main: true, buttons: 0), over: (main: false, buttons: 5)))
        #expect(!ItemEnumerator.prefers((main: false, buttons: 5), over: (main: true, buttons: 0)))
    }

    /// Off the main display nothing is swapped: the walk keeps the main
    /// display's frames only, and other displays' copies go to `barCopies`.
    @Test func copiesOffTheMainDisplayAreNotWeighed() {
        #expect(!ItemEnumerator.prefers((main: false, buttons: 5), over: (main: false, buttons: 0)))
    }
}
