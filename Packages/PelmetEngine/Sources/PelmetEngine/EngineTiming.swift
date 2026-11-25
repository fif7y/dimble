// EngineTiming.swift
// Empirically tuned waits and windows for macOS 27's MenuBarAgent behavior.
// Values are load-bearing (tuned live against agent restart/reflow/AX
// latencies) — rename freely, never retune casually.

import Foundation

enum EngineTiming {
    /// snapshot() cache TTL — sub-500ms repeat reads reuse the last AX walk.
    static let snapshotTTL: TimeInterval = 0.5
    /// A mirror taken at rest (this long after the last swap, so the agent's
    /// reflow is over and AX lists the whole strip) stands in for a fresh
    /// walk on the transition path — converge plans from it, the conceal
    /// measures its strip from it — for this long. Measured 2026-09-21:
    /// the pre-swap walk was 30–100ms of every reveal and 70–130ms of
    /// every conceal, for a bar that had not changed since the last walk.
    static let restWalkDelay: TimeInterval = 0.5
    static let restSnapshotReuse: TimeInterval = 30

    /// A walk read the bar at rest when it started `restWalkDelay` past the
    /// last swap, as that swap stands when the walk lands: one a swap
    /// overtook mid-walk is mid-reflow too.
    static func walkAtRest(startedAt started: Date, lastSwapAt: Date) -> Bool {
        started.timeIntervalSince(lastSwapAt) >= restWalkDelay
    }
    /// AX messaging timeouts — a stuck agent/app must never wedge a walk.
    static let axAgentTimeout: Float = 0.25
    static let axAppTimeout: Float = 0.5
    /// Empty-AX-walk deferral: bounded retries while the agent tree is unreadable.
    static let emptyAXRetries = 6
    static let emptyAXRetryDelay: Duration = .milliseconds(500)
    static let emptyAXSlowRetryDelay: Duration = .seconds(2)
    /// The slow retry stays at 2s this long into an empty run: a login-item
    /// launch reads empty for 17–40s, and every retry skipped there is an
    /// un-hidden bar for longer.
    static let emptyAXFlatRetryWindow: TimeInterval = 120
    /// Past the window it doubles up to this: a bar that stays unreadable
    /// (a desktop's display asleep overnight) costs a walk a minute, where
    /// 2s flat was ≈14k walks a night.
    static let emptyAXSlowRetryMax: Duration = .seconds(60)

    /// The slow retry's delay after `previous` (nil: the first slow one),
    /// `emptyFor` seconds into the empty run.
    static func emptyAXSlowRetry(after previous: Duration?, emptyFor: TimeInterval) -> Duration {
        guard let previous, emptyFor >= emptyAXFlatRetryWindow else { return emptyAXSlowRetryDelay }
        return min(previous * 2, emptyAXSlowRetryMax)
    }
    /// Ignore teardown signals inside this window after a swap (AX drop-out lag).
    static let teardownSettleWindow: TimeInterval = 3
    /// Assertion activation completion: deadline for a dud completion
    /// (observed latency a few ms; the wait resumes on the completion itself).
    static let activationDeadline: TimeInterval = 3
    /// verifyConcealment: bounded poll until concealed bundles drop out of AX.
    static let verifyWindow: TimeInterval = 3
    static let verifyPoll: Duration = .milliseconds(150)
    /// Synthetic-drag idle gate: don't grab the pointer out of the user's
    /// hand — wait for this much HID-mouse quiet before starting, but never
    /// stall a placement longer than the cap (the shield protects either way).
    static let dragIdleQuietGap: TimeInterval = 0.25
    static let dragIdleMaxWait: TimeInterval = 1.5
    /// Pelmet's own items (chevron, separators, extras) move with the bar
    /// frozen and the user usually just asked for it (a toggle, a launch):
    /// a short courtesy gap, not the full stall (2026-09-06).
    static let ownItemDragIdleMaxWait: TimeInterval = 0.3
    static let dragIdlePoll: Duration = .milliseconds(50)
    /// Bounded wait for the shield's tap thread to arm before posting events.
    static let dragShieldArmTimeout: TimeInterval = 0.3
    /// Adoption window: assertion-free gap for a parked fresh registration to
    /// land (lands instantly in practice; the deadline bounds the flash).
    static let adoptionWindowDeadline: TimeInterval = 2.5
    static let adoptionWindowPoll: Duration = .milliseconds(200)
    /// How long after a window the icons it let out can still be leaving.
    static let adoptionLeaving: TimeInterval = 1
}
