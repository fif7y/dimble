// BarRightClickTap.swift
// Takes the right-click that opens Pelmet's bar menu before MenuBarAgent
// can draw its own.
//
// macOS 27's MenuBarAgent answers a right-click on the bare menu bar with a
// one-item context menu ("Menu Bar settings…"). Pelmet answers the same
// click from a passive global NSEvent monitor, which cannot consume an
// event — so the OS menu opens on the mouse-down and Pelmet's lands on top
// a beat later. That is the flash in #140. Only a head-inserted
// `.defaultTap` gets the event first and can swallow it.
//
// A tap callback must not ask the main thread anything: the gate the click
// path runs (`isEmptyMenuBarArea`) is a cross-process AX hit-test, which
// has no business holding up the event stream. So the main thread leaves a
// CLAIM behind instead. It already hit-tests the point under the pointer as
// the pointer travels the band, so by the time the button goes down the
// verdict for that very point is in.
//
// Nothing is swallowed without one. No claim, a stale one, or one taken a
// few points away, and the event passes through untouched: the global
// monitor sees it and the click behaves exactly as it did before — OS menu
// first, Pelmet's over it. Every way this can be wrong ends in today's
// behaviour, never in a right-click another app should have had.

import AppKit

nonisolated final class BarRightClickTap: @unchecked Sendable {
    /// How far the claim's point may sit from the click's. A dwelling
    /// pointer claims its exact point; this is slack for the move that
    /// lands and clicks in the same breath, and it is small because the
    /// bare bar's edge is an item's edge.
    private static let claimReach: CGFloat = 4
    /// How long a claim stands. A moving pointer re-takes it on every band
    /// move, so this only bounds a pointer standing still: past it the
    /// click falls through and macOS draws its own menu first, as it
    /// always did. Kept short because the bar can reflow under a still
    /// pointer — a hover reveal lands ~250ms into a dwell.
    private static let claimFreshness: TimeInterval = 2

    private let lock = NSLock()
    /// Where the main thread last found bare bar of Pelmet's: a CG point
    /// (top-left origin, the way a tap reads an event's location) and the
    /// uptime the verdict was taken at.
    private var claim: (point: CGPoint, takenAt: TimeInterval)?
    /// A down was swallowed, so its up goes with it. A consumed down whose
    /// up is still delivered leaves whatever was under the pointer holding
    /// a press it will never see released — measured 2026-11-10 against the
    /// clock, which kept a highlight window up until the pointer left.
    private var swallowedDown = false
    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var tapRunLoop: CFRunLoop?
    private let onClaimed: @MainActor () -> Void

    init(onClaimed: @escaping @MainActor () -> Void) {
        self.onClaimed = onClaimed
    }

    /// Main thread: a right-click at `point` would be Pelmet's.
    func claim(at point: CGPoint) {
        lock.withLock { claim = (point, ProcessInfo.processInfo.systemUptime) }
    }

    /// Main thread: it would not be, or there is nothing left to claim —
    /// the pointer left the bar, or the bar is about to change under it.
    /// Leaves `swallowedDown` alone: a down already taken owns its up
    /// whatever the bar does in between.
    func release() {
        lock.withLock { claim = nil }
    }

    /// False when the tap could not be created (no Accessibility): the
    /// click path keeps the passive monitor it always had.
    func start() -> Bool {
        let mask = [CGEventType.rightMouseDown, .rightMouseUp]
            .reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let tap = Unmanaged<BarRightClickTap>.fromOpaque(userInfo).takeUnretainedValue()
                return tap.handle(type: type, event: event)
            },
            userInfo: selfPtr
        ) else { return false }
        self.tap = tap
        let thread = Thread { [weak self] in
            guard let self, let tap = self.tap else { return }
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            self.tapSource = source
            self.tapRunLoop = CFRunLoopGetCurrent()
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            CFRunLoopRun()
        }
        thread.qualityOfService = .userInteractive
        thread.name = "pelmet.bar-right-click"
        thread.start()
        return true
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let tapRunLoop, let tapSource {
            CFRunLoopRemoveSource(tapRunLoop, tapSource, .commonModes)
            CFRunLoopStop(tapRunLoop)
        }
        tap = nil
        tapSource = nil
        tapRunLoop = nil
        release()
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        if type == .rightMouseUp {
            let ours = lock.withLock { () -> Bool in
                defer { swallowedDown = false }
                return swallowedDown
            }
            return ours ? nil : Unmanaged.passUnretained(event)
        }
        guard type == .rightMouseDown else { return Unmanaged.passUnretained(event) }
        let point = event.location
        let now = ProcessInfo.processInfo.systemUptime
        let ours: Bool = lock.withLock {
            guard let claim,
                  now - claim.takenAt < Self.claimFreshness,
                  abs(claim.point.x - point.x) <= Self.claimReach,
                  abs(claim.point.y - point.y) <= Self.claimReach
            else { return false }
            // One click per claim: what the pointer is over now is the menu
            // this opens, and the move path takes a fresh verdict after.
            self.claim = nil
            self.swallowedDown = true
            return true
        }
        guard ours else { return Unmanaged.passUnretained(event) }
        let onClaimed = onClaimed
        DispatchQueue.main.async { MainActor.assumeIsolated { onClaimed() } }
        return nil
    }
}
