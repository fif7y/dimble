import Foundation
import Testing
@testable import PelmetCore

@Suite struct PillsOffStandDownTests {
    let down = PillsOffStandDown(count: 1, seen: ["System & App Protection Override"])

    @Test func everyPillOffStandsDown() {
        #expect(PillsOffStandDown.everyPillOff([(off: true, system: false)]))
        #expect(PillsOffStandDown.everyPillOff([(off: true, system: false), (off: true, system: false)]))
    }

    @Test func onePillOnKeepsLiveMode() {
        #expect(!PillsOffStandDown.everyPillOff([(off: true, system: false), (off: false, system: false)]))
    }

    @Test func noPillDrawnIsNotAllOff() {
        // A pill not read yet must not end live mode.
        #expect(!PillsOffStandDown.everyPillOff([]))
    }

    @Test func macOSsOwnPillKeepsLiveMode() {
        #expect(!PillsOffStandDown.everyPillOff([(off: true, system: false), (off: false, system: true)]))
    }

    @Test func anotherActivityEndsIt() {
        #expect(down.after(running: true, count: 2) == nil)
    }

    @Test func nothingRunningEndsIt() {
        #expect(down.after(running: false, count: 0) == nil)
    }

    @Test func oneEndingKeepsItDown() {
        let two = PillsOffStandDown(count: 2, seen: down.seen)
        #expect(two.after(running: true, count: 1) == PillsOffStandDown(count: 1, seen: down.seen))
        #expect(down.after(running: true, count: 1) == down)
    }

    @Test func aPillThatWasUpTurnedBackOnEndsIt() {
        #expect(down.after(hidden: ["Now Playing"]) == nil)
        #expect(down.after(hidden: []) == nil)
    }

    @Test func aPillNotRunningTurnedOnKeepsItDown() {
        // Now Playing was off but not up: turning it on draws nothing
        // (18:57:04, 2026-11-18: live mode filmed the bar and left 1.2s later).
        let wasOff: Set<String> = ["System & App Protection Override", "Now Playing"]
        #expect(down.after(hidden: wasOff) == down)
        #expect(down.after(hidden: ["System & App Protection Override"]) == down)
    }

    @Test func anotherPillTurnedOffKeepsItDown() {
        #expect(down.after(hidden: ["System & App Protection Override", "Now Playing"]) == down)
    }

    // MARK: Clock

    let t0 = Date(timeIntervalSinceReferenceDate: 1_000)

    @Test func clockWaitsTheWholeGrace() {
        var clock = PillsOffStandDown.Clock()
        let r1 = clock.due(allOff: true, now: t0, grace: 10)
        #expect(!r1)
        let r2 = clock.due(allOff: true, now: t0 + 9.9, grace: 10)
        #expect(!r2)
        let r3 = clock.due(allOff: true, now: t0 + 10, grace: 10)
        #expect(r3)
    }

    @Test func aPillOnStartsTheClockOver() {
        // The new activity's pill landed, then went: the wait counts again
        // from the next look that finds them all off.
        var clock = PillsOffStandDown.Clock()
        _ = clock.due(allOff: true, now: t0, grace: 10)
        let r4 = clock.due(allOff: false, now: t0 + 5, grace: 10)
        #expect(!r4)
        let r5 = clock.due(allOff: true, now: t0 + 11, grace: 10)
        #expect(!r5)
        let r6 = clock.due(allOff: true, now: t0 + 21, grace: 10)
        #expect(r6)
    }

    @Test func aResetStartsTheClockOver() {
        // An activity started (the count moved): its pill gets the grace.
        var clock = PillsOffStandDown.Clock()
        _ = clock.due(allOff: true, now: t0, grace: 10)
        clock.reset()
        let r7 = clock.due(allOff: true, now: t0 + 12, grace: 10)
        #expect(!r7)
        let r8 = clock.due(allOff: true, now: t0 + 22, grace: 10)
        #expect(r8)
    }
}
