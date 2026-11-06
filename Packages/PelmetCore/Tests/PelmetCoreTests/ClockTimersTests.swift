// ClockTimersTests.swift
// Fixtures follow mobiletimerd's `Timers` lines from macOS 27.2 (2026-10-29,
// a 2 min Clock timer paused, resumed, rung and dismissed, and one
// cancelled), ids and times as logged.

import Foundation
import Testing
@testable import PelmetCore

struct ClockTimersTests {
    static let id = "8F6CFB89-63D1-41E7-88F7-9181C0D61EB8"
    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    /// The start, verbatim.
    static let added = "<MTTimerDurationManager: 0x782b0a4c80> didAddTimers (\n    \"<MTMutableTimer:0x782b2004d0 TimerID: 8F6CFB89-63D1-41E7-88F7-9181C0D61EB8, Title: , state:Running, duration:120, firedDate: (null), dismissedDate: (null), sound: <MTSound:0x782b24de00 toneID: system:Radial, mediaItemID: (null), vibeID: (null), volume: (null), siriContext: (null)>, timerContext: (null)>\"\n)"

    /// The ring, verbatim.
    static let rang = "<MTTimerDurationManager: 0x782b0a4c80> didUpdateTimers fromTimers: (\n    \"<MTMutableTimer:0x782b2004d0 TimerID: 8F6CFB89-63D1-41E7-88F7-9181C0D61EB8, Title: , state:Running, duration:120, firedDate: (null), dismissedDate: (null), sound: <MTSound:0x782b24c5a0 toneID: system:Radial, mediaItemID: (null), vibeID: (null), volume: (null), siriContext: (null)>, timerContext: (null)>\"\n) toTimers: (\n    \"<MTMutableTimer:0x782b200690 TimerID: 8F6CFB89-63D1-41E7-88F7-9181C0D61EB8, Title: , state:Stopped, duration:120, firedDate: 2026-10-29 14:31:08 +0000, dismissedDate: (null), sound: <MTSound:0x782b24c5a0 toneID: system:Radial, mediaItemID: (null), vibeID: (null), volume: (null), siriContext: (null)>, timerContext: (null)>\"\n)"

    /// usernoted on a banner answer, verbatim (a ring at 08:32 whose
    /// mobiletimerd never logged a dismissedDate).
    static let answered = "Remove record from response action: <NotificationRecord app:\"com.apple.clock\" ident:\"197F-8AE5\" req:\"8F6CFB89-63D1-41E7-88F7-9181C0D61EB8\" uuid:\"3191D916\" source:\"8BC0B5EA\" alertStyle:\"alert\" category:\"MTTimerCategory\" defaultActionURL:\"clock-timer:default\" dismissAfterDefaultAction:true <response action: contents actIdent:  foreground: true text: nil> >"

    /// A change from `from` to `to`, shaped like the logged ones.
    static func update(_ id: String = id, from: String, to: String, fired: String = "(null)", dismissed: String = "(null)") -> String {
        func timer(_ state: String, _ fired: String, _ dismissed: String) -> String {
            "    \"<MTMutableTimer:0x782b200850 TimerID: \(id), Title: , state:\(state), duration:120, firedDate: \(fired), dismissedDate: \(dismissed), sound: <MTSound:0x782b24d770 toneID: system:Radial, mediaItemID: (null), vibeID: (null), volume: (null), siriContext: (null)>, timerContext: (null)>\"\n"
        }
        return "<MTTimerDurationManager: 0x782b0a4c80> didUpdateTimers fromTimers: (\n" + timer(from, "(null)", "(null)")
            + ") toTimers: (\n" + timer(to, fired, dismissed) + ")"
    }

    @Test func aStartEndsItsDurationLater() {
        var clock = ClockTimers()
        let changed = clock.read(Self.added, at: Self.t0)
        #expect(changed)
        #expect(clock.current == .running(ends: Self.t0.addingTimeInterval(120)))
    }

    @Test func aPauseKeepsWhatWasLeftAndAResumeEndsThatMuchLater() {
        var clock = ClockTimers()
        clock.read(Self.added, at: Self.t0)
        clock.read(Self.update(from: "Running", to: "Paused"), at: Self.t0.addingTimeInterval(20))
        #expect(clock.current == .paused(left: 100))
        clock.read(Self.update(from: "Paused", to: "Running"), at: Self.t0.addingTimeInterval(26))
        #expect(clock.current == .running(ends: Self.t0.addingTimeInterval(126)))
    }

    @Test func itRingsThenADismissEndsIt() {
        var clock = ClockTimers()
        clock.read(Self.added, at: Self.t0)
        clock.read(Self.rang, at: Self.t0.addingTimeInterval(120))
        #expect(clock.current == .rang)
        let dismissed = clock.read(Self.update(from: "Stopped", to: "Stopped",
                                               fired: "2026-10-29 14:31:08 +0000", dismissed: "2026-10-29 14:31:14 +0000"),
                                   at: Self.t0.addingTimeInterval(126))
        #expect(dismissed)
        #expect(clock.current == nil)
    }

    @Test func aRingAnsweredFromItsBannerEndsIt() {
        var clock = ClockTimers()
        clock.read(Self.added, at: Self.t0)
        clock.read(Self.rang, at: Self.t0.addingTimeInterval(120))
        let answered = clock.read(Self.answered, at: Self.t0.addingTimeInterval(1500))
        #expect(answered)
        #expect(clock.current == nil)
    }

    @Test func aNewStartEndsAnOldRing() {
        var clock = ClockTimers()
        clock.read(Self.added, at: Self.t0)
        clock.read(Self.rang, at: Self.t0.addingTimeInterval(120))
        let other = "93DD29CC-038D-4109-8A1C-22C855019D8D"
        clock.read(Self.added.replacingOccurrences(of: Self.id, with: other), at: Self.t0.addingTimeInterval(1500))
        #expect(clock.current == .running(ends: Self.t0.addingTimeInterval(1620)))
    }

    @Test func aCancelEndsIt() {
        var clock = ClockTimers()
        clock.read(Self.added, at: Self.t0)
        clock.read(Self.update(from: "Running", to: "Stopped"), at: Self.t0.addingTimeInterval(10))
        #expect(clock.current == nil)
    }

    @Test func presetsAndTimersStartedBeforeTheWindowAreNotFollowed() {
        var clock = ClockTimers()
        let preset = clock.read(Self.update("E597CBFF-0000-4000-8000-000000000000", from: "Stopped", to: "Stopped"), at: Self.t0)
        let unknown = clock.read(Self.update(from: "Paused", to: "Running"), at: Self.t0)
        #expect([preset, unknown] == [false, false])
        #expect(clock.current == nil)
    }

    @Test func theBarShowsARingFirstThenTheOneEndingFirst() {
        var clock = ClockTimers()
        let other = "93DD29CC-038D-4109-8A1C-22C855019D8D"
        clock.read(Self.added, at: Self.t0)
        clock.read(Self.added.replacingOccurrences(of: Self.id, with: other), at: Self.t0.addingTimeInterval(-60))
        #expect(clock.current == .running(ends: Self.t0.addingTimeInterval(60)))
        clock.read(Self.rang, at: Self.t0.addingTimeInterval(120))
        #expect(clock.current == .rang)
    }

    @Test func aTimerWhoseEndNeverCameIsGivenUpOn() {
        var clock = ClockTimers()
        clock.read(Self.added, at: Self.t0)
        let ends = Self.t0.addingTimeInterval(120)
        #expect(clock.nextExpiry == ends.addingTimeInterval(ClockTimers.overdue))
        let early = clock.expire(now: ends.addingTimeInterval(ClockTimers.overdue - 1))
        #expect(!early)
        let due = clock.expire(now: ends.addingTimeInterval(ClockTimers.overdue))
        #expect(due)
        #expect(clock.current == nil)
        #expect(clock.nextExpiry == nil)
    }

    @Test func aLostEndDoesNotHoldTheNextTimerAtZero() {
        var clock = ClockTimers()
        clock.read(Self.added, at: Self.t0)
        let other = "93DD29CC-038D-4109-8A1C-22C855019D8D"
        let later = Self.t0.addingTimeInterval(3600)
        clock.read(Self.added.replacingOccurrences(of: Self.id, with: other), at: later)
        clock.expire(now: later)
        #expect(clock.current == .running(ends: later.addingTimeInterval(120)))
    }

    @Test func aRingJustAfterGivingUpStillRings() {
        var clock = ClockTimers()
        clock.read(Self.added, at: Self.t0)
        let wake = Self.t0.addingTimeInterval(3600)
        clock.expire(now: wake)
        #expect(clock.current == nil)
        clock.read(Self.rang, at: wake)
        #expect(clock.current == .rang)
    }

    @Test func aRingNobodyAnsweredIsGivenUpOn() {
        var clock = ClockTimers()
        clock.read(Self.added, at: Self.t0)
        let rang = Self.t0.addingTimeInterval(120)
        clock.read(Self.rang, at: rang)
        let early = clock.expire(now: rang.addingTimeInterval(ClockTimers.ringLimit - 1))
        #expect(!early)
        #expect(clock.current == .rang)
        let due = clock.expire(now: rang.addingTimeInterval(ClockTimers.ringLimit))
        #expect(due)
        #expect(clock.current == nil)
    }

    @Test func aPausedTimerHasNoBound() {
        var clock = ClockTimers()
        clock.read(Self.added, at: Self.t0)
        clock.read(Self.update(from: "Running", to: "Paused"), at: Self.t0.addingTimeInterval(20))
        #expect(clock.nextExpiry == nil)
        let gone = clock.expire(now: Self.t0.addingTimeInterval(7 * 24 * 3600))
        #expect(!gone)
    }
}
