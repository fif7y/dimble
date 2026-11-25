// SingleInstanceTests.swift

import Testing
@testable import PelmetCore

struct SingleInstanceTests {
    private func copy(_ pid: Int32, _ startedAt: Double) -> SingleInstance.Copy { .init(pid: pid, startedAt: startedAt) }

    @Test func aloneItStarts() {
        #expect(SingleInstance.verdict(me: copy(10, 1), others: []) == .start)
        #expect(SingleInstance.verdict(me: copy(10, 1), others: [copy(10, 1)]) == .start)
    }

    /// 2026-11-24 21:47:11, a build swap: MenuBarAgent brought the copy that
    /// had just quit back as 68527, `open` started 68528 24 ms later.
    @Test func theCopyOpenedOnPurposeReplacesTheOneTheAgentBroughtBack() {
        let agents = copy(68527, 11.579), opened = copy(68528, 11.603)
        #expect(SingleInstance.verdict(me: opened, others: [agents]) == .takeOver([68527]))
        #expect(SingleInstance.verdict(me: agents, others: [opened]) == .yield(to: 68528))
    }

    /// Same start time, or pids that wrapped: exactly one of them stays.
    @Test func everyPairKeepsExactlyOne() {
        let copies = [copy(5, 2), copy(99998, 2), copy(7, 3), copy(99999, 1)]
        for a in copies {
            for b in copies where b != a {
                let kept = [SingleInstance.verdict(me: a, others: [b]), SingleInstance.verdict(me: b, others: [a])]
                #expect(kept.filter { if case .yield = $0 { true } else { false } }.count == 1)
            }
        }
    }

    @Test func amongThreeOnlyTheLastStays() {
        let one = copy(1, 1), two = copy(2, 2), three = copy(3, 3)
        #expect(SingleInstance.verdict(me: three, others: [two, one]) == .takeOver([1, 2]))
        #expect(SingleInstance.verdict(me: two, others: [one, three]) == .yield(to: 3))
        #expect(SingleInstance.verdict(me: one, others: [two, three]) == .yield(to: 3))
    }
}
