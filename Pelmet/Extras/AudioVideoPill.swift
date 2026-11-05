// AudioVideoPill.swift
// Apple's camera and screen-sharing pill: video effects, mic mode, stop
// sharing (#68). MenuBarAgent hosts it as `com.apple.menuextra.audiovideo`,
// one copy per display, and macOS takes it off the bar under ANY assertion,
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
    /// Apple's SharePlay icon, Control Center's FaceTime extra.
    nonisolated static let sharePlayIdentifier = "com.apple.menuextra.faceTime"
    nonisolated static let controlCenterID = "com.apple.controlcenter"

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
    static func open(near point: CGPoint, identifiers: [String] = [identifier]) async -> Bool {
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
        let names = identifiers.map { $0.replacingOccurrences(of: "com.apple.menuextra.", with: "") }
        guard let (pill, found) = pill else {
            PelmetLog.log("audiovideo: no \(names.joined(separator: "/")) in the bar after \(back)ms (\(walks) walks, first \(firstWalk)ms)")
            return nil
        }
        PelmetLog.log("audiovideo: \(found.replacingOccurrences(of: "com.apple.menuextra.", with: "")) back at \(back)ms (\(walks) walks, first \(firstWalk)ms)")
        let before = panelWindows()
        for attempt in 1...2 {
            let sent = AXUIElementPerformAction(pill, kAXPressAction as CFString) == .success
            let pressed = Date()
            let until = pressed.addingTimeInterval(verify)
            repeat {
                try? await Task.sleep(for: .milliseconds(30))
                if let window = panelWindows().subtracting(before).first {
                    PelmetLog.log("audiovideo: press \(attempt) → panel in \(Int(-pressed.timeIntervalSinceNow * 1000))ms")
                    return window
                }
            } while Date() < until
            PelmetLog.log("audiovideo: press \(attempt) \(sent ? "sent" : "refused"), no panel")
        }
        return nil
    }

    /// The most preferred item back on the bar, the copy on `display` else
    /// on any display: a copy only exists while no assertion holds, and one
    /// without a frame is still arriving.
    nonisolated private static func find(in app: AXUIElement, on display: CGDirectDisplayID?, identifiers: [String]) -> (AXUIElement, String)? {
        var pills: [(AXUIElement, CGRect, String)] = []
        collect(app, depth: 8, matching: Set(identifiers), into: &pills)
        for id in identifiers {
            let copies = pills.filter { $0.2 == id }
            if let pill = copies.first(where: { ClockClickRelay.display(under: CGPoint(x: $0.1.midX, y: $0.1.midY)) == display }) ?? copies.first {
                return (pill.0, id)
            }
        }
        return nil
    }

    nonisolated private static func collect(_ element: AXUIElement, depth: Int, matching ids: Set<String>, into pills: inout [(AXUIElement, CGRect, String)]) {
        var value: AnyObject?
        axCopyAttribute(element, kAXIdentifierAttribute as CFString, &value)
        if let id = value as? String, ids.contains(id) {
            if let frame = frame(of: element), frame.width > 0 { pills.append((element, frame, id)) }
            return
        }
        guard depth > 0 else { return }
        var children: AnyObject?
        axCopyAttribute(element, kAXChildrenAttribute as CFString, &children)
        for child in (children as? [AXUIElement]) ?? [] { collect(child, depth: depth - 1, matching: ids, into: &pills) }
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
    nonisolated private static func panelWindows() -> Set<Int> {
        guard let pid = NSRunningApplication.runningApplications(withBundleIdentifier: controlCenterID).first?.processIdentifier,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return [] }
        return Set(windows.compactMap { window in
            guard (window[kCGWindowOwnerPID as String] as? Int32) == pid,
                  (window[kCGWindowLayer as String] as? Int ?? 0) > 0 else { return nil }
            return window[kCGWindowNumber as String] as? Int
        })
    }
}
