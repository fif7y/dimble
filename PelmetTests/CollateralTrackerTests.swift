// CollateralTrackerTests.swift
// Locks the observed "the bar killed it" rule (#30): an item Pelmet never
// asked to conceal, whose app is still running, gone from the bar for two
// sightings ≥4s apart within one conceal episode. A quit app, a revealed
// bar, and an empty bar are all excluded.

import Foundation
import Testing
import PelmetCore
@testable import Pelmet

struct CollateralTrackerTests {
    let istat = ItemID(rawValue: "status:com.bjango.istatmenus.status::CPU").sectionKey
    let maccy = ItemID(rawValue: "status:org.p0deje.Maccy::Item-0").sectionKey
    let drive = "com.google.drivefs"
    let t0 = Date(timeIntervalSince1970: 1_000)

    /// Everything runs unless a test says otherwise.
    let allRunning: (String) -> Bool = { _ in true }

    @Test func confirmsAnAllowedItemThatLeftTheBarAndClearsWhenItReturns() {
        var tracker = CollateralTracker()
        // Both live: iStat is known to the tracker from here on.
        tracker.observe(live: [istat, maccy], concealing: [drive], running: allRunning, at: t0)
        #expect(tracker.confirmed.isEmpty)
        // iStat gone, never concealed by Pelmet, app still up.
        tracker.observe(live: [maccy], concealing: [drive], running: allRunning, at: t0.addingTimeInterval(1))
        #expect(tracker.confirmed.isEmpty)
        tracker.observe(live: [maccy], concealing: [drive], running: allRunning, at: t0.addingTimeInterval(6))
        #expect(tracker.confirmed == [istat])
        // Back in the bar: nothing killed it after all.
        tracker.observe(live: [istat, maccy], concealing: [drive], running: allRunning, at: t0.addingTimeInterval(9))
        #expect(tracker.confirmed.isEmpty)
    }

    @Test func pelmetsOwnConcealIsNotACasualty() {
        var tracker = CollateralTracker()
        let bundle = istat.bundleID ?? ""
        tracker.observe(live: [istat, maccy], concealing: [], running: allRunning, at: t0)
        // Now Pelmet conceals iStat itself — missing on purpose.
        tracker.observe(live: [maccy], concealing: [bundle], running: allRunning, at: t0.addingTimeInterval(1))
        tracker.observe(live: [maccy], concealing: [bundle], running: allRunning, at: t0.addingTimeInterval(20))
        #expect(tracker.confirmed.isEmpty)
    }

    @Test func aQuitAppIsNotACasualty() {
        var tracker = CollateralTracker()
        tracker.observe(live: [istat, maccy], concealing: [drive], running: allRunning, at: t0)
        let istatBundle = istat.bundleID ?? ""
        let running: (String) -> Bool = { $0 != istatBundle }
        tracker.observe(live: [maccy], concealing: [drive], running: running, at: t0.addingTimeInterval(1))
        tracker.observe(live: [maccy], concealing: [drive], running: running, at: t0.addingTimeInterval(20))
        #expect(tracker.confirmed.isEmpty)
    }

    @Test func anEmptyBarIsTheAssertionNotAMassKilling() {
        var tracker = CollateralTracker()
        tracker.observe(live: [istat, maccy], concealing: [drive], running: allRunning, at: t0)
        // Every protected item gone at once: a swap's AX latency, not a verdict.
        tracker.observe(live: [], concealing: [drive], running: allRunning, at: t0.addingTimeInterval(1))
        tracker.observe(live: [], concealing: [drive], running: allRunning, at: t0.addingTimeInterval(20))
        #expect(tracker.confirmed.isEmpty)
    }

    @Test func aRevealedBarTeachesNothingAndResetsTiming() {
        var tracker = CollateralTracker()
        tracker.observe(live: [istat, maccy], concealing: [drive], running: allRunning, at: t0)
        tracker.observe(live: [maccy], concealing: [drive], running: allRunning, at: t0.addingTimeInterval(1))
        // Nothing concealed: no assertion is hiding anything, so nothing can
        // have been killed for being hidden — and the clock restarts.
        tracker.observe(live: [maccy], concealing: [], running: allRunning, at: t0.addingTimeInterval(2))
        tracker.observe(live: [maccy], concealing: [drive], running: allRunning, at: t0.addingTimeInterval(3))
        #expect(tracker.confirmed.isEmpty)
        tracker.observe(live: [maccy], concealing: [drive], running: allRunning, at: t0.addingTimeInterval(8))
        #expect(tracker.confirmed == [istat])
    }

    @Test func anItemNeverSeenLiveIsNeverACasualty() {
        var tracker = CollateralTracker()
        // iStat is never in `live`, so the tracker has no reason to expect it.
        tracker.observe(live: [maccy], concealing: [drive], running: allRunning, at: t0)
        tracker.observe(live: [maccy], concealing: [drive], running: allRunning, at: t0.addingTimeInterval(20))
        #expect(tracker.confirmed.isEmpty)
    }

    @Test func aTornDownAssertionForgetsFirstSightingsButKeepsVerdicts() {
        var tracker = CollateralTracker()
        tracker.observe(live: [istat, maccy], concealing: [drive], running: allRunning, at: t0)
        tracker.observe(live: [maccy], concealing: [drive], running: allRunning, at: t0.addingTimeInterval(1))
        tracker.observe(live: [maccy], concealing: [drive], running: allRunning, at: t0.addingTimeInterval(6))
        #expect(tracker.confirmed == [istat])
        tracker.assertionLost()
        #expect(tracker.confirmed == [istat])
        // A fresh episode needs its own two spaced sightings to re-confirm
        // anything new, but the standing verdict is untouched.
        tracker.observe(live: [maccy], concealing: [drive], running: allRunning, at: t0.addingTimeInterval(30))
        #expect(tracker.confirmed == [istat])
    }
}

struct CollateralRowsTests {
    /// The Settings line names whichever item keeps Apple's hidden, so every
    /// one of them needs a name there.
    @Test func everyReplicaIsNamed() {
        #expect(Set(ExtraKind.collateralRows.map(\.kind)) == ExtraKind.collateralReplicas)
    }
}
