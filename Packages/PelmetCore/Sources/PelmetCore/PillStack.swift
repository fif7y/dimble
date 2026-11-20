// PillStack.swift
// One pill per slot of a bar. When macOS swaps which activity a slot shows
// (more activities than slots), the new pill's AX element takes the same
// frame as the old one, and MenuBarAgent's bar WINDOWS keep the old element
// listed for 1-4 s, stacked: `[#83 1043, #95 1043, #91 1043, #84 1105]`
// (2026-11-20 08:14, three displays, every bar read every 10 ms). Its
// AXMenuBar drops the old element at once, but only one display has that
// copy, so live mode on the others mirrored every stacked element as its
// own pill: 4-5 Shortcuts pills beside the « where the bar showed 2.

import Foundation

public enum PillStack {
    /// A pill copy as one bar lists it.
    public struct Copy: Equatable, Sendable {
        public var minX: Double
        public var width: Double
        /// A mirror already holds this very AX element.
        public var held: Bool
        public init(minX: Double, width: Double, held: Bool = false) {
            self.minX = minX; self.width = width; self.held = held
        }
    }

    /// Copies this close in x and width are one slot. Two real pills sit a
    /// pill and a 14-16 pt gap apart, so no real pair comes near it.
    static let tolerance = 2.0

    /// The copies to keep, one per slot, as indices in the given order.
    /// Within a stack the copy no mirror holds yet wins: in a swap it's the
    /// new activity's pill, the held one is the departed one. With none
    /// new, the first listed stays.
    public static func keep(_ copies: [Copy]) -> [Int] {
        var slots: [[Int]] = []
        for (i, copy) in copies.enumerated() {
            if let s = slots.firstIndex(where: { slot in
                let first = copies[slot[0]]
                return abs(first.minX - copy.minX) <= tolerance && abs(first.width - copy.width) <= tolerance
            }) {
                slots[s].append(i)
            } else {
                slots.append([i])
            }
        }
        return slots.map { slot in slot.first { !copies[$0].held } ?? slot[0] }.sorted()
    }
}
