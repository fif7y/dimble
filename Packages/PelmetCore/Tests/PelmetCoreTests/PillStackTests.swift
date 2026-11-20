import Foundation
import Testing
@testable import PelmetCore

@Suite struct PillStackTests {
    /// 2026-11-20 08:14:30.977, the built-in's bar window `d1W0`: three
    /// Shortcuts elements stacked at 1043 (two departed, #95 new) and the
    /// right pill at 1105. The bar showed 2; live mode mirrored 4.
    @Test func aSwapStackIsOnePill() {
        let bar = [PillStack.Copy(minX: 1043, width: 46, held: true),   // #83, departed
                   PillStack.Copy(minX: 1043, width: 46, held: false),  // #95, the new one
                   PillStack.Copy(minX: 1043, width: 46, held: true),   // #91, departed
                   PillStack.Copy(minX: 1105, width: 46, held: true)]   // #84
        #expect(PillStack.keep(bar) == [1, 3])
    }

    @Test func aStackOfHeldCopiesKeepsTheFirst() {
        let bar = [PillStack.Copy(minX: 1043, width: 46, held: true),
                   PillStack.Copy(minX: 1043.5, width: 46, held: true)]
        #expect(PillStack.keep(bar) == [0])
    }

    /// Two games of one app: same name, same identifier, two slots.
    @Test func twoPillsSideBySideStayTwo() {
        let bar = [PillStack.Copy(minX: 1035, width: 68), PillStack.Copy(minX: 1117, width: 68)]
        #expect(PillStack.keep(bar) == [0, 1])
    }

    /// 08:15:01.900: a pill sliding into the slot an ended one left is 11 pt
    /// off it for a frame or two. Both are on the bar until the slide ends.
    @Test func aSlideInProgressIsNotAStack() {
        let bar = [PillStack.Copy(minX: 1043, width: 46, held: true), PillStack.Copy(minX: 1054, width: 46, held: true)]
        #expect(PillStack.keep(bar) == [0, 1])
    }

    @Test func aDifferentShapeAtTheSameXIsNotAStack() {
        let bar = [PillStack.Copy(minX: 1043, width: 46), PillStack.Copy(minX: 1043, width: 68)]
        #expect(PillStack.keep(bar) == [0, 1])
    }

    @Test func noCopiesKeepNothing() {
        #expect(PillStack.keep([]).isEmpty)
    }
}
