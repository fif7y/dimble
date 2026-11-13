// AppleMenuCorner.swift
// The strip between the bar's left end and the Apple menu belongs to the
// Apple menu, not to the bar's empty space. macOS has always opened that
// menu from the very corner — shove the pointer into the top left and click,
// no aiming — but the item's AX frame starts a little way in, so the corner
// hit-tests as the bare AXMenuBar backdrop, which Pelmet reads as empty bar.
// A corner click toggled a reveal under the menu macOS was opening, while a
// click on the glyph itself was already refused (#147).
//
// Measured 2026-11-13 on Gab's 1800pt built-in: the AX hit test at bar
// height returns the bare AXMenuBar for x=0...9 and the "Apple"
// AXMenuBarItem, frame (10, 0, 34, 39), from x=10 on. Only that 10pt strip
// leaked.

import CoreGraphics

public enum AppleMenuCorner {
    /// The widest leading inset still read as the Apple menu's corner. 10pt
    /// measured; the cap is what keeps a mirrored bar — a right-to-left
    /// system language puts the Apple menu at the far end — from reading as
    /// one corner the width of the bar.
    public static let maxInset: CGFloat = 40

    /// Whether a click in the band belongs to the Apple menu rather than to
    /// the bar's empty space.
    /// - pointX: where the click landed, in screen points. AX and AppKit
    ///   share the x axis, so either convention's x does.
    /// - barMinX: the left end of the AXMenuBar backdrop the click hit. The
    ///   bar under the pointer, so the answer holds on any display.
    /// - appleMinX: the left edge of that bar's leftmost item, the Apple
    ///   menu. Nil when the bar has no item to measure against, and then
    ///   nothing is claimed.
    public static func holdsClick(pointX: CGFloat, barMinX: CGFloat, appleMinX: CGFloat?) -> Bool {
        guard let appleMinX, appleMinX > barMinX, appleMinX - barMinX <= maxInset else { return false }
        return pointX >= barMinX && pointX < appleMinX
    }
}
