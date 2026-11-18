import Testing
@testable import PelmetCore

@Suite struct PointerBorrowTests {
    func verdict(quiet: Double, down: Bool, waitedOut: Bool = false, asked: Bool) -> PointerBorrow {
        PointerBorrow.verdict(quietFor: quiet, gap: 1.5, buttonDown: down, waitedOut: waitedOut, askedByUser: asked)
    }

    /// #159: a button held still for 3s is a quiet pointer by the clock.
    /// A pass nobody asked for (an own item's) does not drag into it.
    @Test func aHeldButtonPutsOffAPassNobodyAskedFor() {
        #expect(verdict(quiet: 3, down: true, asked: false) == .putOff)
        #expect(verdict(quiet: 3, down: true, waitedOut: true, asked: false) == .putOff)
        #expect(verdict(quiet: 0, down: true, asked: false) == .putOff)
    }

    /// Apply waits for the button like it waits for the pointer, then goes
    /// on shielded as before.
    @Test func aHeldButtonIsNotAQuietPointerForApply() {
        #expect(verdict(quiet: 3, down: true, asked: true) == .wait)
        #expect(verdict(quiet: 3, down: true, waitedOut: true, asked: true) == .shielded)
    }

    @Test func withNoButtonHeldTheClockDecides() {
        for asked in [true, false] {
            #expect(verdict(quiet: 1.5, down: false, asked: asked) == .now)
            #expect(verdict(quiet: 0.4, down: false, asked: asked) == .wait)
            #expect(verdict(quiet: 0.4, down: false, waitedOut: true, asked: asked) == .shielded)
        }
    }
}
