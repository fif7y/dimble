// AudioVideoPill.swift
// Apple's camera and screen-sharing pill: video effects, mic mode, stop
// sharing (#68). MenuBarAgent hosts it as `com.apple.menuextra.audiovideo`
// up to macOS 27.2 and as `av-module-pill-<uuid>` from 27.3 (see
// `modulePrefix`), one copy per display, and macOS takes it off the bar
// under ANY assertion,
// so Pelmet's Camera & mic item opens it instead: AppState drops the
// assertion under a picture of the bar, this presses the pill once it is
// back in the tree, and the assertion returns with the panel still up
// (Gab, 2026-09-25 13:33). Probed 13:40 with Pelmet quit: an AX press opens
// Control Center's panel (one window, layer 101) ~150ms later, and a second
// press closes it.
// With a SharePlay session and no call, the pill wears the SharePlay glyph
// and holds its controls; Control Center's separate FaceTime extra is
// pressed first in case a build shows one (none did, 2026-09-25).

import AppKit
import PelmetCore
import PelmetEngine

@MainActor
enum AudioVideoPill {
    nonisolated static let identifier = "com.apple.menuextra.audiovideo"
    /// macOS 27.3 (26C5035r) moved the pill onto the same machinery as the
    /// Live Activity pills: MenuBarAgent hosts it as an AXMenuBarItem with
    /// the identifier `av-module-pill-<uuid>` and the description "AV
    /// Controls", a UUID of that boot — so nothing but its prefix can match
    /// it. A key that ends in "-" is matched as a prefix (`matches`), and
    /// the old identifier stays for 27.2 and earlier.
    nonisolated static let modulePrefix = "av-module-pill-"
    /// The camera pill, newest naming first.
    nonisolated static let cameraIdentifiers = [modulePrefix, identifier]
    /// Apple's SharePlay icon, Control Center's FaceTime extra.
    nonisolated static let sharePlayIdentifier = "com.apple.menuextra.faceTime"

    /// A key matches an identifier outright, or as a prefix when it ends in
    /// "-" (the per-boot UUID on the 27.3 pill).
    nonisolated static func matches(_ key: String, _ id: String) -> Bool {
        key.hasSuffix("-") ? id.hasPrefix(key) : id == key
    }

    /// The key as a log reads it.
    nonisolated private static func name(_ key: String) -> String {
        key == modulePrefix
            ? "AV Controls"
            : key.replacingOccurrences(of: "com.apple.menuextra.", with: "")
    }
    nonisolated static let controlCenterID = "com.apple.controlcenter"

    private static var onBarAt = Date.distantPast
    private static var onBarWas = false

    /// Apple's pill is on the bar right now. From 27.3 it is a pill, which
    /// the engine's status-item walk never sees, and no assertion takes it
    /// off the bar any more — so this is the only way to know, and Pelmet's
    /// own indicator defers to it (`AppState.systemCameraPillVisible`).
    /// A shallow walk of MenuBarAgent's extras bar, behind a short cache:
    /// `extras.apply` can ask several times a second while the bar settles.
    static func onBar() -> Bool {
        if Date().timeIntervalSince(onBarAt) < 0.5 { return onBarWas }
        onBarAt = Date()
        onBarWas = false
        guard let agent = NSRunningApplication.runningApplications(withBundleIdentifier: PelmetBundle.agentID).first
        else { return false }
        var value: AnyObject?
        axCopyAttribute(AXUIElementCreateApplication(agent.processIdentifier), kAXExtrasMenuBarAttribute as CFString, &value)
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return false }
        var pills: [(AXUIElement, CGRect, String)] = []
        collect(unsafeBitCast(value, to: AXUIElement.self), depth: 4, matching: cameraIdentifiers, into: &pills)
        onBarWas = !pills.isEmpty
        return onBarWas
    }

    /// The panel Pelmet opened, while it is up. Never read at click time:
    /// the click on Pelmet's item dismisses it before the action runs, the
    /// way it dismisses Control Center's Focus panel (see ControlCenterFocus).
    private static var panelWindow: Int?
    private static var closedAt = Date.distantPast
    private static var watcher: Task<Void, Never>?

    /// The click only closed the panel Pelmet had opened: dismissed on the
    /// way down, a press now would open it again.
    static func clickClosedPanel() -> Bool {
        guard panelWindow != nil || Date().timeIntervalSince(closedAt) < 0.5 else { return false }
        panelWindow = nil
        closedAt = .distantPast
        watcher?.cancel()
        return true
    }

    /// Press the pill on the display under `point` once the dropped
    /// assertion has put it back, and wait for its panel. `identifiers` in
    /// order of preference: the first one back on the bar is pressed. False
    /// when none came back or no panel showed.
    static func open(near point: CGPoint, identifiers: [String] = cameraIdentifiers) async -> Bool {
        let display = ClockClickRelay.display(under: point)
        let wait = AppTiming.audioVideoPillWait, verify = AppTiming.clockPressVerify
        guard let window = await Task.detached(priority: .userInitiated, operation: {
            await press(on: display, identifiers: identifiers, wait: wait, verify: verify)
        }).value
        else { return false }
        panelWindow = window
        watch(window)
        return true
    }

    /// Clears `panelWindow` once Control Center has taken the panel down
    /// (a click elsewhere, Stop Sharing); one window-list read every 200ms,
    /// only while it is up.
    private static func watch(_ window: Int) {
        watcher?.cancel()
        watcher = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                if Task.isCancelled { return }
                if !panelWindows().contains(window) { break }
            }
            guard panelWindow == window else { return }
            panelWindow = nil
            closedAt = Date()
        }
    }

    nonisolated private static func press(on display: CGDirectDisplayID?, identifiers: [String], wait: TimeInterval, verify: TimeInterval) async -> Int? {
        guard let agent = NSRunningApplication.runningApplications(withBundleIdentifier: PelmetBundle.agentID).first
        else { return nil }
        let app = AXUIElementCreateApplication(agent.processIdentifier)
        let started = Date()
        var pill = find(in: app, on: display, identifiers: identifiers)
        let firstWalk = Int(-started.timeIntervalSinceNow * 1000)
        var walks = 1
        while pill == nil, Date().timeIntervalSince(started) < wait {
            try? await Task.sleep(for: .milliseconds(30))
            pill = find(in: app, on: display, identifiers: identifiers)
            walks += 1
        }
        let back = Int(-started.timeIntervalSinceNow * 1000)
        let names = identifiers.map(name)
        guard let (_, found) = pill else {
            PelmetLog.log("audiovideo: no \(names.joined(separator: "/")) in the bar after \(back)ms (\(walks) walks, first \(firstWalk)ms)")
            return nil
        }
        PelmetLog.log("audiovideo: \(name(found)) back at \(back)ms (\(walks) walks, first \(firstWalk)ms)")
        let before = panelWindows()
        for attempt in 1...2 {
            // Found again for each attempt: the first look lands a few tens
            // of ms after the assertion went, with the bar still re-laying
            // out around the pill that just came back, and 27.3 rebuilds the
            // element rather than moving it — a press on the one found then
            // is refused (-25200 etc.), while the same pill at rest presses
            // fine (measured 2026-11-06).
            guard let fresh = find(in: app, on: display, identifiers: identifiers)?.0 else {
                PelmetLog.log("audiovideo: press \(attempt) — the pill left the bar first")
                return nil
            }
            let error = AXUIElementPerformAction(fresh, kAXPressAction as CFString)
            let sent = error == .success
            let pressed = Date()
            let until = pressed.addingTimeInterval(verify)
            repeat {
                try? await Task.sleep(for: .milliseconds(30))
                if let window = panelWindows().subtracting(before).first {
                    PelmetLog.log("audiovideo: press \(attempt) → panel in \(Int(-pressed.timeIntervalSinceNow * 1000))ms")
                    return window
                }
            } while Date() < until
            PelmetLog.log("audiovideo: press \(attempt) \(sent ? "sent" : "refused (AXError \(error.rawValue))"), no panel")
        }
        return nil
    }

    /// The most preferred item back on the bar, the copy on `display` else
    /// on any display: a copy only exists while no assertion holds, and one
    /// without a frame is still arriving.
    nonisolated private static func find(in app: AXUIElement, on display: CGDirectDisplayID?, identifiers: [String]) -> (AXUIElement, String)? {
        var pills: [(AXUIElement, CGRect, String)] = []
        // The extras menu bar holds the live copy. The same pill also hangs
        // off MenuBarAgent's windows — four copies of the 27.3 AV pill, all
        // at the same frame — and a press on one of those is accepted and
        // does nothing (dimble-pill-three-copies, measured again 2026-11-06:
        // "press 1 sent, no panel" twice, then the Privacy fallback).
        var extras: AnyObject?
        axCopyAttribute(app, kAXExtrasMenuBarAttribute as CFString, &extras)
        if let extras, CFGetTypeID(extras) == AXUIElementGetTypeID() {
            collect(unsafeBitCast(extras, to: AXUIElement.self), depth: 6, matching: identifiers, into: &pills)
        }
        if pills.isEmpty { collect(app, depth: 8, matching: identifiers, into: &pills) }
        for id in identifiers {
            let copies = pills.filter { $0.2 == id }
            if let pill = copies.first(where: { ClockClickRelay.display(under: CGPoint(x: $0.1.midX, y: $0.1.midY)) == display }) ?? copies.first {
                return (pill.0, id)
            }
        }
        return nil
    }

    /// `keys` in order of preference; a pill is remembered under the key that
    /// matched it, so `find` can still prefer one naming over another.
    nonisolated private static func collect(_ element: AXUIElement, depth: Int, matching keys: [String], into pills: inout [(AXUIElement, CGRect, String)]) {
        var value: AnyObject?
        axCopyAttribute(element, kAXIdentifierAttribute as CFString, &value)
        if let id = value as? String, let key = keys.first(where: { matches($0, id) }) {
            if let frame = frame(of: element), frame.width > 0 { pills.append((element, frame, key)) }
            return
        }
        guard depth > 0 else { return }
        var children: AnyObject?
        axCopyAttribute(element, kAXChildrenAttribute as CFString, &children)
        for child in (children as? [AXUIElement]) ?? [] { collect(child, depth: depth - 1, matching: keys, into: &pills) }
    }

    nonisolated private static func frame(of element: AXUIElement) -> CGRect? {
        var position: AnyObject?, size: AnyObject?
        guard axCopyAttribute(element, kAXPositionAttribute as CFString, &position) == .success,
              axCopyAttribute(element, kAXSizeAttribute as CFString, &size) == .success,
              let position, let size else { return nil }
        var origin = CGPoint.zero, extent = CGSize.zero
        AXValueGetValue(position as! AXValue, .cgPoint, &origin)
        AXValueGetValue(size as! AXValue, .cgSize, &extent)
        return CGRect(origin: origin, size: extent)
    }

    /// Control Center's on-screen windows above the desktop: its panels.
    /// Either host's panel: Control Center drew it up to 27.2, and from 27.3
    /// the pill is MenuBarAgent's, so its card may be too. A press that
    /// opened a panel nobody here watches reads as "no panel" and sends the
    /// click to the Privacy fallback instead.
    nonisolated private static func panelWindows() -> Set<Int> {
        let pids = Set(([controlCenterID, PelmetBundle.agentID]).flatMap {
            NSRunningApplication.runningApplications(withBundleIdentifier: $0).map(\.processIdentifier)
        })
        guard !pids.isEmpty,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return [] }
        return Set(windows.compactMap { window in
            guard let pid = window[kCGWindowOwnerPID as String] as? Int32, pids.contains(pid),
                  (window[kCGWindowLayer as String] as? Int ?? 0) > 0 else { return nil }
            return window[kCGWindowNumber as String] as? Int
        })
    }
}
