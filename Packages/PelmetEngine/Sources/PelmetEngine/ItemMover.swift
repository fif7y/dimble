// ItemMover.swift
// Physical repositioning WITHOUT restarting MenuBarAgent: synthesize the same
// ⌘-drag a human performs. macOS 27 handles coordinate-based drags natively
// (verified live on this machine) — the agent animates the move and persists
// the position itself. No rebuild, no blink, no relaunch.
//
// The drag is shielded (2026-08-31): physical mouse input during the synthetic
// sequence merges into the same HID stream — a physical move yanks the drag
// off-path (the agent mis-tracks slot crossings and bounces), a physical click
// lands wherever the warped cursor is (the menu bar — it can open a random
// item's menu), and a physical mouse-up cuts the drag short mid-path. So for
// the duration of the sequence: wait for a quiet gap in user input, decouple
// the physical mouse from the cursor, swallow physical mouse events with an
// active tap (our own events pass via a source-userData tag), and hide the
// cursor so the pointer doesn't visibly fly across the bar.

import AppKit
import CoreGraphics
import Foundation
import Synchronization

public enum ItemMover {
    /// Performs a ⌘-drag from one menubar point to another (top-left-origin
    /// global coordinates, i.e. the same space as AX frames). Saves and
    /// restores the user's cursor so the pointer doesn't visibly teleport.
    ///
    /// Runs OFF the main actor deliberately: when the dragged item is Pelmet's
    /// OWN, our process runs AppKit's drag tracking — posting from the main
    /// actor interleaved the tracking loop with this function's sleeps and
    /// every own-item drop reverted, while a real ⌘-drag on the same item
    /// worked (verified live 2026-08-21). Third-party items never cared
    /// (their owning app tracks the drag).
    /// `ownItem`: Pelmet's own registrations get the short courtesy gap
    /// before the pointer is borrowed (EngineTiming.ownItemDragIdleMaxWait).
    /// `jump`: the first drag event lands on the target, for a WindowServer
    /// that refuses the agent's window drag (see the path below).
    public static func cmdDrag(from: CGPoint, to: CGPoint, ownItem: Bool = false, jump: Bool = false) async {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return }
        // Tag every event from this source so the shield's tap can tell our
        // synthetic stream from real HID input.
        source.userData = SyntheticInput.tag
        let originalPosition = CGEvent(source: nil)?.location

        // Don't grab the pointer out of the user's hand mid-motion — bounded
        // wait for a quiet gap (the shield still protects if it never comes).
        await waitForPointerQuiet(
            maxWait: ownItem ? EngineTiming.ownItemDragIdleMaxWait : EngineTiming.dragIdleMaxWait
        )

        let shield = DragShield()
        shield.activate()
        defer { shield.deactivate() }

        // ⌘ rides the grab and the drag only. Set on the mouse-up too, it
        // stayed down in the HID state after every Apply (flags read
        // 0x20100000), and every later click was a ⌘-click (live test,
        // 2026-10-13): the release below puts it back up.
        func post(_ type: CGEventType, at point: CGPoint) {
            guard let event = CGEvent(
                mouseEventSource: source,
                mouseType: type,
                mouseCursorPosition: point,
                mouseButton: .left
            ) else { return }
            event.flags = type == .leftMouseUp ? [] : .maskCommand
            event.post(tap: .cghidEventTap)
        }
        func releaseCommand() {
            // Left ⌘'s key-up from the same source: a flagsChanged event.
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: 55, keyDown: false) else { return }
            event.flags = []
            event.post(tap: .cghidEventTap)
        }

        post(.leftMouseDown, at: from)
        // The ⌘-click hands frontmost to the dragged item's owner, and macOS
        // resets cursor visibility (and mouse association) on that flip — a
        // single pre-drag hide never survived it. Re-assert after every post;
        // SetsCursorInBackground (see DragShield) makes the re-hide stick.
        // The flip lands asynchronously — when Pelmet itself was frontmost
        // (the first drag of an Apply pass, clicked from the editor) it landed
        // AFTER a single re-assert and the cursor read VISIBLE at 180ms; every
        // later drag of the pass, started from the background, read hidden
        // (log, 2026-09-20). Re-assert through the hold instead of once.
        // Hold briefly so the drag registers as a deliberate grab.
        for _ in 0..<3 {
            shield.reassert()
            try? await Task.sleep(for: .milliseconds(60))
        }
        PelmetLog.log("mover: mid-drag cursor \(DragShield.cursorVisible ? "VISIBLE" : "hidden")")
        // Ease toward the target — single-jump drags are sometimes ignored,
        // and LONG drags need finer motion for the agent to track slot
        // crossings (a fixed-6-step 440pt drag = 74pt jumps bounced entirely,
        // verified live 2026-08-21).
        // A jump instead: the agent starts its drag on the first drag event
        // and asks WindowServer to carry the item's window with the mouse.
        // When WindowServer refuses ("no client initiated window drag trait
        // gesture to activate for mouse", every app's window drags, on and
        // off from 2026-10-19 13:15), the drag ends where that first event
        // put the pointer: one eased step from the start, so every drop
        // bounced. Landing that first event on the target drops it there
        // (A/B live, 2026-10-19 23:23); a few 1pt moves keep it a drag.
        let path: [CGPoint]
        if jump {
            path = [to] + (1...5).map { CGPoint(x: to.x + ($0.isMultiple(of: 2) ? 1 : -1), y: to.y) } + [to]
        } else {
            let distance = abs(to.x - from.x) + abs(to.y - from.y)
            let steps = min(24, max(6, Int(distance / 40)))
            path = (1...steps).map { step in
                let t = CGFloat(step) / CGFloat(steps)
                return CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t)
            }
        }
        for point in path {
            post(.leftMouseDragged, at: point)
            shield.reassert()
            try? await Task.sleep(for: .milliseconds(30))
        }
        try? await Task.sleep(for: .milliseconds(120))
        post(.leftMouseUp, at: to)
        releaseCommand()

        // Warp home while the shield still hides the cursor — it reappears
        // where the user left it, never mid-flight.
        try? await Task.sleep(for: .milliseconds(60))
        if let originalPosition {
            CGWarpMouseCursorPosition(originalPosition)
        }
        // The release above clears ⌘ (probed 2026-10-13). Still down = a
        // real ⌘ key held somewhere (device bit 0x8 is left ⌘ pressed), not
        // this drag: said here so a stuck ⌘ names its source.
        let flags = CGEventSource.flagsState(.hidSystemState)
        if flags.contains(.maskCommand) {
            PelmetLog.log("mover: ⌘ still down after the drag (flags 0x\(String(flags.rawValue, radix: 16)))")
        }
    }

    /// One plain click at a bar point under the same shield as a drag —
    /// the native « toggle only answers real HID clicks (AXPress refused,
    /// probed 2026-08-22 and 2026-09-20). Cursor hidden for the blip,
    /// warped home after. `button` .right is the secondary click (an item's
    /// right-click menu).
    public static func shieldedClick(at point: CGPoint, button: CGMouseButton = .left) async {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return }
        source.userData = SyntheticInput.tag
        let originalPosition = CGEvent(source: nil)?.location
        let shield = DragShield()
        // A click keeps mouse/cursor association ON, unlike a drag. The
        // shield turns it off so a drag's pointer cannot fly across the
        // screen, but with it off the pointer is decoupled from the point
        // the click carries, and a status item whose button reads the
        // pointer reads it wherever the user left it and opens nothing —
        // #142. OpenClip's menu never opened (0 of 8, three builds) and
        // opened every time once association stayed on (8 of 8); Unclutter
        // and Apple's sound item were 8 of 8 either way, which is why this
        // only ever hit some apps (probed 2026-11-13). The cursor still
        // hides, so none of this shows.
        shield.keepAssociation = true
        shield.activate()
        defer { shield.deactivate() }
        let (downType, upType): (CGEventType, CGEventType) =
            button == .right ? (.rightMouseDown, .rightMouseUp) : (.leftMouseDown, .leftMouseUp)
        func post(_ type: CGEventType) {
            guard let event = CGEvent(
                mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: button
            ) else { return }
            event.post(tap: .cghidEventTap)
        }
        SyntheticInput.noteClickPosted()
        post(downType)
        for _ in 0..<2 {
            shield.reassert()
            try? await Task.sleep(for: .milliseconds(30))
        }
        post(upType)
        if let originalPosition {
            try? await Task.sleep(for: .milliseconds(60))
            CGWarpMouseCursorPosition(originalPosition)
        }
    }

    /// Seconds since the user (or anyone) last produced a mouse event. Our own
    /// synthetic events count too, but callers only reach here ≥450ms after
    /// the previous drag (placementPreSettle), past the quiet gap already.
    private static func secondsSincePointerActivity() -> TimeInterval {
        let types: [CGEventType] = [
            .mouseMoved, .leftMouseDown, .leftMouseUp, .leftMouseDragged,
            .rightMouseDown, .scrollWheel,
        ]
        return types.map {
            CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: $0)
        }.min() ?? .infinity
    }

    private static func waitForPointerQuiet(maxWait: TimeInterval) async {
        let deadline = Date.now.addingTimeInterval(maxWait)
        while Date.now < deadline {
            if secondsSincePointerActivity() >= EngineTiming.dragIdleQuietGap { return }
            try? await Task.sleep(for: EngineTiming.dragIdlePoll)
        }
        PelmetLog.log("mover: pointer never went quiet — dragging shielded anyway")
    }
}

// MARK: - Shield

/// Guards one synthetic-drag window. Three layers, each independently
/// crash-safe (the WindowServer resets connection state — association, cursor
/// hide, taps — if the process dies mid-drag):
/// 1. `CGAssociateMouseAndMouseCursorPosition(0)` — physical mouse motion
///    stops moving the cursor, so it can't yank the drag off its path.
/// 2. An active HID event tap on its own thread that swallows physical mouse
///    events (ours carry `syntheticTag` in source userData and pass) — no
///    miss-clicks into the menu bar, no premature physical mouse-up.
/// 3. `CGDisplayHideCursor` — the pointer vanishes for the window instead of
///    visibly flying. (May no-op while Pelmet isn't frontmost — cosmetic
///    layer only; 1+2 are what prevent harm.)
///
/// The tap needs a runloop; a dedicated thread hosts it because the main
/// runloop is busy running AppKit's drag tracking during own-item drags, and
/// a starved tap gets auto-disabled by timeout (passing everything through).
/// Marks CGEvents Pelmet posts itself (source userData), so Pelmet's own
/// event taps let them through and only physical input is intercepted.
public enum SyntheticInput {
    public static let tag: Int64 = 0x504C_4D54 // "PLMT"

    /// When Pelmet last posted a shielded click (system uptime, like an
    /// event's timestamp): a monitor that sees the click can tell it from
    /// the user's by its time, should its copy come without the tag.
    public static var clickPostedAt: TimeInterval? { posted.withLock { $0 } }
    private static let posted = Mutex<TimeInterval?>(nil)

    static func noteClickPosted() {
        posted.withLock { $0 = ProcessInfo.processInfo.systemUptime }
    }
}

private final class DragShield {

    private var tap: CFMachPort?
    private var tapRunLoop: CFRunLoop?
    private var tapSource: CFRunLoopSource?
    private var active = false
    private let armed = DispatchSemaphore(value: 0)

    /// `CGDisplayHideCursor` is FOREGROUND-gated, and the drag's first posted
    /// ⌘-click hands frontmost to the dragged item's owner — so the hide died
    /// the moment the drag started and the cursor stayed visible for the whole
    /// flight (observed live 2026-08-31). This SPI connection property opts
    /// our WindowServer connection into hiding the cursor from the background
    /// (same private-API disclosure posture as MenuBarClientCore). Connection
    /// state — a crash resets it. Resolved via dlsym like the hiding core.
    private static let backgroundCursorOptIn: Bool = {
        typealias MainCID = @convention(c) () -> UInt32
        typealias SetProp = @convention(c) (UInt32, UInt32, CFString, CFTypeRef) -> Int32
        let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)
        guard
            let cidSym = dlsym(rtldDefault, "CGSMainConnectionID"),
            let setSym = dlsym(rtldDefault, "CGSSetConnectionProperty")
        else {
            PelmetLog.log("mover: CGS cursor SPI unresolved — cursor stays visible in background")
            return false
        }
        let cid = unsafeBitCast(cidSym, to: MainCID.self)()
        let err = unsafeBitCast(setSym, to: SetProp.self)(
            cid, cid, "SetsCursorInBackground" as CFString, kCFBooleanTrue
        )
        if err != 0 {
            PelmetLog.log("mover: SetsCursorInBackground refused (\(err)) — cursor stays visible in background")
        }
        return err == 0
    }()

    /// `CGDisplayHideCursor` is COUNTED — deactivate balances every hide.
    private var hideCount = 0

    /// Whether the cursor is globally visible right now (deprecated
    /// `CGCursorIsVisible`, resolved via dlsym to dodge the warning) —
    /// mid-drag diagnostic for whether the re-asserted hide actually took.
    static var cursorVisible: Bool {
        typealias IsVisible = @convention(c) () -> UInt32
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGCursorIsVisible") else {
            return true
        }
        return unsafeBitCast(sym, to: IsVisible.self)() != 0
    }

    func activate() {
        guard !active else { return }
        active = true
        _ = Self.backgroundCursorOptIn
        reassert()
        startTap()
    }

    /// Association and cursor-hide are both reset by macOS whenever frontmost
    /// changes — which the drag itself causes. Cheap; called after every
    /// posted event.
    /// A click (not a drag) can keep association on: the cursor still hides,
    /// but the pointer really is where the click lands, which is what an item
    /// that reads the pointer needs (#142).
    var keepAssociation = false

    func reassert() {
        guard active else { return }
        if !keepAssociation { CGAssociateMouseAndMouseCursorPosition(0) }
        CGDisplayHideCursor(CGMainDisplayID())
        hideCount += 1
    }

    /// Idempotent, and the ONLY exit — every layer must come back up even on
    /// a failed drag; leaving association off or the tap alive would freeze
    /// the user's mouse for good.
    func deactivate() {
        guard active else { return }
        active = false
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let tapRunLoop, let tapSource {
            CFRunLoopRemoveSource(tapRunLoop, tapSource, .commonModes)
            CFRunLoopStop(tapRunLoop)
        }
        tap = nil
        tapSource = nil
        tapRunLoop = nil
        while hideCount > 0 {
            CGDisplayShowCursor(CGMainDisplayID())
            hideCount -= 1
        }
        CGAssociateMouseAndMouseCursorPosition(1)
    }

    private func startTap() {
        let types: [CGEventType] = [
            .mouseMoved, .leftMouseDown, .leftMouseUp, .leftMouseDragged,
            .rightMouseDown, .rightMouseUp, .rightMouseDragged,
            .otherMouseDown, .otherMouseUp, .otherMouseDragged, .scrollWheel,
        ]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, _ in
                // Auto-disable notifications must pass or input wedges open.
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    return Unmanaged.passUnretained(event)
                }
                if event.getIntegerValueField(.eventSourceUserData) == SyntheticInput.tag {
                    return Unmanaged.passUnretained(event)
                }
                return nil // physical mouse input — swallowed for the window
            },
            userInfo: nil
        ) else {
            // No tap (permission edge) — degrade to association-off + hidden
            // cursor: the drag path stays deterministic, clicks aren't caught.
            PelmetLog.log("mover: shield tap unavailable — degraded shield")
            return
        }
        self.tap = tap
        let thread = Thread { [weak self] in
            guard let self, let tap = self.tap else { return }
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            self.tapSource = source
            self.tapRunLoop = CFRunLoopGetCurrent()
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            self.armed.signal()
            CFRunLoopRun()
        }
        thread.qualityOfService = .userInteractive
        thread.name = "pelmet.drag-shield"
        thread.start()
        // Post no events until the tap is live — a race here would let the
        // first physical events through (harmless) but, worse, could let
        // deactivate() run before tapRunLoop exists and leak a live tap.
        if armed.wait(timeout: .now() + EngineTiming.dragShieldArmTimeout) == .timedOut {
            PelmetLog.log("mover: shield tap never armed — degraded shield")
        }
    }
}
