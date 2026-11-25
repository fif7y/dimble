// PointerBorrow.swift
// When a pass may take the pointer for its first drag. Pure: the app reads
// the clock and the mouse buttons (`ApplyPass.waitForIdlePointer`).

import Foundation

public enum PointerBorrow: Equatable, Sendable {
    /// Quiet for long enough and no button held: drag.
    case now
    /// Not yet: look again.
    case wait
    /// The wait ran out on a pass the user asked for: drag behind the
    /// shield, as Apply always has.
    case shielded
    /// A button is held and nobody asked for this pass, or a link or an
    /// action asked for it (`unattended`) and the wait ran out: no drag. A held,
    /// still button reads as a quiet pointer, and a drag posted into it
    /// lets go of whatever the user is holding (#159: a press-and-hold
    /// recording in another app ended a few seconds after the mic came on,
    /// when the Camera & mic item's own pass went to place it).
    case putOff

    public static func verdict(
        quietFor: TimeInterval, gap: TimeInterval, buttonDown: Bool, waitedOut: Bool, askedByUser: Bool,
        unattended: Bool = false
    ) -> PointerBorrow {
        if buttonDown, !askedByUser || (unattended && waitedOut) { return .putOff }
        if !buttonDown, quietFor >= gap { return .now }
        return waitedOut ? .shielded : .wait
    }

    /// An automatic pass (the grouper's, the order keeper's, the recording
    /// pill's) never waits and never goes shielded: it drags only when the
    /// user has been still for the gap with no button held. A held button
    /// sends no input, so the clock alone dragged into a press-and-hold
    /// (the Stop Recording pill's pass, #159, Fra's video 2026-11-19).
    public static func automaticMayDrag(quietFor: TimeInterval, gap: TimeInterval, buttonDown: Bool) -> Bool {
        !buttonDown && quietFor >= gap
    }
}
