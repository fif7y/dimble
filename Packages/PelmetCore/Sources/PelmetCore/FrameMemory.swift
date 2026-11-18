// FrameMemory.swift
// The last in-slot frame per icon, kept across conceals so the Apply count
// and the settle can place a concealed icon without a reveal (AppState's,
// read through `ApplyPass.rememberedFrames`). Pure: the app hands it each
// walk and each pass.

import CoreGraphics
import Foundation

public struct FrameMemory: Equatable, Sendable {
    /// Last primary-band frame per canonical key, read in its slot.
    public private(set) var frames: [ItemID: CGRect] = [:]
    /// The chevron's midX when each frame was remembered: concealed icons
    /// sit left of the chevron and slide with it, so a frame remembered
    /// before Apply moved an icon out of Hidden (chevron 1523 → 1451,
    /// 2026-09-20 21:39) reads right of the new chevron and lit the button
    /// again for nothing. The count shifts each frame by the chevron delta.
    public private(set) var chevronMidX: [ItemID: CGFloat] = [:]
    /// Icons whose frame a pass's drags made stale: only a walk at rest
    /// frames them again.
    public private(set) var awaitingRest: Set<ItemID> = []

    public init() {}

    /// One walk's frames for the icons it read in their slot (primary band,
    /// neither concealed nor out on their own).
    public mutating func remember(_ inSlot: [ItemID: CGRect], chevronMidX chevron: CGFloat?, atRest: Bool) {
        for (key, frame) in inSlot {
            if awaitingRest.contains(key) {
                guard atRest else { continue }
                awaitingRest.remove(key)
            }
            frames[key] = frame
            chevronMidX[key] = chevron
        }
    }

    /// A pass dragged icons where concealed ones sit, and `read` is what the
    /// walk after its last drag placed. Every other frame is from the bar
    /// before the drags: a drag shifts the icons beside it and nothing
    /// re-reads one hidden through it, nor does the chevron shift account
    /// for it. Sound kept a frame from before Snib's drag moved it, the
    /// collapsed bar read it in place, and a real reorder in a concealed
    /// Hidden read as no move (live test, 2026-10-13); with every icon framed
    /// the settle would have cleared it. Forgotten, the icon is one the bar
    /// cannot place until its section is out again: its edit stays pending,
    /// never dark.
    @discardableResult
    public mutating func forget(allBut read: Set<ItemID>) -> Set<ItemID> {
        let stale = Set(frames.keys).subtracting(read)
        for key in stale {
            frames.removeValue(forKey: key)
            chevronMidX.removeValue(forKey: key)
        }
        awaitingRest.formUnion(stale)
        return stale
    }

    /// The icons among `keys` remembered right of the chevron as it stood
    /// with them. macOS pins some there (Apple's Siri, in SystemUIServer,
    /// Control Center), and one Apply has yet to drag sits there too.
    /// Hidden, such an icon leaves the bar and the chevron and every icon
    /// between close the gap: a reveal that brings it back moves them all
    /// over again, by its width (#157).
    ///
    /// An icon not read in its slot since launch has only its frame from
    /// the launch walk (`launchFrames`: every icon out, before the first
    /// conceal), and a frame read with no chevron on the bar has nothing to
    /// stand against. Both are judged against `chevronNow`, the chevron of
    /// the concealed bar: it stands as far right as it ever does there, so
    /// an icon wholly past it was right of it revealed too (Control Center,
    /// first reveal of a launch, 2026-11-18).
    public func rightOfChevron(
        among keys: some Sequence<ItemID>, chevronNow: CGRect? = nil, launchFrames: [ItemID: CGRect] = [:]
    ) -> [ItemID] {
        keys.filter { key in
            if let frame = frames[key], let chevron = chevronMidX[key] { return frame.midX > chevron }
            guard let frame = frames[key] ?? launchFrames[key], let chevronNow else { return false }
            return frame.minX >= chevronNow.maxX - 1
        }.sorted { $0.rawValue < $1.rawValue }
    }

    /// Always Hidden is seen only in a full reveal, Hidden in every hover,
    /// and the chevron alone does not re-anchor one against the other: the
    /// separator remembered at launch, before Siri joined Hidden, read
    /// inside it and lit "Apply (1)" with nothing to do (2026-09-25). No
    /// reading sees across that line while Always Hidden is concealed, so
    /// its remembered icons (`alwaysHidden`) keep their order, left of
    /// Hidden's left edge. One remembered right of the chevron was seen
    /// there, a stray, and keeps its side: shifted with the group, Battery
    /// read in place at rest and was never grouped (2026-10-20).
    public static func alwaysHiddenLeftOfHidden(
        _ frames: [ItemID: CGRect], alwaysHidden: Set<ItemID>, hiddenLeft: CGFloat?, chevronMidX: CGFloat?
    ) -> [ItemID: CGRect] {
        let group = alwaysHidden.filter { key in
            guard let chevronMidX, let frame = frames[key] else { return true }
            return frame.midX < chevronMidX
        }
        guard let hiddenLeft, let groupRight = group.compactMap({ frames[$0]?.maxX }).max(),
              groupRight > hiddenLeft else { return frames }
        var shifted = frames
        for key in group { shifted[key] = frames[key]?.offsetBy(dx: hiddenLeft - groupRight, dy: 0) }
        return shifted
    }

    /// The Always Hidden icons `alwaysHiddenLeftOfHidden` keeps apart: the
    /// remembered ones, and the ones on the bar while a Hidden icon is
    /// concealed. Out alone (#149's middle click) they sit where Hidden
    /// was, and no reading has both: 8 of them read beside Hidden's
    /// remembered frames counted 3 moves, and "Apply (3)" came back at
    /// every reveal (2026-11-17 20:56:16).
    public static func alwaysHiddenApart(
        in frames: [ItemID: CGRect], remembered: Set<ItemID>, concealed: Set<ItemID>, section: (ItemID) -> Section
    ) -> Set<ItemID> {
        guard frames.keys.contains(where: { concealed.contains($0) && section($0) == .hidden }) else { return remembered }
        return remembered.union(frames.keys.filter { section($0) == .alwaysHidden })
    }
}
