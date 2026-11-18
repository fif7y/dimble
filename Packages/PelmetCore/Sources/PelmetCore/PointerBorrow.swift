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
    /// A button is held and nobody asked for this pass: no drag. A held,
    /// still button reads as a quiet pointer, and a drag posted into it
    /// lets go of whatever the user is holding (#159: a press-and-hold
    /// recording in another app ended a few seconds after the mic came on,
    /// when the Camera & mic item's own pass went to place it).
    case putOff

    public static func verdict(
        quietFor: TimeInterval, gap: TimeInterval, buttonDown: Bool, waitedOut: Bool, askedByUser: Bool
    ) -> PointerBorrow {
        if buttonDown, !askedByUser { return .putOff }
        if !buttonDown, quietFor >= gap { return .now }
        return waitedOut ? .shielded : .wait
    }
}
