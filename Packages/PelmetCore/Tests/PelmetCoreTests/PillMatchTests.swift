import Foundation
import Testing
@testable import PelmetCore

@Suite struct PillMatchTests {
    let canadiens = PillMatch.Held(name: "Sports", text: "Canadiens 0 Devils 0", midX: 1063)
    let wizards = PillMatch.Held(name: "Sports", text: "Wizards 9 Raptors 5", midX: 1151)

    @Test func wordsDropTheNumbers() {
        #expect(PillMatch.words("Wizards 18 Raptors 15") == "wizardsraptors")
        #expect(PillMatch.words("12:03").isEmpty)
    }

    /// 2026-11-18 19:48:59: the read missed the Canadiens pill, and bar
    /// order gave the Wizards pill to the "Sports" mirror.
    @Test func aMissingGameDoesNotHandItsMirrorToTheOther() {
        let found = [PillMatch.Found(name: "Sports", text: "Wizards 11 Raptors 5", midX: 1151)]
        #expect(PillMatch.assign(found, to: [canadiens, wizards]) == [1])
    }

    @Test func theSameElementWinsOverWordsAndOrder() {
        let found = [PillMatch.Found(name: "Sports", text: "", midX: 1151, same: 1)]
        #expect(PillMatch.assign(found, to: [canadiens, wizards]) == [1])
    }

    @Test func wordsFollowAGameThatMovedLeft() {
        let found = [
            PillMatch.Found(name: "Sports", text: "Wizards 9 Raptors 5", midX: 1063),
            PillMatch.Found(name: "Sports", text: "Canadiens 0 Devils 0", midX: 1151),
        ]
        #expect(PillMatch.assign(found, to: [canadiens, wizards]) == [1, 0])
    }

    /// A pill caught with no text (the Canadiens pill between its looks)
    /// and no element in common: every pill of the name is there, so bar
    /// order decides.
    @Test func noWordsAndEveryPillThereGoesByOrder() {
        let found = [
            PillMatch.Found(name: "Sports", text: "", midX: 1100),
            PillMatch.Found(name: "Sports", text: "", midX: 1190),
        ]
        #expect(PillMatch.assign(found, to: [canadiens, wizards]) == [0, 1])
    }

    @Test func noWordsAndOneMissingGoesToTheNearest() {
        let found = [PillMatch.Found(name: "Sports", text: "", midX: 1160)]
        #expect(PillMatch.assign(found, to: [canadiens, wizards]) == [1])
    }

    @Test func aNewActivityGetsNoMirror() {
        let found = [
            PillMatch.Found(name: "Sports", text: "Canadiens 0 Devils 0", midX: 1063),
            PillMatch.Found(name: "Sports", text: "Wizards 9 Raptors 5", midX: 1151),
            PillMatch.Found(name: "Timer", text: "4:59", midX: 1240),
        ]
        #expect(PillMatch.assign(found, to: [canadiens, wizards]) == [0, 1, nil])
    }

    @Test func anotherNameNeverTakesAMirror() {
        let found = [PillMatch.Found(name: "Timer", text: "Wizards", midX: 1151, same: 1)]
        #expect(PillMatch.assign(found, to: [canadiens, wizards]) == [nil])
    }

    @Test func newKeysSkipTheOnesHeld() {
        #expect(PillMatch.newKey("Timer", taken: ["Sports"]) == "Timer")
        #expect(PillMatch.newKey("Sports", taken: ["Sports", "Sports #2"]) == "Sports #3")
        #expect(PillMatch.newKey("Sports", taken: ["Sports #2"]) == "Sports")
    }
}

@Suite struct PillSettleTests {
    let t0 = Date(timeIntervalSince1970: 1_000)
    let rest: [Double] = [1150, 76, 22, 43]
    let slid: [Double] = [1150, 76, -67, 43]

    @Test func theFirstReadIsDrawn() {
        var settle = PillSettle()
        let drawn = settle.read(rest, now: t0)
        #expect(drawn)
        #expect(!settle.moving)
    }

    @Test func aReadMidSlideWaitsForTheNextToAgree() {
        var settle = PillSettle()
        _ = settle.read(rest, now: t0)
        let r1 = settle.read(slid, now: t0.addingTimeInterval(0.25))
        #expect(!r1)
        #expect(settle.moving)
        let r2 = settle.read(rest, now: t0.addingTimeInterval(0.5))
        #expect(r2)
        #expect(!settle.moving)
    }

    @Test func aNewShapeThatHoldsIsDrawnOnTheSecondRead() {
        var settle = PillSettle()
        _ = settle.read(rest, now: t0)
        let wide: [Double] = [1150, 84, 22, 47]
        let r1 = settle.read(wide, now: t0.addingTimeInterval(0.25))
        let r2 = settle.read(wide, now: t0.addingTimeInterval(0.5))
        #expect(!r1)
        #expect(r2)
        #expect(settle.drawn == wide)
    }

    @Test func twoReadsTooCloseStillWait() {
        var settle = PillSettle()
        _ = settle.read(rest, now: t0)
        let r1 = settle.read(slid, now: t0.addingTimeInterval(0.25))
        let r2 = settle.read(slid, now: t0.addingTimeInterval(0.3))
        #expect(!r1)
        #expect(!r2)
    }

    @Test func aPillThatKeepsMovingIsDrawnAfterTheWait() {
        var settle = PillSettle()
        _ = settle.read(rest, now: t0)
        var drawn: [Bool] = []
        // Moving from the read at 0.25 s: drawn at 2.25 s, then waiting again.
        for i in 1...10 {
            drawn.append(settle.read([1150, 76, Double(i * 5), 43], now: t0.addingTimeInterval(Double(i) * 0.25)))
        }
        #expect(drawn == [false, false, false, false, false, false, false, false, true, false])
    }

    @Test func underAPointIsTheSameShape() {
        var settle = PillSettle()
        _ = settle.read(rest, now: t0)
        let r = settle.read([1150.5, 76.4, 22.3, 43], now: t0.addingTimeInterval(0.25))
        #expect(r)
    }
}
