// PicturePassBatches.swift
// The pure side of the picture pass's follow-up batches (docs/PANEL-PLAN.md
// §8): which wanted items a follow-up is for, which drawn frames a follow-up
// may crop, what stops one, and when another round is worth its time. The
// pass itself (reveals, strips, covers) lives in TransitionCoordinator. Its
// first round crops through `drawn` too (#81: a phantom's cut is the «), and
// follow-ups are a narrow fallback. Locked by PicturePassBatchesTests.

import CoreGraphics
import Foundation

public enum PicturePassBatches {
    /// Rounds after the first full-section one.
    public static let maxFollowUps = 3

    /// Cover time kept back for what follows the last round: the final
    /// conceal and the cover's lift.
    public static let liftReserve: TimeInterval = 1.5

    // MARK: - Which items a follow-up is for

    /// How the first round's settled walk saw one wanted item.
    public enum Reading: Equatable, Sendable {
        /// A frame on the primary bar, clear of every other frame.
        case clear
        /// A primary-bar frame overlapping another's: the native « holds it
        /// (`PlacementGeometry.overflowTrapped`).
        case phantom
        /// In the walk, with no frame at all.
        case frameless
        /// Frames only on another display's bar.
        case elsewhere
        /// Not in the walk: it draws nothing under any assertion, or its
        /// app is not running.
        case unseen
    }

    /// `items` is every item of the walk, wanted or not, by key and frame
    /// (nil when AX gave none): a phantom is told by its neighbours, and one
    /// overlapping a visible icon is as much a phantom as one overlapping
    /// another hidden icon. Twins of one key (title variants) read as the
    /// leftmost primary-bar frame they have, so they do not overlap
    /// themselves.
    public static func readings(
        wanted: Set<ItemID>, items: [(key: ItemID, frame: CGRect?)], primaryMaxX: CGFloat
    ) -> [ItemID: Reading] {
        var seen = Set<ItemID>()
        var framed = Set<ItemID>()
        var onPrimary: [ItemID: CGRect] = [:]
        for (key, frame) in items {
            seen.insert(key)
            guard let frame else { continue }
            framed.insert(key)
            guard MenuBarGeometry.isInPrimaryBand(frame, primaryMaxX: primaryMaxX) else { continue }
            if let existing = onPrimary[key], existing.minX <= frame.minX { continue }
            onPrimary[key] = frame
        }
        let phantoms = phantomKeys(in: onPrimary)
        var readings: [ItemID: Reading] = [:]
        for key in wanted {
            if !seen.contains(key) {
                readings[key] = .unseen
            } else if !framed.contains(key) {
                readings[key] = .frameless
            } else if onPrimary[key] == nil {
                readings[key] = .elsewhere
            } else {
                readings[key] = phantoms.contains(key) ? .phantom : .clear
            }
        }
        return readings
    }

    /// The wanted items a follow-up is for: seen frameless, or as a phantom
    /// on the primary bar. Not a clear frame whose cut came back blank (an
    /// animated wallpaper, an empty glyph: the same reveal would give the
    /// same), not another display's, not one the walk never saw.
    public static func leftovers(wanted: Set<ItemID>, items: [(key: ItemID, frame: CGRect?)], primaryMaxX: CGFloat) -> Set<ItemID> {
        Set(readings(wanted: wanted, items: items, primaryMaxX: primaryMaxX).compactMap { key, reading in
            reading == .phantom || reading == .frameless ? key : nil
        })
    }

    /// What a follow-up still owes after it pictured `pictured`.
    public static func remaining(_ leftovers: Set<ItemID>, pictured: Set<ItemID>) -> Set<ItemID> {
        leftovers.subtracting(pictured)
    }

    // MARK: - What a follow-up may crop

    /// What a follow-up's settled walk drew of the items it asked for.
    public struct Drawn: Equatable, Sendable {
        /// Asked-for items on the bar, clear of every other frame: safe to crop.
        public let solid: [ItemID: CGRect]
        /// Asked-for items whose frame overlaps another's: a crop of it
        /// would take the neighbour's pixels.
        public let phantoms: Set<ItemID>

        public init(solid: [ItemID: CGRect], phantoms: Set<ItemID>) {
            self.solid = solid
            self.phantoms = phantoms
        }
    }

    /// `frames` is every primary-band frame of the walk, asked for or not.
    public static func drawn(wanted: Set<ItemID>, frames: [(key: ItemID, frame: CGRect)]) -> Drawn {
        var byKey: [ItemID: CGRect] = [:]
        for (key, frame) in frames {
            if let existing = byKey[key], existing.minX <= frame.minX { continue }
            byKey[key] = frame
        }
        let phantoms = phantomKeys(in: byKey)
        var solid: [ItemID: CGRect] = [:]
        var behind = Set<ItemID>()
        for (key, frame) in byKey where wanted.contains(key) {
            if phantoms.contains(key) {
                behind.insert(key)
            } else {
                solid[key] = frame
            }
        }
        return Drawn(solid: solid, phantoms: behind)
    }

    private static func phantomKeys(in byKey: [ItemID: CGRect]) -> Set<ItemID> {
        let entries = Array(byKey)
        return Set(PlacementGeometry.overflowTrapped(entries.map(\.value)).map { entries[$0].key })
    }

    // MARK: - Whether to go on

    /// Whether to run another follow-up. None when nothing is owed, at the
    /// cap, or when the round before pictured nothing new AND had only one
    /// item out: the same set draws the same way, but a smaller one can find
    /// room the « took (#153). `lastRoundPictured` and `lastRoundAsked` are
    /// ignored before the first follow-up.
    public static func wantsAnotherRound(
        followUpsDone: Int, leftovers: Set<ItemID>, lastRoundPictured: Int, lastRoundAsked: Int = 0
    ) -> Bool {
        guard !leftovers.isEmpty, followUpsDone < maxFollowUps else { return false }
        if followUpsDone == 0 || lastRoundPictured > 0 { return true }
        return lastRoundAsked > 1
    }

    /// How many leftovers the next round may ask for, learnt from the round
    /// before. A round that pictured nothing had more out at once than the
    /// bar had room for, so every one of them came back behind the «; the cap
    /// halves and never grows back, since the room doesn't (#153: nine at
    /// once on a full MacBook Air bar stayed trapped, every tile a chevron).
    public static func nextCap(cap: Int, lastRoundAsked: Int, lastRoundPictured: Int) -> Int {
        guard lastRoundAsked > 0, lastRoundPictured == 0 else { return cap }
        return max(1, lastRoundAsked / 2)
    }

    /// The cap the rounds start with: every leftover, unless the first
    /// full-section round found not one of the items it wanted clear of the
    /// others. That already says the bar had no room for that many, so the
    /// rounds start halved rather than spending one on a set that would come
    /// back behind the « whole (#153).
    public static func startingCap(leftovers: Int, firstRoundClear: Int) -> Int {
        firstRoundClear == 0 ? max(1, leftovers / 2) : leftovers
    }

    /// The items of a round, capped: the cap's worth of leftovers in key
    /// order, so a round is reproducible and the rest fall to the next one.
    public static func batch(_ leftovers: Set<ItemID>, cap: Int) -> Set<ItemID> {
        guard cap < leftovers.count else { return leftovers }
        return Set(leftovers.sorted { $0.rawValue < $1.rawValue }.prefix(max(1, cap)))
    }

    /// What must hold at the start of every follow-up.
    public struct Conditions: Equatable, Sendable {
        public var hasCover: Bool
        public var hasEmptyBarPicture: Bool
        /// A press other than the pass's own holds the bar.
        public var otherPressHoldsBar: Bool
        /// A reveal or a press is waiting for the pass to put the bar back.
        public var waiterPending: Bool

        public init(hasCover: Bool, hasEmptyBarPicture: Bool, otherPressHoldsBar: Bool, waiterPending: Bool) {
            self.hasCover = hasCover
            self.hasEmptyBarPicture = hasEmptyBarPicture
            self.otherPressHoldsBar = otherPressHoldsBar
            self.waiterPending = waiterPending
        }
    }

    /// Why a follow-up does not start; `reason` is what the log says.
    public enum Blocker: Equatable, Sendable {
        case noCover
        case noEmptyBarPicture
        case pressHoldsBar
        case waiterPending
        case noTime

        public var reason: String {
            switch self {
            case .noCover: "no cover"
            case .noEmptyBarPicture: "no empty-bar picture"
            case .pressHoldsBar: "a press holds the bar"
            case .waiterPending: "a reveal or press is waiting"
            case .noTime: "not enough cover time left"
            }
        }
    }

    /// A round needs `batch` and then `liftReserve` to still fit under
    /// `ceiling`, all counted from the cover going up.
    public static func roundFits(elapsed: TimeInterval, batch: TimeInterval, ceiling: TimeInterval) -> Bool {
        elapsed + batch + liftReserve <= ceiling
    }

    /// The first thing that stops the next follow-up, nil when it may start.
    public static func blocker(
        _ conditions: Conditions, elapsed: TimeInterval, batch: TimeInterval, ceiling: TimeInterval
    ) -> Blocker? {
        if !conditions.hasCover { return .noCover }
        if !conditions.hasEmptyBarPicture { return .noEmptyBarPicture }
        if conditions.otherPressHoldsBar { return .pressHoldsBar }
        if conditions.waiterPending { return .waiterPending }
        if !roundFits(elapsed: elapsed, batch: batch, ceiling: ceiling) { return .noTime }
        return nil
    }
}
