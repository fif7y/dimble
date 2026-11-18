import Foundation
import Testing
@testable import PelmetCore

/// #149: a click, a middle click or a shortcut that asks for sections shows
/// exactly those. It never stacks them on what was out.
@Suite struct RevealSwitchTests {
    let now = Date(timeIntervalSince1970: 1_000_000)
    typealias Sections = Set<PelmetCore.Section>
    let asks: [Sections] = [[.hidden], [.alwaysHidden], [.hidden, .alwaysHidden]]

    func revealed(_ sections: Sections, by reason: RevealReason = .statusItem) -> RehideStateMachine {
        var machine = RehideStateMachine(policy: .init(autoRehide: true, delay: 5))
        _ = machine.handle(.revealRequested(sections, reason), now: now)
        _ = machine.handle(.transitionSettled, now: now)
        return machine
    }

    /// Runs the machine to rest, answering every reveal and conceal with a
    /// settle, and returns what the engine was asked to do on the way.
    func settle(_ machine: inout RehideStateMachine, after first: [RehideEffect]) -> [RehideEffect] {
        var asked: [RehideEffect] = []
        var effects = first
        for _ in 0..<6 {
            let moves = effects.filter { if case .reveal = $0 { true } else { $0 == .conceal } }
            guard !moves.isEmpty else { break }
            asked += moves
            effects = machine.handle(.transitionSettled, now: now)
        }
        return asked
    }

    /// Every settled bar × every ask: all of it out already puts everything
    /// away, more than what is out widens in one reveal, anything else
    /// closes what is out and opens what was asked.
    @Test func everySettledBarEndsAtExactlyWhatWasAsked() {
        for out in asks {
            for ask in asks {
                var machine = revealed(out)
                let asked = settle(&machine, after: machine.handle(.toggleRequested(ask, .statusItem), now: now))
                if ask.isSubset(of: out) {
                    #expect(asked == [.conceal], "\(out) + \(ask)")
                    #expect(machine.state == .concealed, "\(out) + \(ask)")
                } else if ask.isSuperset(of: out) {
                    #expect(asked == [.reveal(ask)], "\(out) + \(ask)")
                    #expect(machine.state == .revealed(sections: ask, reason: .statusItem), "\(out) + \(ask)")
                } else {
                    #expect(asked == [.conceal, .reveal(ask)], "\(out) + \(ask)")
                    #expect(machine.state == .revealed(sections: ask, reason: .statusItem), "\(out) + \(ask)")
                }
            }
        }
    }

    @Test func aCollapsedBarOpensWhatWasAsked() {
        for ask in asks {
            var machine = RehideStateMachine()
            #expect(machine.handle(.toggleRequested(ask, .statusItem), now: now) == [.reveal(ask)])
        }
    }

    /// The pointer is on the bar after a middle click: its hover asks for
    /// Hidden, and must not bring it out beside Always Hidden.
    @Test func aHoverNeverWidensASectionThatIsOut() {
        var machine = revealed([.alwaysHidden])
        let effects = machine.handle(.revealRequested([.hidden], .hover), now: now)
        #expect(!effects.contains(.reveal([.hidden, .alwaysHidden])))
        #expect(machine.state == .revealed(sections: [.alwaysHidden], reason: .statusItem))
    }

    @Test func aHoverNeverChangesASwitchOnItsWay() {
        var machine = revealed([.hidden])
        #expect(machine.handle(.toggleRequested([.alwaysHidden], .statusItem), now: now) == [.cancelTimer, .conceal])
        // Hidden is going away, Always Hidden waits behind it.
        #expect(machine.handle(.revealRequested([.hidden], .hover), now: now) == [.none])
        #expect(machine.handle(.transitionSettled, now: now) == [.reveal([.alwaysHidden])])
        // Always Hidden is coming out.
        #expect(machine.handle(.revealRequested([.hidden], .hover), now: now) == [.none])
        _ = machine.handle(.transitionSettled, now: now)
        #expect(machine.state == .revealed(sections: [.alwaysHidden], reason: .statusItem))
    }

    /// The pointer reaches the chevron, the hover starts bringing Hidden
    /// out, the middle click lands mid-flight.
    @Test func aMiddleClickDuringAHoverRevealEndsAtAlwaysHiddenAlone() {
        var machine = RehideStateMachine(policy: .init(autoRehide: true, delay: 5))
        _ = machine.handle(.revealRequested([.hidden], .hover), now: now)
        #expect(machine.handle(.toggleRequested([.alwaysHidden], .statusItem), now: now) == [.none])
        let asked = settle(&machine, after: machine.handle(.transitionSettled, now: now))
        #expect(asked == [.conceal, .reveal([.alwaysHidden])])
        #expect(machine.state == .revealed(sections: [.alwaysHidden], reason: .statusItem))
    }

    /// Two quick middle clicks from Hidden: the second lands while Hidden is
    /// still closing. They cancel out, as they do on a settled bar.
    @Test func aRepeatPressDuringASwitchEndsCollapsed() {
        var machine = revealed([.hidden])
        _ = machine.handle(.toggleRequested([.alwaysHidden], .statusItem), now: now)
        _ = machine.handle(.toggleRequested([.alwaysHidden], .statusItem), now: now)
        let asked = settle(&machine, after: machine.handle(.transitionSettled, now: now))
        #expect(asked.isEmpty)
        #expect(machine.state == .concealed)
    }

    /// An Apply or Show in Menu Bar landing in a switch's closing half adds
    /// to the section on its way, it does not replace it.
    @Test func aRevealDuringASwitchKeepsTheSectionAskedFor() {
        for (extra, expected) in [(Sections(), Sections([.alwaysHidden])), ([.hidden], [.hidden, .alwaysHidden])] {
            var machine = revealed([.hidden])
            _ = machine.handle(.toggleRequested([.alwaysHidden], .statusItem), now: now)
            _ = machine.handle(.revealRequested(extra, extra.isEmpty ? .itemInBar : .settingsPreview), now: now)
            #expect(machine.handle(.transitionSettled, now: now) == [.reveal(expected)])
        }
    }

    /// A click on the empty bar closes whatever is out. Only the chevron, a
    /// middle click and the shortcuts switch.
    @Test func aClickOnTheEmptyBarClosesWhateverIsOut() {
        var settled = revealed([.alwaysHidden])
        #expect(settled.handle(.toggleRequested([.hidden], .click), now: now) == [.cancelTimer, .conceal])
        #expect(settled.state == .transitioning(target: .conceal, queued: nil))
        var onItsWay = RehideStateMachine()
        _ = onItsWay.handle(.revealRequested([.alwaysHidden], .statusItem), now: now)
        _ = onItsWay.handle(.toggleRequested([.hidden], .click), now: now)
        #expect(onItsWay.state == .transitioning(target: .reveal([.alwaysHidden], .statusItem), queued: .conceal))
    }

    /// A click for what is already coming out still closes it, as before.
    @Test func aToggleForWhatIsComingOutQueuesTheConceal() {
        var machine = RehideStateMachine()
        _ = machine.handle(.revealRequested([.hidden], .hover), now: now)
        _ = machine.handle(.toggleRequested([.hidden], .statusItem), now: now)
        #expect(machine.state == .transitioning(target: .reveal([.hidden], .hover), queued: .conceal))
    }

    @Test func aToggleForMoreThanWhatIsComingOutWidensAfterIt() {
        var machine = RehideStateMachine()
        _ = machine.handle(.revealRequested([.alwaysHidden], .statusItem), now: now)
        _ = machine.handle(.toggleRequested([.hidden, .alwaysHidden], .hotkey), now: now)
        let asked = settle(&machine, after: machine.handle(.transitionSettled, now: now))
        #expect(asked == [.reveal([.hidden, .alwaysHidden])])
    }

    /// A display set to always show: Hidden is the policy's, not a reveal
    /// to swap away. Switching would close it and the policy would bring
    /// it straight back.
    @Test func thePolicysHiddenStaysUnderAnAskForAlwaysHidden() {
        var machine = revealed([.hidden], by: .displayPolicy)
        #expect(machine.handle(.toggleRequested([.alwaysHidden], .statusItem), now: now)
            == [.cancelTimer, .reveal([.hidden, .alwaysHidden])])
        var onItsWay = RehideStateMachine()
        _ = onItsWay.handle(.revealRequested([.hidden], .displayPolicy), now: now)
        _ = onItsWay.handle(.toggleRequested([.alwaysHidden], .statusItem), now: now)
        let asked = settle(&onItsWay, after: onItsWay.handle(.transitionSettled, now: now))
        #expect(asked == [.reveal([.hidden, .alwaysHidden])])
    }

    /// Reveals the app asks for itself (an Apply, the editor, a double-click
    /// for everything) still add to what is out.
    @Test func aRevealRequestStillWidens() {
        for reason in [RevealReason.settingsPreview, .doubleClick, .barDrag, .displayPolicy] {
            var machine = revealed([.alwaysHidden])
            #expect(machine.handle(.revealRequested([.hidden], reason), now: now)
                == [.cancelTimer, .reveal([.hidden, .alwaysHidden])], "\(reason)")
        }
    }
}
