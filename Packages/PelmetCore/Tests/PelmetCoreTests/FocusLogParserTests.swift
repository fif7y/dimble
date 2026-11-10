// FocusLogParserTests.swift
// Fixtures are real donotdisturbd lines from macOS 27 (2026-09-16), cut at
// os_log's 1 KB cap exactly as the log hands them out — the previous state
// is what gets truncated, the active one must still read.

import Testing
@testable import PelmetCore

struct FocusLogParserTests {
    static let on = "Did receive state update, will handle; stateUpdate=<DNDStateUpdate: 0x7733529bf0; reason: user action; source: local; options: <none>; state: <DNDState: 0x773619d080; suppressionState: while UI locked; startDate: 2026-09-17 00:43:05 +0000; userVisibleTransitionDate: 4001-01-01 00:00:00 +0000; userVisibleTransitionLifetimeType: schedule; activeModeConfiguration: <DNDMutableModeConfiguration: 0x7732851700; mode: <DNDMode: 0x7734d2d0e0; name: Do Not Disturb; modeIdentifier: com.apple.donotdisturb.mode.default; symbolImageName: moon.fill; tintColorName: systemIndigoColor; symbolDescriptor: (null); semanticType: 0; visibility: 0; identifier: 17F98D64-A2D2-4178-A928-224C3ACCE520; isPlaceHolder: NO>; impactsAvailability: enabled; dimsLockScreen: default>; activeModeIdentifier: com.apple.donotdisturb.mode.default>; previousState: <DNDState: 0x77352adf80; suppressionState: inactive; startDate: 2026-09-16 20:32:37 +0000; userVisibleTransitionDate: 4001-01-01 00:00:00 +0000; userVisibleTransitionLifetimeType: none; activeModeConfiguration: (null); activeModeIde"
    static let off = "Did receive state update, will handle; stateUpdate=<DNDStateUpdate: 0x773364e2b0; reason: user action; source: local; options: <none>; state: <DNDState: 0x773619d980; suppressionState: inactive; startDate: 2026-09-17 00:48:30 +0000; userVisibleTransitionDate: 4001-01-01 00:00:00 +0000; userVisibleTransitionLifetimeType: none; activeModeConfiguration: (null); activeModeIdentifier: (null)>; previousState: <DNDState: 0x773619da40; suppressionState: while UI locked; startDate: 2026-09-17 00:43:05 +0000; userVisibleTransitionDate: 4001-01-01 00:00:00 +0000; userVisibleTransitionLifetimeType: schedule; activeModeConfiguration: <DNDMutableModeConfiguration: 0x7732853780; mode: <DNDMode: 0x7734d2e0d0; name: Do Not Disturb; modeIdentifier: com.apple.donotdisturb.mode.default; symbolImageName: moon.fill; tintColorName: systemIndigoColor; symbolDescriptor: (null); semanticType: 0; visibility: 0; identifier: 17F98D64-A2D2-4178-A928-224C3ACCE520; isPlaceHolder: NO>; impactsAvailability: enabled; dimsLockScreen: default>; activeModeIdentifier: com.apple.donotdistu"

    @Test func onReadsTheActiveModeNotThePreviousOne() {
        #expect(FocusLogParser.activeMode(in: Self.on) == FocusMode(
            identifier: "com.apple.donotdisturb.mode.default",
            name: "Do Not Disturb",
            symbol: "moon.fill"
        ))
    }

    @Test func offReadsNoModeEvenThoughThePreviousStateNamesOne() {
        #expect(Self.off.contains("moon.fill"))
        #expect(FocusLogParser.activeMode(in: Self.off) == nil)
    }

    @Test func customModeWithoutSymbolFallsBackToTheMoon() {
        let line = "Did receive state update, will handle; stateUpdate=<DNDStateUpdate: 0x1; state: <DNDState: 0x2; activeModeConfiguration: <DNDMutableModeConfiguration: 0x3; mode: <DNDMode: 0x4; name: Deep Work; modeIdentifier: 5E1F; symbolDescriptor: (null)>>; activeModeIdentifier: 5E1F>; previousState: <DNDState: 0x6; activeModeIdentifier: (null)>>"
        #expect(FocusLogParser.activeMode(in: line) == FocusMode(identifier: "5E1F", name: "Deep Work", symbol: "moon.fill"))
    }

    // Snapshot messages as `log stream --style ndjson` hands them out (2026-09-29)
    static let snapshotOff = "Calculate DND state for snapshot: activeAssertionUUIDs=(\n)"
    static let snapshotOn = "Calculate DND state for snapshot: activeAssertionUUIDs=(\n    \"BB22EB4E-8C73-4F6D-84A7-9E1A4C75FC39\"\n)"

    @Test func anEmptySnapshotReadsOff() {
        #expect(FocusLogParser.snapshotSaysOff(Self.snapshotOff))
    }

    @Test func aSnapshotNamingAnAssertionLeavesTheStateToTheUpdate() {
        #expect(!FocusLogParser.snapshotSaysOff(Self.snapshotOn))
        #expect(FocusLogParser.activeMode(in: Self.snapshotOn) == nil)
    }

    @Test func aStateUpdateIsNotASnapshot() {
        #expect(!FocusLogParser.snapshotSaysOff(Self.off))
        #expect(!FocusLogParser.snapshotSaysOff(Self.on))
    }

    @Test func aLineCutBeforeActiveModeIdentifierStillReadsTheModeBlock() {
        let cut = String(Self.on.prefix(upTo: Self.on.range(of: "; activeModeIdentifier:")!.lowerBound))
        #expect(FocusLogParser.activeMode(in: cut)?.identifier == "com.apple.donotdisturb.mode.default")
    }

    // MARK: The boot read (#92)
    //
    // Real lines from Gab's 2026-11-05 boot into an already-active Sleep
    // schedule: donotdisturbd wrote three held snapshots at daemon start and
    // no state update at all. The first update came at 00:00:15, when the
    // schedule rolled to a new assertion.

    static let sleep = "Did receive state update, will handle; stateUpdate=<DNDStateUpdate: 0x7a7bbce3d0; reason: automation; source: cloud; options: <none>; state: <DNDState: 0x7a79338080; suppressionState: while UI locked; startDate: 2026-11-06 05:00:02 +0000; userVisibleTransitionDate: 2026-11-06 12:00:00 +0000; userVisibleTransitionLifetimeType: none; activeModeConfiguration: <DNDMutableModeConfiguration: 0x7a7b0fff00; mode: <DNDMode: 0x7a7c0a3750; name: Sleep; modeIdentifier: com.apple.sleep.sleep-mode; symbolImageName: bed.double.fill; tintColorName: systemIndigoColor; symbolDescriptor: (null); semanticType: 1; visibility: 0; identifier: 8FDC4FE2-BE0A-43E8-A498-A5F1B45C20AF; isPlaceHolder: NO>; impactsAvailability: disabled; dimsLockScreen: enabled>; activeModeIdentifier: com.apple.sleep.sleep-mode>; previousState: <DNDState: 0x7a793a9bc0; suppressionState: while UI locked; startDate: 2026-11-06 04:30:00 +0000; userVisibleTransitionDate: 2026-11-06 12:00:00 +0000; userVisibleTransitionLifetimeType: none; activeModeConfiguration: <DNDMutableModeConfiguration: 0x7a7c9df"
    static let heldSnapshot = "Calculate DND state for snapshot: activeAssertionUUIDs=(\n    \"9266B307-4D53-4C7C-B812-D6F1F6A248CE\"\n)"

    static let doNotDisturb = FocusMode(
        identifier: "com.apple.donotdisturb.mode.default",
        name: "Do Not Disturb",
        symbol: "moon.fill"
    )

    /// #92: the Mac starts at 09:01 into a 09:00 Do Not Disturb schedule.
    /// The newest state update in the hour is the one from before the
    /// shutdown, and it says off — the held snapshots the boot wrote after
    /// it are what say a Focus is on.
    @Test func aBootIntoAScheduledFocusTakesTheModeFromHistory() {
        let window = [Self.on, Self.off, Self.heldSnapshot, Self.heldSnapshot]
        #expect(FocusLogParser.bootRead(window) == .settled(Self.doNotDisturb))
    }

    /// The boot's own hour, on its own: a Focus is on, nothing names it, so
    /// the caller reads further back.
    @Test func heldSnapshotsAloneAreUnnamed() {
        #expect(FocusLogParser.bootRead([Self.heldSnapshot, Self.heldSnapshot, Self.heldSnapshot]) == .unnamed)
    }

    /// The wider window around that same boot, which does name it.
    @Test func theWiderWindowNamesTheHeldFocus() {
        let window = [Self.sleep, Self.heldSnapshot, Self.heldSnapshot, Self.heldSnapshot]
        #expect(FocusLogParser.bootRead(window) == .settled(FocusMode(
            identifier: "com.apple.sleep.sleep-mode",
            name: "Sleep",
            symbol: "bed.double.fill"
        )))
    }

    /// Turning a Focus off writes the update after the last held snapshot,
    /// so the update stays in charge — the snapshot must not revive it.
    @Test func aHeldSnapshotOlderThanTheUpdateDoesNotRevive() {
        #expect(FocusLogParser.bootRead([Self.on, Self.heldSnapshot, Self.off]) == .settled(nil))
    }

    /// Turning one on writes a held snapshot right after the update; the
    /// answer is the mode either way.
    @Test func turningAFocusOnReadsItThoughASnapshotFollows() {
        #expect(FocusLogParser.bootRead([Self.off, Self.on, Self.heldSnapshot]) == .settled(Self.doNotDisturb))
    }

    /// An empty snapshot is decisive on its own (#70).
    @Test func anEmptySnapshotAfterAHeldOneReadsOff() {
        #expect(FocusLogParser.bootRead([Self.on, Self.heldSnapshot, Self.snapshotOff]) == .settled(nil))
    }

    @Test func noLinesAtAllIsNothingOnRecord() {
        #expect(FocusLogParser.bootRead([]) == .nothing)
    }
}
