// MenuBarEngine.swift
// The macOS-28 seam: everything above this protocol is version-agnostic.
// One implementation exists today (AgentBarEngine, macOS 27).

import Foundation
import PelmetCore

public struct ObservedItem: Equatable, Sendable {
    public let id: ItemID
    /// Screen-coordinate frame on the main menubar instance; nil when concealed
    /// (concealed items drop out of the AX tree entirely).
    public let frame: CGRect?
    public let appName: String?
    /// The item's owning process has no LaunchServices bundle id (a bare
    /// helper executable inside another app — ChatGPT Classic's
    /// ChatGPTHelper). Pelmet files it under the enclosing app's bundle, but
    /// the assertion allowlist keys on the process and can never hide it.
    public let hostIsBundleless: Bool
    /// The process that owns the item (0 when unknown). A bundle id alone
    /// cannot tell a relaunch from a sibling process reusing the id.
    public let pid: pid_t

    public init(id: ItemID, frame: CGRect?, appName: String?, hostIsBundleless: Bool = false, pid: pid_t = 0) {
        self.id = id
        self.frame = frame
        self.appName = appName
        self.hostIsBundleless = hostIsBundleless
        self.pid = pid
    }
}

public struct EngineSnapshot: Equatable, Sendable {
    public let items: [ObservedItem]
    /// Items currently concealed by our assertion (kept from the last converge;
    /// AX can no longer see them).
    public let concealed: Set<ItemID>
    public let takenAt: Date
    /// Items out on the bar on their own (a press, a picture pass round, a
    /// show rule) while their section stays concealed: they sit beside the
    /// chevron, not in their slot.
    public let shownAlone: Set<ItemID>
    /// False when `items` were not read at rest: stamped at a swap on the
    /// walk before it, or walked inside the swap's reflow (AX lists a freshly
    /// revealed strip a part at a time). Icons the swap revealed can then be
    /// in neither `items` nor `concealed`. Fine for presence and covers; not
    /// for judging an order (the settle cleared a pending reorder on it,
    /// live test 2026-10-13). A walk at rest always follows one
    /// (`AgentBarEngine.lastSnapshot`), announced by `.mirrorAtRest`.
    public let itemsAtRest: Bool

    public init(
        items: [ObservedItem], concealed: Set<ItemID>, takenAt: Date, shownAlone: Set<ItemID> = [],
        itemsAtRest: Bool = true
    ) {
        self.items = items
        self.concealed = concealed
        self.takenAt = takenAt
        self.shownAlone = shownAlone
        self.itemsAtRest = itemsAtRest
    }

    /// Equality ignoring `takenAt` — for observers that only care whether the
    /// bar's content changed, not when it was last walked.
    public func contentEquals(_ other: EngineSnapshot) -> Bool {
        items == other.items && concealed == other.concealed
    }
}

public enum EngineEvent: Equatable, Sendable {
    /// The set of menubar items changed (app launched/quit, item added/removed).
    case itemsChanged
    /// The mirror is a walk at rest again after one that was not
    /// (`EngineSnapshot.itemsAtRest`), or the walk at rest an own item's
    /// show was owed (`AgentBarEngine.ownItemShown`): re-read it, nothing
    /// to converge.
    /// Not itemsChanged: that converges, and a swap that never goes no-op
    /// (a dud activation drops the allowlist) would swap at every rest walk.
    case mirrorAtRest
    /// Our hide assertion was torn down externally (DND/assessment churn).
    case assertionTornDown
    /// MenuBarClientCore availability flipped (e.g. after an OS update).
    case availabilityChanged(Bool)
    /// A converge attempt failed after bounded retries; surface to the user.
    case convergeFailed(String)
}

public struct EngineCapabilities: Sendable {
    public let canHide: Bool

    public init(canHide: Bool) {
        self.canHide = canHide
    }
}

/// The engine converges the real menubar toward a desired `SectionModel` +
/// reveal state. All mutating calls are serialized internally; callers never
/// see interleaved half-states.
public protocol MenuBarEngine: Actor {
    var capabilities: EngineCapabilities { get }
    var events: AsyncStream<EngineEvent> { get }

    func start() async
    func stop() async

    func snapshot() async -> EngineSnapshot

    /// Update the desired layout and converge toward it.
    func setModel(_ model: SectionModel) async
    /// Reveal the given sections (relax the assertion accordingly).
    func reveal(_ sections: Set<Section>) async
    /// Conceal everything the model says is non-visible.
    func conceal() async
    /// True when no assertion swap has been issued for `interval` seconds —
    /// the agent's animation passes ride each swap, so swap-quiet means the
    /// bar has stopped moving. Overlay covers hold until this turns true.
    func quiesced(for interval: TimeInterval) async -> Bool
}
