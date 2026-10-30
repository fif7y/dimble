// LiveMirror.swift
// Live mode (the "Show Live Activities" setting, on by default): while a Live
// Activity runs, the pill shows beside the « and the hidden icons stay hidden.
//
// MenuBarAgent takes the pill off the bar under any hide assertion, so live
// mode holds none: the assertion goes (`engine.holdLift`), the icons it hid
// come back onto the bar, and a picture of the concealed bar, taken just
// before, covers [left limit, «) on every display. Right of the « the bar is
// live: with no assertion Sound, Battery and the like come back there and
// push the « left, so the cover's end follows it.
//
// The pill is drawn by Dimble, from one still: the pill's frame and its
// children are read over AX (MenuBarAgent, subrole AXLiveActivity); a still
// of the pill (Pelmet's own windows and foreign surfaces left out) keeps its
// capsule and its logos, the text children are blanked out of it and drawn
// live by Dimble at their AX frames. An AXObserver on the pill's elements
// says when a text or the layout changes, with a slow poll behind it. The
// still is retaken only when the image children change (count, description,
// relative frames) or the pill's width does. A click on the mirror is an AX
// press on the real pill. A click on the « lifts the cover (the real bar,
// hidden icons and pill, shows) and a second one, or ten seconds, puts it
// back. When the activity ends the assertion comes back under the cover,
// which lifts once the bar beneath has settled
// (`TransitionCoordinator.endLive`).
//
// It never asks for Screen Recording: without it live mode waits and the
// pill stays off the bar. Turning the setting off leaves live mode the way
// an ended activity does. Every step logs with a `livemirror:` prefix.

import AppKit
import ApplicationServices
import PelmetCore
import PelmetEngine
import QuartzCore
import ScreenCaptureKit

// MARK: - The pill over AX

/// One copy of the pill in MenuBarAgent's tree (one per display).
nonisolated struct PillCopy: @unchecked Sendable {
    let element: AXUIElement
    /// CG global, top-left origin.
    let frame: CGRect
    let text: String
    let name: String
}


/// One element under the pill.
nonisolated struct ElementBox: @unchecked Sendable { let list: [AXUIElement] }

nonisolated struct PillNode: @unchecked Sendable {
    let element: AXUIElement
    let role: String
    /// AXIdentifier, else AXDescription.
    let key: String
    let value: String
    /// CG global.
    let frame: CGRect
    let isLeaf: Bool
}

nonisolated struct PillTree: @unchecked Sendable {
    let pill: AXUIElement
    let frame: CGRect
    let nodes: [PillNode]

    /// A leaf that covers the pill (its hit area, "Expanded"): not content.
    func isBackdrop(_ node: PillNode) -> Bool {
        node.isLeaf && node.role != "AXStaticText" && node.frame.width >= frame.width * 0.9 && node.frame.height >= frame.height * 0.9
    }
    var texts: [PillNode] { textNodes.sorted { $0.frame.minX < $1.frame.minX } }
    /// The texts in tree order (what the quick read walks).
    var textNodes: [PillNode] { nodes.filter { $0.role == "AXStaticText" && $0.frame.width > 0 } }
    /// The same tree with the texts' values replaced, in tree order: what a
    /// quick read (the pill's frame and each value, a handful of reads
    /// against the whole tree's hundred) found.
    func patched(with values: [String]) -> PillTree {
        var i = 0
        let out = nodes.map { node -> PillNode in
            guard node.role == "AXStaticText", node.frame.width > 0, i < values.count else { return node }
            defer { i += 1 }
            return PillNode(element: node.element, role: node.role, key: node.key, value: values[i], frame: node.frame, isLeaf: node.isLeaf)
        }
        return PillTree(pill: pill, frame: frame, nodes: out)
    }
    /// Logos and glyphs: every other leaf with a frame.
    var images: [PillNode] {
        nodes.filter { $0.isLeaf && $0.role != "AXStaticText" && $0.frame.width > 0 && !isBackdrop($0) }.sorted { $0.frame.minX < $1.frame.minX }
    }
    /// What the pill looks like: its frame joined with the hit area's.
    var visual: CGRect {
        nodes.filter(isBackdrop).reduce(frame) { $0.union($1.frame) }
    }
    /// What forces a new still: the image children and the pill's width.
    struct Look {
        var width: CGFloat
        var items: [(key: String, rect: CGRect)]

        /// Why `self` needs a new still after `old`, or nil: the pill's width,
        /// the image children (count, key) or a relative frame moved by more
        /// than a point (AX frames drift by half a point as the bar shifts).
        func change(from old: Look) -> String? {
            if abs(width - old.width) > 1 { return "pill width \(fmt(old.width)) → \(fmt(width))" }
            if items.count != old.items.count { return "image children \(old.items.count) → \(items.count)" }
            for (new, was) in zip(items, old.items) {
                if new.key != was.key { return "image child \(was.key) → \(new.key)" }
                let r = new.rect, o = was.rect
                if abs(r.minX - o.minX) > 1 || abs(r.minY - o.minY) > 1 || abs(r.width - o.width) > 1 || abs(r.height - o.height) > 1 {
                    return "\(new.key) frame \(fmt(o.minX)),\(fmt(o.minY)),\(fmt(o.width))x\(fmt(o.height)) → \(fmt(r.minX)),\(fmt(r.minY)),\(fmt(r.width))x\(fmt(r.height))"
                }
            }
            return nil
        }
        private func fmt(_ v: CGFloat) -> String { String(format: "%.1f", v) }
    }
    var look: Look {
        Look(width: frame.width, items: images.map { ($0.key, CGRect(x: $0.frame.minX - frame.minX, y: $0.frame.minY - frame.minY, width: $0.frame.width, height: $0.frame.height)) })
    }
}

/// One drawn text: its value and its frame (CG global).
nonisolated struct TextBit: @unchecked Sendable {
    var value: String
    var frame: CGRect
}

/// "m:ss" and "h:mm:ss" texts, the clocks of a timer pill.
nonisolated enum ClockText {
    /// The seconds a clock text shows; nil for anything that is not one.
    static func seconds(_ text: String) -> Int? {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard (2...3).contains(parts.count),
              parts.allSatisfy({ !$0.isEmpty && $0.count <= 2 && $0.allSatisfy { $0.isASCII && $0.isNumber } })
        else { return nil }
        let n = parts.compactMap { Int($0) }
        guard n.count == parts.count else { return nil }
        return n.count == 2 ? n[0] * 60 + n[1] : n[0] * 3600 + n[1] * 60 + n[2]
    }

    /// `total` seconds in the form `like` uses (hours only when it has them).
    static func text(_ total: Int, like: String) -> String {
        let s = max(0, total)
        if like.split(separator: ":").count == 3 || s >= 3600 { return String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60) }
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// How one pill's clock text moves: which text it is, which way, and when
/// it last changed, so the mirror reads it just after each change instead
/// of on a poll, and carries it on by itself while the pill is not there.
nonisolated struct ClockState {
    /// Which of the pill's texts (in left-to-right order) is the clock.
    var index: Int?
    /// +1 counting up, -1 counting down, 0 not seen moving by a second.
    var dir = 0
    /// The clock's text and seconds at `tick`.
    var text = ""
    var seconds = 0
    /// When that value appeared on the real pill (an estimate), and whether
    /// the estimate is good to ~30 ms (a locked clock is read on it).
    var tick: Date?
    var locked = false
    /// The change a locked read is waiting for, and when the next read is due.
    var due: Date?
    var next: Date?

    /// The clock text `now`, counted on from `tick`; nil when its direction
    /// is not known.
    func extrapolated(at now: Date) -> String? {
        guard dir != 0, let tick else { return nil }
        let n = max(0, Int(floor(now.timeIntervalSince(tick) + 0.001)))
        return ClockText.text(seconds + dir * n, like: text)
    }
}

nonisolated enum PillProbe {
    static let identifierPrefix = "live-activity-pill-"
    /// Every distinct pill on a display, left to right: macOS shows one pill
    /// per running activity, each with its own AX element (and a copy per bar).
    static func pills(in bounds: CGRect) -> [PillCopy] {
        var out: [PillCopy] = []
        for copy in copies() where bounds.contains(CGPoint(x: copy.frame.midX, y: copy.frame.midY)) {
            // Each bar window holds its own element for the same pill, and
            // while the capture indicator moves things the two can stand a
            // few points apart: one description within 30 pt is one pill.
            if out.contains(where: { $0.name == copy.name && abs($0.frame.minX - copy.frame.minX) < 30 }) { continue }
            out.append(copy)
        }
        return out.sorted { $0.frame.minX < $1.frame.minX }
    }

    /// A pill's identity is its AXDescription ("Sports", "myVW"), the one
    /// thing that names the activity in AX; a second pill with the same
    /// description gets " #2".
    static func keys(of pills: [PillCopy]) -> [String] {
        var counts: [String: Int] = [:]
        return pills.map { pill in
            counts[pill.name, default: 0] += 1
            return counts[pill.name]! == 1 ? pill.name : "\(pill.name) #\(counts[pill.name]!)"
        }
    }

    /// Every element read gets its own short messaging timeout: the one set on
    /// the application element is not inherited by the children (the default
    /// is 6 s), and a stalled MenuBarAgent must not hold a read for minutes.
    static let axTimeout: Float = 0.6

    static func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
        AXUIElementSetMessagingTimeout(element, axTimeout)
        var value: AnyObject?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    static func frame(of element: AXUIElement) -> CGRect? {
        guard let position = attribute(element, kAXPositionAttribute), let size = attribute(element, kAXSizeAttribute)
        else { return nil }
        var origin = CGPoint.zero, extent = CGSize.zero
        AXValueGetValue(position as! AXValue, .cgPoint, &origin)
        AXValueGetValue(size as! AXValue, .cgSize, &extent)
        return CGRect(origin: origin, size: extent)
    }

    /// The compact text the pill shows: its static texts, two levels down.
    static func text(of element: AXUIElement, depth: Int = 4) -> String {
        var parts: [String] = []
        for child in (attribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? [] {
            if (attribute(child, kAXRoleAttribute) as? String) == "AXStaticText" {
                if let value = attribute(child, kAXValueAttribute) as? String { parts.append(value) }
            } else if depth > 1 {
                let inner = text(of: child, depth: depth - 1)
                if !inner.isEmpty { parts.append(inner) }
            }
        }
        return parts.joined(separator: " ")
    }

    enum Quick { case same, values([String]), reread }

    /// The cheap read of a pill whose tree is in hand: its frame and each
    /// text's value (three or four reads, against the whole tree's hundred).
    /// The values may have moved (a clock ticking); a moved or restructured
    /// pill takes the full read.
    static func quick(_ tree: PillTree, of element: AXUIElement) -> Quick {
        guard CFEqual(tree.pill, element), let frame = frame(of: element),
              abs(frame.minX - tree.frame.minX) < 0.05, abs(frame.minY - tree.frame.minY) < 0.05, abs(frame.width - tree.frame.width) < 0.05
        else { return .reread }
        let nodes = tree.textNodes
        var values: [String] = []
        for node in nodes {
            guard let value = attribute(node.element, kAXValueAttribute) as? String else { return .reread }
            values.append(value)
        }
        return values == nodes.map(\.value) ? .same : .values(values)
    }

    /// Frame and text of a copy already found; nil when it is gone.
    static func read(_ element: AXUIElement) -> (frame: CGRect, text: String)? {
        guard let frame = frame(of: element), frame.width > 0 else { return nil }
        return (frame, text(of: element))
    }

    /// Frames of every element with this identifier in the agent's tree
    /// (CG global): the clock, once per bar copy.
    static func frames(ofIdentifier wanted: String) -> [CGRect] {
        guard let agent = NSRunningApplication.runningApplications(withBundleIdentifier: PelmetBundle.agentID).first
        else { return [] }
        let app = AXUIElementCreateApplication(agent.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.6)
        var found: [CGRect] = []
        func walk(_ element: AXUIElement, _ depth: Int) {
            if let id = attribute(element, kAXIdentifierAttribute) as? String, id == wanted {
                if let frame = frame(of: element), frame.width > 0 { found.append(frame) }
                return
            }
            guard depth > 0 else { return }
            for child in (attribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? [] { walk(child, depth - 1) }
        }
        walk(app, 8)
        return found
    }

    /// The pill's children: texts, logos, the hit area. Nil when it is gone.
    /// MenuBarAgent's AX application element, and the debug pill host's (the
    /// harness, `pelmet.debug.pillHost`) when set: both show pills.
    static func agentApps() -> [AXUIElement] {
        var ids = LiveActivityStatus.debugHostOnly ? [] : [PelmetBundle.agentID]
        if let host = LiveActivityStatus.debugHost { ids.append(host) }
        return ids.compactMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0).first }
            .map { AXUIElementCreateApplication($0.processIdentifier) }
    }

    /// The right edge of the app menus the menu-bar-owning app `pid` shows
    /// inside `bounds` (a display), or nil when it shows none there. A cover
    /// must start right of it: a menu under a picture is neither live nor
    /// clickable.
    static func menusRight(pid: pid_t, in bounds: CGRect) -> CGFloat? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, axTimeout)
        guard let bar = attribute(app, kAXMenuBarAttribute) else { return nil }
        var right: CGFloat?
        for item in (attribute(bar as! AXUIElement, kAXChildrenAttribute) as? [AXUIElement]) ?? [] {
            guard let f = frame(of: item), f.width > 0, bounds.contains(CGPoint(x: f.midX, y: f.midY)) else { continue }
            right = max(right ?? f.maxX, f.maxX)
        }
        return right
    }

    /// MenuBarAgent's AX application element.
    static func agentApp() -> AXUIElement? {
        NSRunningApplication.runningApplications(withBundleIdentifier: PelmetBundle.agentID).first
            .map { AXUIElementCreateApplication($0.processIdentifier) }
    }

    /// Whether the expanded card is on screen: a MenuBarAgent window below
    /// the bar (the bar's own sits at y 0) holding a live-activity group.
    /// The card's window stays listed for the whole collapse (~0.8 s).
    static func cardIsOpen() -> Bool { cardProbe().open }

    /// The top edge (CG global) of the display `frame` sits on: a bar is at
    /// y 0 on the primary and above or below it on any other display, so
    /// "below the bar" is measured from its own display's top.
    static func displayTop(of frame: CGRect) -> CGFloat {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(16, &ids, &count) == .success else { return 0 }
        let point = CGPoint(x: frame.midX, y: frame.minY + 1)
        let bounds = ids.prefix(Int(count)).map { CGDisplayBounds($0) }
        return (bounds.first { $0.contains(point) } ?? bounds.first { $0.minX <= frame.midX && frame.midX < $0.maxX })?.minY ?? 0
    }

    /// The same read with what it saw: whose card is open (the group's
    /// AXDescription is its pill's, "Sports"), and the agent's windows with
    /// their frames, a star on the one holding the live-activity group.
    static func cardProbe() -> (open: Bool, owners: [String], detail: String) {
        let apps = agentApps()
        guard !apps.isEmpty else { return (false, [], "no agent") }
        func owner(_ element: AXUIElement, _ depth: Int) -> String? {
            if (attribute(element, kAXSubroleAttribute) as? String) == "AXLiveActivity" {
                return (attribute(element, kAXDescriptionAttribute) as? String) ?? ""
            }
            guard depth < 4 else { return nil }
            for child in (attribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? [] {
                if let found = owner(child, depth + 1) { return found }
            }
            return nil
        }
        var owners: [String] = []
        var parts: [String] = []
        var status = "ok"
        for app in apps {
            AXUIElementSetMessagingTimeout(app, 0.6)
            var raw: AnyObject?
            let error = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &raw)
            if error != .success { status = "err \(error.rawValue)" }
            for window in (raw as? [AXUIElement]) ?? [] {
                guard let frame = frame(of: window) else { parts.append("?"); continue }
                // The harness's card is a plain window titled for its pill.
                let harness = (attribute(window, kAXTitleAttribute) as? String).flatMap { $0.hasPrefix("harness-card-") ? String($0.dropFirst(13)) : nil }
                let who = frame.minY >= displayTop(of: frame) + 20 ? (owner(window, 0) ?? harness) : nil
                if let who { owners.append(who) }
                parts.append("\(Int(frame.minX)),\(Int(frame.minY)) \(Int(frame.width))x\(Int(frame.height))\(who.map { "*\($0)" } ?? "")")
            }
        }
        return (!owners.isEmpty, owners, "ax \(status), \(parts.count) window(s) [\(parts.joined(separator: "; "))]")
    }

    /// Presses the pill that sits in `bounds`, looked up fresh (the element
    /// in hand may be a copy the agent has since replaced); the one in hand
    /// is the fallback. Returns what happened, for the log, and the fresh copy.
    static func press(in bounds: CGRect, named: String?, kept: AXUIElement?) -> (result: String, fresh: PillCopy?) {
        let fresh = pills(in: bounds).first { named == nil || $0.name == named }
        var notes: [String] = []
        if let fresh {
            AXUIElementSetMessagingTimeout(fresh.element, axTimeout)
            let error = AXUIElementPerformAction(fresh.element, kAXPressAction as CFString)
            if error == .success { return ("success (fresh pill)", fresh) }
            notes.append("fresh pill error \(error.rawValue)")
        } else {
            notes.append("no pill found")
        }
        if let kept {
            AXUIElementSetMessagingTimeout(kept, axTimeout)
            let error = AXUIElementPerformAction(kept, kAXPressAction as CFString)
            notes.append(error == .success ? "kept pill success" : "kept pill error \(error.rawValue)")
        }
        return (notes.joined(separator: ", "), fresh)
    }

    static func readTree(_ pill: AXUIElement) -> PillTree? {
        guard let frame = frame(of: pill), frame.width > 0 else { return nil }
        var nodes: [PillNode] = []
        // A stalled agent answers each read after the timeout: the whole tree
        // gets 1.5 s, then it is read as unreadable (the loop must not hang).
        let deadline = Date().addingTimeInterval(1.5)
        func walk(_ element: AXUIElement, _ depth: Int) {
            for child in (attribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? [] {
                guard Date() < deadline else { return }
                let role = (attribute(child, kAXRoleAttribute) as? String) ?? ""
                let id = (attribute(child, kAXIdentifierAttribute) as? String) ?? ""
                let description = (attribute(child, kAXDescriptionAttribute) as? String) ?? ""
                let value = role == "AXStaticText" ? ((attribute(child, kAXValueAttribute) as? String) ?? "") : ""
                let kids = depth < 6 ? ((attribute(child, kAXChildrenAttribute) as? [AXUIElement]) ?? []) : []
                nodes.append(PillNode(element: child, role: role, key: id.isEmpty ? description : id, value: value,
                                      frame: self.frame(of: child) ?? .zero, isLeaf: kids.isEmpty))
                if !kids.isEmpty { walkKids(kids, depth + 1) }
            }
        }
        func walkKids(_ kids: [AXUIElement], _ depth: Int) {
            for child in kids {
                guard Date() < deadline else { return }
                let role = (attribute(child, kAXRoleAttribute) as? String) ?? ""
                let id = (attribute(child, kAXIdentifierAttribute) as? String) ?? ""
                let description = (attribute(child, kAXDescriptionAttribute) as? String) ?? ""
                let value = role == "AXStaticText" ? ((attribute(child, kAXValueAttribute) as? String) ?? "") : ""
                let sub = depth < 6 ? ((attribute(child, kAXChildrenAttribute) as? [AXUIElement]) ?? []) : []
                nodes.append(PillNode(element: child, role: role, key: id.isEmpty ? description : id, value: value,
                                      frame: self.frame(of: child) ?? .zero, isLeaf: sub.isEmpty))
                if !sub.isEmpty { walkKids(sub, depth + 1) }
            }
        }
        walk(pill, 0)
        if Date() >= deadline { return nil }
        return PillTree(pill: pill, frame: frame, nodes: nodes)
    }

    /// Every pill in the agent's tree.
    static func copies() -> [PillCopy] {
        var found: [PillCopy] = []
        for app in agentApps() {
            AXUIElementSetMessagingTimeout(app, 0.6)
            // The pills are the bar windows' own children (app > window > item):
            // the items' own children are never read.
            collect(app, depth: 2, into: &found)
        }
        return found
    }

    private static func collect(_ element: AXUIElement, depth: Int, into found: inout [PillCopy]) {
        if let id = attribute(element, kAXIdentifierAttribute) as? String, id.hasPrefix(identifierPrefix) {
            if let read = read(element) {
                let name = (attribute(element, kAXDescriptionAttribute) as? String) ?? id
                found.append(PillCopy(element: element, frame: read.frame, text: read.text, name: name))
            }
            return
        }
        guard depth > 0 else { return }
        for child in (attribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? [] {
            collect(child, depth: depth - 1, into: &found)
        }
    }
}


// MARK: - Live mode

@MainActor
final class LiveMirror {
    /// The "Show Live Activities" setting.
    private var enabled: Bool { appState?.settings.showLiveActivities ?? false }

    private static let pollInterval = Duration.milliseconds(250)
    /// The AX fallback read, in ticks: the observer is the way in, this is the net.
    private static let fallbackEvery = 8
    /// Points the mirror keeps clear of the cover's right end.
    private static let gap: CGFloat = 3
    /// Between two mirrors when the real pills' own gap can't be measured.
    private static let pillGap: CGFloat = 8
    private static let coverSafety: TimeInterval = 3600
    private static let liftedCoverReturn: TimeInterval = 10

    /// One real pill's mirror: the still with its texts blanked, and the
    /// texts drawn over it from AX, in a container inside the cover.
    private final class PillMirror {
        let key: String
        var copy: PillCopy
        var tree: PillTree?
        var look: PillTree.Look?
        /// The texts as drawn, and the AX texts as of the last still (a change
        /// in them is what the text-triggered snapshot compares against).
        var texts: [String] = []
        var snapTexts: [String]?
        var textChangedAt: Date?
        /// When a text change was last logged, and how many came since: a
        /// ticking timer is one line every 10 s, not one a second.
        var textLoggedAt = Date.distantPast
        var textHeld = 0
        /// A changed look waits until two reads half a second apart agree: the
        /// pill slides when the capture indicator lights or goes out, and a
        /// still taken mid-slide has a cut edge.
        var lookCandidate: (look: PillTree.Look, since: Date)?
        /// Where the pill stood when it was first seen (or last moved) while it
        /// has no still: the first still waits until it has stood there 0.2 s,
        /// a pill still sliding in was caught half-way by the first capture.
        var placeCandidate: (frame: CGRect, since: Date, first: Date)?
        var misses = 0
        /// Discovery passes that did not find it (two in a row end it).
        var absent = 0
        /// No room left of the « for it.
        var dropped = false
        let firstSeen = Date()
        let container = CALayer()
        let base = CALayer()
        var textLayers: [CATextLayer] = []
        var attached = false
        /// CG global: the pill's visual; Cocoa global: where its mirror stands.
        var visual: CGRect?
        var global: NSRect?
        /// Drawn from memory (the kept still, the last texts) while its real
        /// pill is not on the bar yet: nothing is read for it, nothing is
        /// pressed, and it is adopted by the pill's discovery.
        var provisional = false
        /// Whether the container is meant to be on screen (the end state of
        /// its motion).
        var shown = false
        /// The texts as last drawn, with their frames: what a memory keeps.
        var bits: [TextBit] = []
        /// The raw text values as last drawn, and when the pill was last read.
        var values: [String] = []
        var lastRead: Date?
        var clock = ClockState()
        /// A read of this mirror's pill is under way (the clock loop's).
        var reading = false

        init(key: String, copy: PillCopy) {
            self.key = key; self.copy = copy
            container.addSublayer(base)
            container.isHidden = true
        }
    }

    /// One display's share of live mode.
    private final class Side {
        let id: CGDirectDisplayID
        let screen: NSScreen
        var scDisplay: SCDisplay
        /// A display set to show every icon (round 7c): the bar stays anchored
        /// out on it, Hidden icons included. Live mode covers only what the
        /// assertion hides there (the Always Hidden run and the pills' spot),
        /// which ends at `runEdge`, the left edge of the Hidden icons.
        var showsAll = false
        var runEdge: CGFloat?
        var alwaysRun: ClosedRange<CGFloat>?
        var runNote = ""
        var picture: ConcealGhostOverlay.BarSnapshot?
        var cover: ConcealGhostOverlay.GhostSet?
        var coverMinX: CGFloat = 0
        var coverMaxX: CGFloat = 0
        /// The right edge of the frontmost app's menus on this display (0:
        /// none shown): no cover starts left of it.
        var menusRight: CGFloat = 0
        /// One mirror per running activity, in the order macOS shows the pills
        /// (left to right).
        var mirrors: [PillMirror] = []
        var needsDiscovery = false
        var droppedNote = ""
        var placedNote = ""
        var snapping = false
        var snapshots = 0
        /// While seeded mirrors wait for their pills: where the « will stand
        /// once the extras are back (the mirrors are laid out to it).
        var predictedRight: CGFloat?
        /// The icons the concealed bar shows out on their own beside the «
        /// (a show rule's Battery): where they ran when the picture was
        /// taken, and that run cut from it into a layer of the cover, laid
        /// out against the « like the mirrors. They keep beside it when it
        /// moves (an extra coming or going), and the mirrors stand left of
        /// them, where macOS puts the pills.
        var aloneRun: ClosedRange<CGFloat>?
        var alone: CALayer?
        var aloneAttached = false
        /// When the picture was taken, and under which backdrop.
        var pictureAt = Date()
        var pictureGeneration = 0
        /// The last still of any kind: the slow graphic refresh counts from it.
        var lastSnapshotAt = Date()
        /// The snapshot time the last "skipped" line was written for: one line
        /// per rate-limit window, not one per read.
        var skippedWindow: Date?
        /// The one trailing snapshot waiting for the rate limit to pass.
        var trailing: Task<Void, Never>?

        init(id: CGDirectDisplayID, screen: NSScreen, scDisplay: SCDisplay) {
            self.id = id; self.screen = screen; self.scDisplay = scDisplay
        }
        var scale: CGFloat { screen.backingScaleFactor }
        var bounds: CGRect { CGDisplayBounds(id) }
    }

    private weak var appState: AppState?
    private var sides: [Side] = []
    private(set) var isActive = false
    private var entering = false, exiting = false
    private var wanted = false
    /// What the watcher last said, whatever the setting: turning the setting
    /// on picks it up (`settingChanged`).
    private var reported = (running: false, count: 0)
    private var loop: Task<Void, Never>?
    private var lastChevron: NSRect?
    private var coverLifted = false
    /// Hidden is out under live mode (a hover or the «): the covers end at
    /// the Always Hidden icons, the assertion stays down, nothing on the bar
    /// moves. `outSince`: when the pointer left the bar.
    private struct HiddenOut { let reason: RevealReason; var outSince: Date? }
    private var hiddenOut: HiddenOut?
    private var liftedReturn: Task<Void, Never>?
    private var lastBlockedWhy = ""
    private var lastSummaryAt = Date()
    private var tickCount = 0
    private var activityCount = 0
    private var lookEagerlyUntil = Date.distantPast
    private var screenObserver: NSObjectProtocol?
    private var spaceObserver: NSObjectProtocol?
    private var orderKeeper: Task<Void, Never>?
    /// A reveal asked after the assertion dropped, while live mode starts:
    /// run once it has settled (or, if the start gives up, at once).
    enum Replay { case toggle, reveal, toggleAll }
    private var pendingReveal: (reason: RevealReason, sections: Set<PelmetCore.Section>, how: Replay)?
    private var themeObserver: NSObjectProtocol?
    private var activateObserver: NSObjectProtocol?
    /// Before the assertion drops nothing is held: a reveal that comes then
    /// goes first and the start stands down (`standDown`). After it, the
    /// reveal waits for the start to settle.
    private var assertionDropped = false
    private var standDown = false
    /// The displays changed while a start or a retake ran.
    private var displaysChangedWhileEntering = false
    /// No pill to mirror for a while: live mode leaves, and does not come
    /// back for a while (longer each time in a row).
    private var noPillSince: Date?
    private var emptyStrikes = 0
    private var retryNotBefore = Date.distantPast
    /// Why live mode holds off until `retryNotBefore`, for the log.
    private var holdOffWhy = ""
    /// Starts called off for a reason that would call off the next one too
    /// (`abort(holdOff:)`), in a row: each waits longer, up to two minutes.
    private var abortStrikes = 0
    static let noPillGrace: TimeInterval = 10

    /// A reveal the live mirror handed the bar to (`beginHandOver`): the
    /// pill and the mirror are away, the cover stays up until the reveal's
    /// swap has landed (`revealLanded`), and live mode comes back by the
    /// loop once the re-hide has rested.
    private var handingOver = false
    private var kicking = false
    private var released = false
    private var handOverWatchdog: Task<Void, Never>?
    private var lastHoverNote = Date.distantPast

    /// Counts what makes a picture of the bare bar untrue (a Space, the
    /// appearance, the displays), also while live mode is off.
    private var backdropGeneration = 0
    /// The mirrors are on their way out (an exit, a hand-over): a layout
    /// leaves their visibility alone.
    private var mirrorsLeaving = false
    private var clockLoop: Task<Void, Never>?
    /// A retake is under way (the pictures again, the mirrors staying).
    private var retaking = false

    /// What a hand-over to a reveal takes along, so the return can draw the
    /// mirrors at once: each pill's size, texts and clock, where the « stood,
    /// and the pictures of the bare bar.
    private struct Remembered {
        var key: String
        var name: String
        var visual: CGRect
        var bits: [(value: String, rel: CGRect)]
        var clock: ClockState
    }
    private struct Memory { var chevronMinX: CGFloat; var pills: [Remembered] }
    private var remembered: [CGDirectDisplayID: Memory] = [:]
    private struct KeptPicture { var picture: ConcealGhostOverlay.BarSnapshot; var generation: Int; var at: Date }
    private var keptPictures: [CGDirectDisplayID: KeptPicture] = [:]
    /// A kept picture of the bare bar serves a return this long (the
    /// backdrop's changes it can know of are counted by `backdropGeneration`).
    static let pictureMaxAge: TimeInterval = 180

    /// The last still of each display, kept across a reveal (not across the
    /// end of live mode): reused when the pill's look is unchanged, so the
    /// return to live mode takes no second capture.
    private struct KeptStill { var look: PillTree.Look; var image: CGImage; var at: Date; var texts: [String] }
    private var kept: [String: KeptStill] = [:]
    private func keptKey(_ side: Side, _ mirror: PillMirror) -> String { keptKey(side, key: mirror.key) }
    private func keptKey(_ side: Side, key: String) -> String { "\(side.id)|\(key)" }
    /// Drawn graphics (a ring, a bar) usually move with the pill's text. A
    /// text change takes a new still, at most once per interval per display
    /// (a ticking countdown must not keep the capture dot lit); changes inside
    /// the window coalesce into one trailing snapshot. Kept across live mode.
    static let textSnapshotInterval: TimeInterval = 30
    /// How long a changed look must hold still before a new still is taken.
    static let lookSettle: TimeInterval = 0.45
    /// A pill with no still waits until it stands still this long.
    static let firstSettle: TimeInterval = 0.2
    /// A pill with a graphic area (a ring, a bar, a logo) gets a new still at
    /// least this often even when nothing the AX tree shows has changed: a
    /// progress bar can move without a text. One capture (~0.28 s of the dot,
    /// ~50 ms of work) per interval, none when a text-triggered still came.
    static let graphicRefresh: TimeInterval = 300
    private var textSnapAt: [CGDirectDisplayID: Date] = [:]

    init(appState: AppState) { self.appState = appState }

    // MARK: Entry points

    /// A conceal landed (the re-hide after a reveal): live mode that waits to
    /// come back looks now, not at the loop's next quarter second.
    func kick() {
        guard enabled, wanted, loop != nil, !isActive, !entering, !exiting, !handingOver, !kicking else { return }
        kicking = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.kicking = false }
            guard self.wanted, !self.isActive, !self.entering else { return }
            if await self.cannotEnter() == nil {
                self.lastBlockedWhy = ""
                await self.enter()
            }
        }
    }

    func activitiesChanged(running: Bool, count: Int = 0) {
        reported = (running, count)
        // With the setting off the watcher may still run (the item follows
        // it): live mode takes no part.
        follow(running: running && enabled, count: enabled ? count : 0, why: "activity ended")
    }

    /// The setting changed (`AppState.settingsChanged`, so often): turned
    /// on, live mode picks up what the watcher last said; turned off, it
    /// leaves the way an ended activity does.
    func settingChanged() {
        let running = enabled && reported.running
        guard running != wanted else { return }
        PelmetLog.log("livemirror: the setting turned \(enabled ? "on" : "off")")
        follow(running: running, count: enabled ? reported.count : 0, why: "setting turned off")
    }

    private func follow(running: Bool, count: Int, why: String) {
        if running != wanted { PelmetLog.log("livemirror: activities \(running ? "running" : "none") — wanted \(running)") }
        wanted = running
        // An activity started or ended: the pills are looked for every tick for
        // a few seconds (its pill shows a moment after the log line).
        if count != activityCount {
            if isActive { PelmetLog.log("livemirror: activities \(activityCount) → \(count), looking for the pills") }
            if count > activityCount { retryNotBefore = .distantPast; emptyStrikes = 0; abortStrikes = 0 }
            activityCount = count
            lookEagerlyUntil = Date().addingTimeInterval(3)
        }
        // (Nothing runs and no loop: nothing to start, or to stop again.)
        if loop == nil, running { startLoop() }
        // The last activity ended: the mirror leaves now, not at the loop's
        // next tick (`exit` ignores a second call).
        if !running, isActive, !entering, !exiting, !handingOver {
            Task { @MainActor [weak self] in await self?.exit(why) }
        }
    }

    /// A reveal asked for while live mode has the bar. Every reveal that
    /// needs the bar (the «, a hover, the hotkey, Apply, the editor, a
    /// policy, an item asked for in the bar) hands it to the normal reveal:
    /// the pill and the mirror go, the cover stays up while the one swap
    /// lands, and live mode comes back after the re-hide. A reveal that
    /// opens the panel needs no hand-over: the bar stays as it is. A hover on
    /// the mirror itself is no reveal (the pointer is on its way to a click).
    /// While live mode starts: before the assertion drops the reveal goes
    /// first and the start stands down; after it the reveal waits for the
    /// start to settle.
    func intercepts(reveal reason: RevealReason, sections: Set<PelmetCore.Section> = [.hidden], how: Replay = .reveal) -> Bool {
        guard isActive else { return false }
        if handingOver || exiting { return false }
        if entering {
            if !assertionDropped {
                standDown = true
                appState?.transitions.liveModeActive = false
                PelmetLog.log("livemirror: reveal(\(reason)) asked while live mode prepares — nothing held yet, the start stands down and the reveal runs")
                return false
            }
            pendingReveal = (reason, sections, how)
            PelmetLog.log("livemirror: reveal(\(reason)) asked while live mode starts — it runs once live mode has settled")
            return true
        }
        if opensPanel(reason) {
            if Date().timeIntervalSince(lastHoverNote) > 2 {
                lastHoverNote = Date()
                PelmetLog.log("livemirror: reveal(\(reason)) opens the panel — no hand-over, live mode stays")
            }
            return false
        }
        if reason == .hover, pointerOnMirror() {
            if Date().timeIntervalSince(lastHoverNote) > 2 {
                lastHoverNote = Date()
                PelmetLog.log("livemirror: hover on the mirror — no reveal, the pointer is on its way to a click")
            }
            return true
        }
        // Hidden asked for by a hover, the « or a ⌘-drag: the bar is out
        // already, only the covers hide it. They end at the Always Hidden
        // icons instead of handing the bar to a reveal, whose assertion would
        // take the timer, the extras and the pills off (mid-drag too) and
        // reflow everything right of the «.
        if sections == [.hidden], [.hover, .statusItem, .barDrag].contains(reason), how != .toggleAll, !coverLifted {
            // On a display that shows every icon Hidden is out already: a
            // hover or a drag asks nothing, the « opens Always Hidden there (#96).
            if appState?.pointerDisplayBehavior == .alwaysShowAll, hiddenOut == nil {
                if reason != .statusItem { return true }
                beginHandOver(reason)
                return false
            }
            if hiddenOut != nil {
                if reason == .statusItem { Task { @MainActor in await self.hideHidden("the « again") } }
                return true
            }
            Task { @MainActor in await self.showHidden(reason) }
            return true
        }
        if hiddenOut != nil { hiddenOut = nil }
        beginHandOver(reason)
        return false
    }

    /// The covers end at the Always Hidden icons: Hidden shows, live.
    private func showHidden(_ reason: RevealReason) async {
        guard isActive, !entering, !exiting, !handingOver, hiddenOut == nil else { return }
        hiddenOut = HiddenOut(reason: reason, outSince: nil)
        let started = Date()
        var fresh = true
        for side in sides where !side.showsAll {
            await measureRunEdge(side, fresh: fresh)
            fresh = false
            guard hiddenOut != nil, isActive, !exiting, !handingOver else { return }
            guard let edge = side.runEdge, edge > side.coverMinX + 40, edge < side.coverMaxX else {
                PelmetLog.log("livemirror: display \(side.id) Hidden edge \(side.runEdge.map { "\(Int($0))" } ?? "-") outside the cover \(Int(side.coverMinX))..\(Int(side.coverMaxX)) — left covered")
                continue
            }
            buildCover(side, left: side.coverMinX, right: edge - 1, why: "hidden out")
        }
        PelmetLog.log("livemirror: reveal(\(reason)) — Hidden out under live mode in \(Int(-started.timeIntervalSinceNow * 1000))ms, the assertion stays down")
    }

    /// The covers reach the « again: Hidden is hidden.
    private func hideHidden(_ why: String) async {
        guard hiddenOut != nil else { return }
        hiddenOut = nil
        guard isActive, !entering, !exiting, !handingOver, let chevron = lastChevron else { return }
        for side in sides where !side.showsAll {
            buildCover(side, left: side.coverMinX, right: coverEnd(chevron, on: side) - 1, why: "hidden back")
        }
        PelmetLog.log("livemirror: Hidden back under the covers (\(why))")
    }

    /// The pointer is in a menu bar (the top 40 pt of any display).
    private static func pointerInBar() -> Bool {
        let point = NSEvent.mouseLocation
        return NSScreen.screens.contains { NSMouseInRect(point, $0.frame, false) && point.y >= $0.frame.maxY - 40 }
    }

    /// The reveal goes to the panel (its "Show hidden icons in"), not the bar.
    private func opensPanel(_ reason: RevealReason) -> Bool {
        guard let appState else { return false }
        return RevealRouting.destination(for: reason, target: appState.revealDecision(for: reason).target) == .panel
    }

    /// The reveal asked while live mode was starting, run now.
    private func runPendingReveal(_ why: String) {
        guard let appState, let p = pendingReveal else { return }
        pendingReveal = nil
        PelmetLog.log("livemirror: running the reveal(\(p.reason)) asked while live mode started (\(why))")
        switch p.how {
        case .toggle: appState.toggle(reason: p.reason, sections: p.sections)
        case .reveal: appState.reveal(p.sections, reason: p.reason)
        case .toggleAll: appState.toggleAll(reason: p.reason)
        }
    }

    /// The Live Activities item's own click (the existing lift): in live
    /// mode it only lifts the cover and puts it back.
    func interceptsItemClick() -> Bool {
        guard isActive, !handingOver else { return isActive }
        toggleCover("item")
        return true
    }

    private func pointerOnMirror() -> Bool {
        let point = NSEvent.mouseLocation
        return sides.contains { side in
            side.mirrors.contains { !$0.dropped && !$0.container.isHidden && ($0.global?.insetBy(dx: -6, dy: -6).contains(point) ?? false) }
        }
    }

    private func beginHandOver(_ reason: RevealReason?) {
        let named = reason.map { "reveal(\($0))" } ?? "a reveal"
        handingOver = true
        released = false
        liftedReturn?.cancel()
        if coverLifted {
            coverLifted = false
            setCoversShown(true, why: "hand-over")
        }
        PelmetLog.log("livemirror: \(named) — the bar goes to the normal reveal, pill and mirror away, cover up")
        rememberAll()
        // The mirrors leave the way the bar's own items do (the reveal
        // animation's exit), under the cover that stays up.
        mirrorsLeaving = true
        for side in sides {
            side.trailing?.cancel()
            side.trailing = nil
            for mirror in side.mirrors { present(mirror, false) }
        }
        let mouse: Bool = { switch reason { case .click?, .doubleClick?, .statusItem?: true; default: false } }()
        Task { @MainActor in await self.closeCard(why: named, mouseDismisses: mouse) }
        handOverWatchdog?.cancel()
        handOverWatchdog = Task { @MainActor [weak self] in
            // The reveal should take the bar within moments. A reveal that is
            // under way (asked, moving, out) is late, not missing: it gets up
            // to 8 s; with none under way 3 s is enough to call it off.
            var waited = 0.0
            while waited < 8 {
                try? await Task.sleep(for: .milliseconds(250))
                waited += 0.25
                guard let self, !Task.isCancelled, self.handingOver, !self.released else { return }
                if waited >= 3, !(self.appState?.isTransitioning ?? false), !(self.appState?.isRevealed ?? false) { break }
            }
            guard let self, !Task.isCancelled, self.handingOver, !self.released else { return }
            PelmetLog.log("livemirror: no reveal came for the hand-over in \(Int(waited))s — live mode carries on")
            self.handingOver = false
            self.mirrorsLeaving = false
            for side in self.sides { self.layoutMirrors(side) }
        }
    }

    /// What the mirrors and the pictures were when the bar went to a reveal.
    private func rememberAll() {
        remembered = [:]
        keptPictures = [:]
        for side in sides {
            if let picture = side.picture, side.pictureGeneration == backdropGeneration {
                keptPictures[side.id] = KeptPicture(picture: picture, generation: side.pictureGeneration, at: side.pictureAt)
            }
            guard let chevron = lastChevron else { continue }
            let pills = side.mirrors.filter { !$0.dropped && $0.visual != nil && $0.base.contents != nil }.map { m -> Remembered in
                let v = m.visual!
                return Remembered(key: m.key, name: m.copy.name, visual: v,
                                  bits: m.bits.map { ($0.value, $0.frame.offsetBy(dx: -v.minX, dy: -v.minY)) }, clock: m.clock)
            }
            remembered[side.id] = Memory(chevronMinX: coverEnd(chevron, on: side), pills: pills)
        }
    }

    /// The coordinator's reveal is about to take the engine: live mode's
    /// hold ends with no swap of its own, so the reveal's is the only one.
    func releaseForReveal() async {
        guard isActive, !entering, !exiting, !released, let appState else { return }
        if !handingOver {
            // A reveal took the bar after the hand-over gave up (or with no
            // hand-over asked): the hold ends for it all the same.
            PelmetLog.log("livemirror: a reveal is taking the bar with no hand-over under way — handing over now")
            beginHandOver(nil)
        }
        released = true
        handOverWatchdog?.cancel()
        ConcealGhostOverlay.liveModeBlocksCaptures = false
        if underAnchor {
            // Anchored, Hidden is out already: a reveal of it touches no
            // section and runs no swap of its own, so nothing else would put
            // the assertion back (the pill and every hidden icon stayed on
            // the bars, 2026-10-28). The hold ends with a swap of its own,
            // under the cover that is still up.
            await appState.engine.holdLift(false)
            PelmetLog.log("livemirror: hold released — anchored, the assertion goes back in a swap of its own")
        } else {
            await appState.engine.releaseLiftHold()
            PelmetLog.log("livemirror: hold released — the reveal's assertion is the swap")
        }
    }

    /// The reveal's swap has landed: the pill is gone for good, live mode
    /// is over until the re-hide. The cover comes down once the bar rests
    /// beneath it (under the reveal's own cover, which lifts after).
    func revealLanded() async {
        guard handingOver, released, let appState else { return }
        let covers = sides.filter { !$0.showsAll }.compactMap(\.cover)
        // A display that shows every icon has no held bar to take over: the
        // assertion's return fades its Always Hidden icons out natively
        // (60 fps burst 2026-10-28: ten icons, still visible 30 ms after the
        // cover was down), so its cover stays until they are gone.
        let runCovers = sides.filter(\.showsAll).compactMap(\.cover)
        sides = []
        isActive = false
        handingOver = false
        released = false
        lastChevron = nil
        resetRunState()
        appState.transitions.liveModeActive = false
        PelmetLog.log("livemirror: reveal landed — live mode is off until the re-hide")
        Task { @MainActor in
            let started = Date()
            await appState.waitUntilQuiesced(interval: 0.15, deadline: 2, poll: .milliseconds(30))
            for cover in covers { cover.dismiss() }
            PelmetLog.log("livemirror: hand-over cover down at \(Int(-started.timeIntervalSinceNow * 1000))ms")
            guard !runCovers.isEmpty else { return }
            // Unless the reveal brought the Always Hidden icons out: then
            // they are meant to show.
            if !appState.currentRevealedSections.contains(.alwaysHidden) {
                let deadline = Date().addingTimeInterval(AppTiming.clockBlinkCoverDeadline)
                while Date() < deadline, await appState.engine.concealedItemsStillVisible() {
                    try? await Task.sleep(for: .milliseconds(60))
                }
                let gone = Int(-started.timeIntervalSinceNow * 1000)
                try? await Task.sleep(for: .seconds(AppTiming.exitCoverHold))
                PelmetLog.log("livemirror: show-all display cover held for the Always Hidden icons' fade — gone at \(gone)ms")
            }
            for cover in runCovers { cover.dismiss() }
            PelmetLog.log("livemirror: show-all display cover down at \(Int(-started.timeIntervalSinceNow * 1000))ms")
        }
    }

    /// What a run leaves behind when it ends, however it ends.
    private func resetRunState() {
        mirrorsLeaving = false
        hiddenOut = nil
        retaking = false
        missionControlUp = false
        assertionDropped = false
        standDown = false
        noPillSince = nil
    }

    // MARK: The card

    /// The expanded card is closed by an AX press on the pill again (the
    /// second press collapses it, ~0.8s), or by the click outside it. Cancel
    /// actions are unsupported on the card, the pill and its window (error
    /// -25206) and an Escape posted to MenuBarAgent's pid does nothing.
    /// Presses the real pill `name` (a mirror's own) on `side`, looked up
    /// fresh; no name presses the first mirror's.
    @discardableResult
    private func pressPill(_ why: String, side: Side? = nil, name: String? = nil) async -> String {
        guard let side = side ?? sides.first(where: { !$0.mirrors.isEmpty }) ?? sides.first else { return "no display" }
        let bounds = side.bounds
        let mirror = side.mirrors.first { name == nil || $0.copy.name == name } ?? side.mirrors.first
        let kept = ElementBox(list: mirror.map { [$0.copy.element] } ?? [])
        let wanted = name ?? mirror?.copy.name
        let started = Date()
        let (result, fresh) = await Task.detached(priority: .userInitiated) { PillProbe.press(in: bounds, named: wanted, kept: kept.list.first) }.value
        if let fresh, let mirror { mirror.copy = fresh }
        let text = "\(result) in \(Int(-started.timeIntervalSinceNow * 1000))ms"
        PelmetLog.log("livemirror: card — AX press on the pill \"\(wanted ?? "?")\" (\(why)) → \(text)")
        return text
    }

    private func cardProbe() async -> (open: Bool, owners: [String], detail: String) {
        await Task.detached(priority: .userInitiated) { PillProbe.cardProbe() }.value
    }

    /// Closes the card if it is open. `mouseDismisses`: a click started this,
    /// and the click is already an outside interaction that collapses the
    /// card; a press now would interrupt that collapse and leave it open.
    private func closeCard(why: String, mouseDismisses: Bool) async {
        let probe = await cardProbe()
        guard probe.open else { return }
        let owner = probe.owners.first { !$0.isEmpty }
        let started = Date()
        if mouseDismisses {
            PelmetLog.log("livemirror: card open (\(why)) — the click closes it")
        } else {
            PelmetLog.log("livemirror: card open (\(why)) — closing it")
            await pressPill(why, name: owner)
        }
        for _ in 0..<14 {
            try? await Task.sleep(for: .milliseconds(100))
            if !(await cardProbe()).open {
                PelmetLog.log("livemirror: card closed \(Int(-started.timeIntervalSinceNow * 1000))ms after (\(why))")
                return
            }
        }
        PelmetLog.log("livemirror: card still open 1.4s after (\(why))\(mouseDismisses ? " — pressing the pill" : "")")
        if mouseDismisses { await pressPill(why, name: owner) }
    }

    private func startLoop() {
        if screenObserver == nil {
            screenObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.backdropGeneration += 1
                    self.keptPictures = [:]
                    guard self.isActive, !self.exiting else { return }
                    // A start or a retake in flight built its sides and covers
                    // for the old displays: it finishes, then leaves
                    // (`leaveForDisplayChange`).
                    if self.entering {
                        self.displaysChangedWhileEntering = true
                        PelmetLog.log("livemirror: displays changed while live mode starts — it leaves once the start has settled")
                        return
                    }
                    PelmetLog.log("livemirror: displays changed — leaving live mode, it re-enters")
                    await self.exit("displays changed")
                }
            }
        }
        if spaceObserver == nil {
            spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
            ) { [weak self] _ in Task { @MainActor in self?.backdropGeneration += 1; await self?.backdropMayHaveChanged("the Space changed") } }
        }
        if themeObserver == nil {
            themeObserver = DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name("AppleInterfaceThemeChangedNotification"), object: nil, queue: .main
            ) { [weak self] _ in Task { @MainActor in self?.backdropGeneration += 1; await self?.backdropMayHaveChanged("the appearance changed") } }
        }
        if activateObserver == nil {
            // The menus on the left are the frontmost app's: a longer set
            // under a cover would be a picture of nothing.
            activateObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
            ) { [weak self] _ in Task { @MainActor in await self?.menusMayHaveChanged() } }
        }
        startOrderKeeper()
        loop = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let desired = self.wanted && self.enabled
                if self.entering || self.exiting || self.handingOver {
                    // a step is running
                } else if !self.wanted || !self.enabled, !self.isActive {
                    // Nothing to mirror and nothing held: no loop, no keeper,
                    // no observers until an activity starts again.
                    self.stopLoop()
                    return
                } else if desired, !self.isActive {
                    if let why = await self.cannotEnter() {
                        if why != self.lastBlockedWhy { self.lastBlockedWhy = why; PelmetLog.log("livemirror: waiting to enter — \(why)") }
                    } else {
                        self.lastBlockedWhy = ""
                        await self.enter()
                    }
                } else if !desired, self.isActive {
                    await self.exit(self.enabled ? "activity ended" : "setting turned off")
                } else if self.isActive {
                    await self.tick()
                }
                try? await Task.sleep(for: self.nextPoll())
            }
        }
    }

    /// The loop's rest: quick while a pill waits for its first still or a
    /// changed look settles (the still follows within a tick of being
    /// ready), otherwise the usual quarter second.
    private func nextPoll() -> Duration {
        guard isActive, !entering, !exiting, !handingOver else { return Self.pollInterval }
        let waiting = sides.contains { $0.mirrors.contains { !$0.dropped && !$0.provisional && ($0.placeCandidate != nil || $0.lookCandidate != nil) } }
        return waiting ? .milliseconds(60) : Self.pollInterval
    }

    /// Everything `startLoop` started, ended: idle live mode costs nothing.
    private func stopLoop() {
        PelmetLog.log("livemirror: idle — loop, order keeper and observers stopped")
        loop?.cancel(); loop = nil
        orderKeeper?.cancel(); orderKeeper = nil
        ConcealGhostOverlay.onNewCover = nil
        if let o = screenObserver { NotificationCenter.default.removeObserver(o); screenObserver = nil }
        if let o = spaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(o); spaceObserver = nil }
        if let o = activateObserver { NSWorkspace.shared.notificationCenter.removeObserver(o); activateObserver = nil }
        if let o = themeObserver { DistributedNotificationCenter.default().removeObserver(o); themeObserver = nil }
        clockLoop?.cancel(); clockLoop = nil
        kept = [:]; remembered = [:]; keptPictures = [:]
        resetRunState()
    }

    /// The bar is out for a reason of its own: a reveal, a section out
    /// beyond the anchor, an anchor on its way. A display that shows every
    /// icon keeps Hidden out on every bar (`TransitionCoordinator.anchored`)
    /// and holds the displays that conceal under pictures of the bare bar:
    /// that alone is no reason to wait. Live mode covers those displays
    /// itself and leaves the one that shows all as it is.
    private var barIsOut: Bool {
        guard let appState else { return true }
        if appState.isRevealed { return true }
        let out = appState.currentRevealedSections
        if out.isEmpty { return false }
        let t = appState.transitions
        return !(t.anchored && t.anchorTarget && out == t.anchoredSections && t.anchoredSections == [.hidden])
    }

    /// Hidden is out on every bar for a display that shows all icons.
    private var underAnchor: Bool { appState?.transitions.anchored ?? false }

    private func cannotEnter() async -> String? {
        guard let appState else { return "no app state" }
        if Date() < retryNotBefore { return holdOffWhy }
        if !ScreenRecordingAccess.isGranted { return "no Screen Recording" }
        // Nothing to film when every display shows all its icons (`enter`
        // would only call the start off, again and again).
        let conceals = NSScreen.screens.contains {
            appState.settings.behavior(forDisplayUUID: $0.displayUUIDString) != .alwaysShowAll
        }
        if !conceals { return "no display conceals — every display shows all its icons" }
        if barIsOut { return "the bar is out" }
        if appState.isTransitioning { return "a transition runs" }
        if appState.panelShowsReveal { return "the panel is up" }
        if appState.liftHoldReason != nil { return "a lift has the bar" }
        if appState.transitions.coversInFlight { return "a cover is still up" }
        if appState.chevronWindowFrame == nil { return "no chevron window" }
        if !(await appState.engine.holdsAssertion) { return "no assertion held — the pill shows on its own" }
        return nil
    }

    // MARK: Geometry

    private var primaryHeight: CGFloat { NSScreen.screens.first?.frame.maxY ?? 0 }
    private var primaryMaxX: CGFloat { NSScreen.screens.first?.frame.maxX ?? 0 }

    /// The chevron's left edge on `side`'s display: its window's offset from
    /// its own display's right edge, translated (the bars mirror right-anchored).
    private func chevronMinX(_ chevron: NSRect, on side: Side) -> CGFloat {
        let home = NSScreen.screens.first { NSMouseInRect(NSPoint(x: chevron.midX, y: chevron.midY), $0.frame, false) } ?? side.screen
        return chevron.minX + (side.screen.frame.maxX - home.frame.maxX)
    }

    /// Where a cover on `side` ends: the « on a display that conceals; on one
    /// that shows every icon, the left edge of the Hidden icons (they stay
    /// out, the cover is only over what the assertion hides left of them).
    private func coverEnd(_ chevron: NSRect, on side: Side) -> CGFloat {
        if side.showsAll || hiddenOut != nil, let edge = side.runEdge { return edge }
        return chevronMinX(chevron, on: side)
    }

    /// A display that shows every icon: the left edge of its Hidden icons
    /// (the leftmost visible one when it has none) and the span of the Always
    /// Hidden icons, from a fresh walk of the agent's bar for that display.
    private func measureRunEdge(_ side: Side, fresh: Bool = true) async {
        guard let appState else { return }
        if fresh { _ = await appState.engine.freshSnapshot() }
        let copies = await appState.engine.barCopies()
        let model = appState.settings.sectionModel
        let bounds = side.bounds
        var hidden: CGFloat?, visible: CGFloat?
        var always: ClosedRange<CGFloat>?
        for (id, rects) in copies {
            guard let r = rects.first(where: { bounds.contains(CGPoint(x: $0.midX, y: $0.midY)) }) else { continue }
            switch model.section(of: id) {
            case .hidden: hidden = min(hidden ?? r.minX, r.minX)
            case .visible: visible = min(visible ?? r.minX, r.minX)
            case .alwaysHidden: always = min(always?.lowerBound ?? r.minX, r.minX)...max(always?.upperBound ?? r.maxX, r.maxX)
            }
        }
        side.runEdge = hidden ?? visible
        side.alwaysRun = always
    }

    /// The concealed bar's icons out on their own on `side` (a show rule's
    /// Battery, a press's item) sit beside the «, where the mirrors are
    /// laid out: their run to `right`, from a fresh walk, or nil when there
    /// are none. Under the anchor the bare picture holds no icon at all.
    private func measureAlone(_ side: Side, left: CGFloat, right: CGFloat) async {
        side.aloneRun = nil
        guard let appState, !underAnchor, !side.showsAll else { return }
        let alone = await appState.engine.itemsShownAlone()
        guard !alone.isEmpty else { return }
        _ = await appState.engine.freshSnapshot()
        let copies = await appState.engine.barCopies()
        let bounds = side.bounds
        let edge = alone.compactMap { id in
            copies[id]?.first { bounds.contains(CGPoint(x: $0.midX, y: $0.midY)) }?.minX
        }.filter { $0 > left + 40 && $0 < right }.min()
        guard let edge else { return }
        side.aloneRun = edge...right
        PelmetLog.log("livemirror: display \(side.id) icons out on their own \(Int(edge))..\(Int(right)) — they keep beside the «, the mirrors left of them")
    }

    /// `run` of `picture`, cut column for column into a layer.
    private static func cut(_ picture: ConcealGhostOverlay.BarSnapshot, run: ClosedRange<CGFloat>, contentsScale: CGFloat) -> CALayer? {
        let frame = picture.windowFrame
        let scale = CGFloat(picture.image.width) / frame.width
        let x0 = Int(((run.lowerBound - frame.minX) * scale).rounded())
        let x1 = Int(((run.upperBound - frame.minX) * scale).rounded())
        guard x0 > 0, x1 <= picture.image.width, x1 - x0 > 8,
              let image = picture.image.cropping(to: CGRect(x: x0, y: 0, width: x1 - x0, height: picture.image.height))
        else { return nil }
        let layer = CALayer()
        layer.contents = image
        layer.contentsScale = contentsScale
        layer.bounds = CGRect(x: 0, y: 0, width: CGFloat(x1 - x0) / scale, height: frame.height)
        return layer
    }

    /// Where a cover may start: far enough left for the hidden icons the
    /// last conceal measured (the estimate by count when none was) and the
    /// pill beside them, right of the notch and right of the frontmost
    /// app's menus (a menu under a picture is neither live nor clickable).
    private func coverLeft(for side: Side, right: CGFloat) -> CGFloat {
        let concealed = appState?.snapshot?.concealed.count ?? 0
        var left = right - CGFloat(concealed) * 44 - 360
        let shift = side.screen.frame.maxX - primaryMaxX
        if let t = appState?.transitions, let strip = t.lastConcealedStripRect {
            left = min(left, min(strip.minX, t.widestStripMinX ?? strip.minX) + shift - 360)
        }
        // Under the anchor the hidden icons are out, and the pill and the
        // extras coming back push them left: the cover reaches past them.
        if let held = appState?.transitions.heldRunLeft { left = min(left, held + shift - 360) }
        let floor = side.menusRight > 0 ? side.menusRight + 4 : side.screen.frame.minX + side.screen.frame.width * 0.3
        left = max(left, floor)
        if let notch = side.screen.auxiliaryTopRightArea?.minX { left = max(left, notch + 2) }
        return left
    }

    /// The x range a cover's picture is cropped to (primary space, inside the
    /// picture's padding), nil when `left..right` is too narrow to hold one.
    /// A backwards `ClosedRange` traps, and a cover's edges can meet: the
    /// floor (the frontmost app's menus, the notch) against a « that moved
    /// left.
    private func coverSpan(left: CGFloat, right: CGFloat, shift: CGFloat) -> ClosedRange<CGFloat>? {
        let pad = ConcealGhostOverlay.capturePadding
        guard right - left >= 2 * pad else { return nil }
        return (left - shift + pad)...(right - shift - pad)
    }

    /// The frontmost app's menus on `side`, read now.
    private func measureMenus(_ side: Side) async {
        guard let pid = NSWorkspace.shared.menuBarOwningApplication?.processIdentifier else { side.menusRight = 0; return }
        let bounds = side.bounds
        side.menusRight = await Task.detached(priority: .userInitiated) { PillProbe.menusRight(pid: pid, in: bounds) }.value ?? 0
    }

    /// Another app came to the front: its menus may reach under a cover.
    /// The cover starts right of them again.
    private func menusMayHaveChanged() async {
        try? await Task.sleep(for: .milliseconds(200))
        guard isActive, !entering, !exiting, !handingOver else { return }
        for side in sides {
            await measureMenus(side)
            guard isActive, !entering, !exiting, !handingOver, side.menusRight > 0, side.menusRight + 4 > side.coverMinX,
                  side.menusRight + 44 < side.coverMaxX else { continue }
            PelmetLog.log("livemirror: display \(side.id) menus reach \(Int(side.menusRight)), under the cover from \(Int(side.coverMinX)) — it starts right of them")
            buildCover(side, left: side.menusRight + 4, right: side.coverMaxX, why: "the frontmost app's menus")
        }
    }

    private func cocoa(_ rect: CGRect) -> NSRect {
        NSRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    // MARK: Enter

    /// `holdOff`: the reason will be there next time too (no display to film,
    /// no picture, no room for a cover), so the loop does not try again at
    /// once: 5 s, doubling each time in a row, to two minutes. A new activity
    /// or a start that goes through ends the hold-off. Without it (something
    /// took the bar meanwhile) the next quiet bar tries again.
    private func abort(_ why: String, dropAssertion: Bool = false, holdOff: Bool = false) async {
        PelmetLog.log("livemirror: enter aborted — \(why)")
        if holdOff {
            abortStrikes += 1
            let hold = min(120, 5 * pow(2, Double(abortStrikes - 1)))
            retryNotBefore = Date().addingTimeInterval(hold)
            holdOffWhy = "the last start was called off (\(why)) — holding off \(Int(hold))s (a new activity ends the hold-off)"
        }
        for side in sides { side.cover?.dismiss() }
        sides = []
        // The assertion goes back if it was let go (a start that gave up
        // after the drop must not leave the hidden icons showing).
        if dropAssertion || assertionDropped { await appState?.engine.holdLift(false) }
        ConcealGhostOverlay.liveModeBlocksCaptures = false
        appState?.transitions.liveModeActive = false
        isActive = false
        lastChevron = nil
        resetRunState()
        // A reveal swallowed while the start ran is the user's: it runs now
        // (not at some later start).
        if pendingReveal != nil {
            Task { @MainActor [weak self] in self?.runPendingReveal("the start was called off") }
        }
    }

    /// Why the start should not go on, or nil: something took the bar since
    /// `cannotEnter` looked (the picture and the settle take a second or two).
    private func prepIssue() -> String? {
        guard let appState else { return "no app state" }
        if standDown { return "a reveal came first" }
        if barIsOut { return "the bar came out" }
        if appState.isTransitioning { return "a transition started" }
        if appState.panelShowsReveal { return "the panel came up" }
        return nil
    }

    private func enter() async {
        await enterOnce()
        await leaveForDisplayChange()
    }

    /// The displays changed while a start or a retake ran: its sides and
    /// covers are for the old ones. Live mode leaves; the loop starts it
    /// again on the new displays.
    private func leaveForDisplayChange() async {
        guard displaysChangedWhileEntering, !entering else { return }
        displaysChangedWhileEntering = false
        guard isActive, !exiting else { return }
        PelmetLog.log("livemirror: displays changed during the start — leaving live mode, it re-enters")
        backdropGeneration += 1
        keptPictures = [:]
        await exit("displays changed")
    }

    private func enterOnce() async {
        guard let appState, !isActive, !entering else { return }
        displaysChangedWhileEntering = false
        entering = true
        defer { entering = false }
        // After a re-hide the bar may still be at its reflow.
        let quietFrom = Date()
        // A return from a reveal has its pictures kept: it needs the bar's rest less.
        await appState.waitUntilQuiesced(interval: keptPictures.isEmpty ? 0.2 : 0.08, deadline: 2, poll: .milliseconds(30))
        let started = Date()
        func ms() -> Int { Int(-started.timeIntervalSinceNow * 1000) }
        guard let chevron = appState.chevronWindowFrame,
              let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        else { PelmetLog.log("livemirror: enter refused — no chevron or no shareable content"); return }
        PelmetLog.log("livemirror: enter — chevron \(Int(chevron.minX))..\(Int(chevron.maxX)), \(NSScreen.screens.count) display(s), bar quiet after \(Int(started.timeIntervalSince(quietFrom) * 1000))ms")
        isActive = true
        standDown = false
        assertionDropped = false
        mirrorsLeaving = false
        appState.transitions.liveModeActive = true
        sides = NSScreen.screens.compactMap { screen in
            guard let id = screen.directDisplayID, let display = content.displays.first(where: { $0.displayID == id }) else { return nil }
            // A display set to show every icon keeps its Hidden icons out; the
            // assertion dropping brings back what it hides there (the Always
            // Hidden icons, the pills): a cover over that alone, from the
            // left limit to the Hidden icons, with the mirrors in it.
            let side = Side(id: id, screen: screen, scDisplay: display)
            if appState.settings.behavior(forDisplayUUID: screen.displayUUIDString) == .alwaysShowAll {
                side.showsAll = true
                PelmetLog.log("livemirror: display \(id) always shows — covers Always Hidden only (the Hidden icons stay out), live")
            } else {
                PelmetLog.log("livemirror: display \(id) conceals, live\(appState.transitions.anchored ? " (held under the anchor)" : "")")
            }
            return side
        }
        // Nothing to film when every display shows all its icons.
        guard sides.contains(where: { !$0.showsAll }) else { await abort("no display to film", holdOff: true); return }
        for side in sides {
            await measureMenus(side)
            if side.showsAll { await measureRunEdge(side) }
            PelmetLog.log("livemirror: display \(side.id) menus end at \(side.menusRight > 0 ? "\(Int(side.menusRight))" : "- (none shown)"), cover may start at \(Int(coverLeft(for: side, right: coverEnd(chevron, on: side) - 1)))")
        }
        if let issue = prepIssue() { await abort("\(issue) (before the picture)"); return }
        await goLive(chevron: chevron, started: started, retake: false)
    }

    /// The pictures, the covers, the assertion and the pills: the start of
    /// live mode, or with `retake` the same again under a new backdrop with
    /// the mirrors staying on screen (they were made provisional, so the
    /// pills' own take them over as they come back).
    private func goLive(chevron first: NSRect, started: Date, retake: Bool) async {
        guard let appState else { return }
        var chevron = first
        func ms() -> Int { Int(-started.timeIntervalSinceNow * 1000) }

        // 1. The picture of the concealed bar, each display from its left
        // limit to the «. Taking it lights the system's capture indicator,
        // which moves the cluster: the « is read again once it has. A
        // picture kept from before a reveal serves while the backdrop is the
        // one it was taken on: no capture, no indicator, no wait.
        var captured = false
        var fresh: Set<CGDirectDisplayID> = []
        for side in sides {
            // A retake comes back to a bar whose Hidden icons may have moved.
            if side.showsAll, retake { await measureRunEdge(side) }
            let right = coverEnd(chevron, on: side) - 1
            let left = coverLeft(for: side, right: right)
            let shift = side.screen.frame.maxX - primaryMaxX
            guard let span = coverSpan(left: left, right: right, shift: shift) else {
                await abort("no room for a cover on display \(side.id) (\(Int(left))..\(Int(right)))", holdOff: true); return
            }
            // A kept picture holds no icon out on their own (they are cut
            // out of it): one is taken again while some are out.
            if !retake, let keep = keptPictures[side.id], keep.generation == backdropGeneration,
               Date().timeIntervalSince(keep.at) < Self.pictureMaxAge, await appState.engine.itemsShownAlone().isEmpty,
               !ConcealGhostOverlay.cropped([keep.picture], toPrimaryX: span).isEmpty {
                side.picture = keep.picture
                side.pictureAt = keep.at
                side.pictureGeneration = keep.generation
                PelmetLog.log("livemirror: display \(side.id) picture kept from \(Int(Date().timeIntervalSince(keep.at)))s ago — no capture")
                continue
            }
            // The start read the bar a moment ago: a converge since (a show
            // rule's icon coming out at an unlock) may still be reflowing.
            await appState.waitUntilQuiesced(interval: 0.2, deadline: 2, poll: .milliseconds(30))
            await measureAlone(side, left: left, right: right)
            let rect = CGRect(x: left - shift, y: 0, width: right - left, height: 40)
            // Under the anchor the hidden icons are out on the bar: the bare
            // bar (the system's bar window left out) is the concealed bar.
            // Dimble's own windows are left out: a retake keeps the old cover
            // and its mirrors up over the bar, and filmed, the old picture
            // (a Battery a rule just took back) and the old mirror (a slice of
            // pill once the « moved) came back in the new one.
            side.picture = await ConcealGhostOverlay.snapshotSet(
                of: rect, excludingOwnWindows: true, displays: [side.id], bare: underAnchor, liveMirror: true
            ).first
            guard let picture = side.picture else { await abort("no picture of display \(side.id)", holdOff: true); return }
            side.pictureAt = Date()
            side.pictureGeneration = backdropGeneration
            captured = true
            fresh.insert(side.id)
            PelmetLog.log("livemirror: display \(side.id) picture \(Int(picture.windowFrame.minX))..\(Int(picture.windowFrame.maxX)) (wanted \(Int(left))..\(Int(right)))")
        }
        keptPictures = [:]
        PelmetLog.log("livemirror: pictures at \(ms())ms\(captured ? "" : " (kept)")")
        if captured {
            try? await Task.sleep(for: .milliseconds(350))
            if let issue = prepIssue() { await abort("\(issue) (after the picture)"); return }
        }
        let before = chevron
        chevron = appState.chevronWindowFrame ?? chevron
        lastChevron = chevron
        PelmetLog.log("livemirror: chevron \(Int(before.minX)) → \(Int(chevron.minX)) after the picture\(captured ? " (capture indicator)" : "")")
        for side in sides {
            // The capture indicator moved the cluster, the Hidden icons too.
            if side.showsAll, captured { await measureRunEdge(side) }
            let right = coverEnd(chevron, on: side) - 1
            // A picture taken just now holds the « and the extras mid-slide at
            // its right end (the capture indicator moves them while it is
            // taken): from where the cover ends it is bar background only, so
            // a cover that later reaches further right (a return, the
            // indicator gone) never shows a boot-state item there.
            // The icons out on their own beside the « are cut out of it the
            // same way, into the layer laid out against the « (`layoutMirrors`).
            if fresh.contains(side.id), let picture = side.picture {
                side.alone = side.aloneRun.flatMap { Self.cut(picture, run: $0, contentsScale: side.scale) }
                side.aloneAttached = false
                let smearFrom = side.alone == nil ? right : min(right, side.aloneRun?.lowerBound ?? right)
                side.picture = ConcealGhostOverlay.smeared(picture, from: smearFrom)
            }
            guard buildCover(side, left: coverLeft(for: side, right: right), right: right, why: "enter") else {
                await abort("cover won't crop on display \(side.id)", holdOff: true); return
            }
        }
        if let issue = prepIssue() { await abort("\(issue) (covers up)"); return }
        ConcealGhostOverlay.liveModeBlocksCaptures = true
        PelmetLog.log("livemirror: covers up at \(ms())ms — \(sides.map { "d\($0.id) \(Int($0.coverMinX))..\(Int($0.coverMaxX))" }.joined(separator: ", "))")
        for side in sides where side.showsAll {
            PelmetLog.log("livemirror: display \(side.id) always shows — cover \(Int(side.coverMinX))..\(Int(side.coverMaxX)) ends at the Hidden icons (\(side.runEdge.map { "from \(Int($0))" } ?? "no Hidden or visible icon found, the « ends it"))")
        }
        // A return from a reveal draws the mirrors now, from the kept stills.
        if !retake { for side in sides { seedMirrors(side) } }

        // 2. The assertion goes: the hidden icons come back under the cover,
        // the extras right of the « and the pill after them. From here a
        // reveal waits for the start to settle (the assertion is dropped as
        // far as the engine is concerned, and `abort` puts it back).
        assertionDropped = true
        // The covers are up: the held windows (the anchor's) make way.
        appState.transitions.releaseHeldForLive()
        await appState.engine.holdLift(true)
        let dropped = ms()
        PelmetLog.log("livemirror: assertion down at \(dropped)ms")

        // 3. Wait for the « to stop moving and the pill (with its children) to be there.
        let by = Date().addingTimeInterval(4)
        let droppedAt = Date()
        var movedAt = Date(), seen = chevron
        var firstPill: Int?
        func real(_ side: Side) -> Bool { side.mirrors.contains { !$0.provisional } }
        func waiting(_ side: Side) -> Bool { side.mirrors.contains { $0.provisional } }
        while Date() < by, wanted {
            if let now = appState.chevronWindowFrame, abs(now.minX - seen.minX) > 0.5 {
                seen = now; movedAt = Date()
            }
            for side in sides where !real(side) || waiting(side) {
                await discoverPills(side)
                if real(side) { firstPill = firstPill ?? ms() }
            }
            let still = Date().timeIntervalSince(movedAt) > 0.3
            // Every pill back, or some back and the others given 1.5 s.
            if sides.allSatisfy({ real($0) && !waiting($0) }), still { break }
            if sides.allSatisfy({ real($0) }), still, Date().timeIntervalSince(droppedAt) > 1.5 { break }
            try? await Task.sleep(for: .milliseconds(60))
        }
        PelmetLog.log("livemirror: settled at \(ms())ms — chevron \(Int(chevron.minX)) → \(Int(seen.minX)), pill \(firstPill.map { "\($0)ms" } ?? "never seen")")
        // A mirror drawn from memory whose pill did not come back has nothing to mirror.
        for side in sides {
            for mirror in side.mirrors where mirror.provisional {
                PelmetLog.log("livemirror: display \(side.id) pill \"\(mirror.key)\" did not come back — its mirror leaves")
                retire(mirror)
            }
            side.mirrors.removeAll { $0.provisional }
            side.predictedRight = nil
        }

        // 4. The cover shrinks to the « where it is now; the pill is drawn.
        if let now = appState.chevronWindowFrame { lastChevron = now }
        if let chevron = lastChevron {
            for side in sides {
                if side.showsAll { await measureRunEdge(side) }
                let right = coverEnd(chevron, on: side) - 1
                buildCover(side, left: side.coverMinX, right: right, why: "settled")
                if side.showsAll { noteRun(side) }
            }
        }
        for side in sides { await refreshSide(side, why: "enter") }
        PelmetLog.log("livemirror: live at \(ms())ms (assertion down \(dropped)ms)")
        abortStrikes = 0
        lastSummaryAt = Date()
        noPillSince = Date()
        if pendingReveal != nil {
            entering = false
            runPendingReveal("live mode has settled")
        }
    }

    /// A return from a reveal: the mirrors go up with the covers, drawn from
    /// the kept stills and the last texts (a clock counted on to now), at the
    /// place the pills will stand once the extras are back. The real pills
    /// take them over as they show; a still taken meanwhile replaces the
    /// kept one in place.
    private func seedMirrors(_ side: Side) {
        guard let memory = remembered[side.id] else { return }
        remembered[side.id] = nil
        let now = Date()
        var made: [PillMirror] = []
        var bitsOf: [String: [TextBit]] = [:]
        for r in memory.pills {
            guard let still = kept[keptKey(side, key: r.key)],
                  now.timeIntervalSince(still.at) < (still.look.items.isEmpty ? 900 : Self.graphicRefresh) else { continue }
            let mirror = PillMirror(key: r.key, copy: PillCopy(element: AXUIElementCreateSystemWide(), frame: r.visual, text: "", name: r.name))
            mirror.provisional = true
            mirror.visual = r.visual
            mirror.base.contents = still.image
            mirror.base.contentsGravity = .resize
            mirror.look = still.look
            mirror.snapTexts = still.texts
            mirror.clock = r.clock
            var bits = r.bits.map { TextBit(value: $0.value, frame: $0.rel.offsetBy(dx: r.visual.minX, dy: r.visual.minY)) }
            if let i = r.clock.index, i < bits.count, r.clock.locked, let text = r.clock.extrapolated(at: now) { bits[i].value = text }
            bitsOf[r.key] = bits
            made.append(mirror)
        }
        guard !made.isEmpty else { return }
        side.mirrors.append(contentsOf: made)
        side.mirrors.sort { $0.copy.frame.minX < $1.copy.frame.minX }
        side.predictedRight = memory.chevronMinX - 1
        layoutMirrors(side)
        for mirror in made {
            drawTexts(mirror, bits: bitsOf[mirror.key] ?? [], side: side, why: "memory", readAt: now, bridge: true)
            carryOn(mirror, now: now)
        }
        PelmetLog.log("livemirror: display \(side.id) mirrors from memory [\(made.map(\.key).joined(separator: ", "))] — the kept stills and the last texts, the pills' own come back")
    }

    /// A provisional mirror's clock is counted on by the clock loop.
    private func carryOn(_ mirror: PillMirror, now: Date) {
        guard mirror.clock.locked, let tick = mirror.clock.tick else { return }
        mirror.clock.next = tick.addingTimeInterval(floor(now.timeIntervalSince(tick) + 0.001) + 1)
        ensureClockLoop()
    }

    // MARK: Cover

    /// One line per change of a show-all display's run: what the cover is
    /// over (the Always Hidden icons, the pills' spot) and where the Hidden
    /// icons it leaves out begin.
    private func noteRun(_ side: Side) {
        let always = side.alwaysRun.map { "\(Int($0.lowerBound))..\(Int($0.upperBound))" } ?? "none found"
        let note = "\(Int(side.coverMinX))..\(Int(side.coverMaxX)) always \(always) edge \(side.runEdge.map { "\(Int($0))" } ?? "-")"
        guard note != side.runNote else { return }
        side.runNote = note
        PelmetLog.log("livemirror: display \(side.id) always shows — covers Always Hidden only \(always) (cover \(Int(side.coverMinX))..\(Int(side.coverMaxX)), the Hidden icons stay out from \(side.runEdge.map { "\(Int($0))" } ?? "-"))")
    }

    /// The cover over [`left`, `right`] (global Cocoa x) from the kept picture.
    /// The new one goes up before the old one comes down.
    @discardableResult
    /// `keepMirrors`: the mirrors stay in the cover they stand in (the exit's:
    /// they leave there, with the exit motion, while the new cover is already
    /// up beneath them), and that cover goes once they are gone.
    private func buildCover(_ side: Side, left: CGFloat, right: CGFloat, why: String, keepMirrors: Bool = false) -> Bool {
        guard let picture = side.picture else { return false }
        // The Hidden icons did not move (a display that shows every icon):
        // nothing to end or grow.
        if side.showsAll, why == "settled" || why == "chevron moved", side.cover != nil,
           abs(left - side.coverMinX) < 0.5, abs(right - side.coverMaxX) < 0.5 { return true }
        // A shorter cover with the same left edge is the cover itself, ended
        // sooner: no new window, nothing moves, no frame without a cover.
        if why == "settled" || why == "chevron moved" || why == "hidden out", let current = side.cover?.members.first, abs(left - side.coverMinX) < 0.5,
           right < side.coverMaxX - 0.5, right > side.coverMinX + 40 {
            current.clip(toMaxX: right)
            side.coverMaxX = current.windowFrame.maxX
            layoutMirrors(side)
            if why != "enter" { PelmetLog.log("livemirror: cover #\(current.id) on display \(side.id) \(Int(side.coverMinX))..\(Int(side.coverMaxX)) (\(why), ended in place)") }
            return true
        }
        let shift = side.screen.frame.maxX - primaryMaxX
        guard let span = coverSpan(left: left, right: right, shift: shift) else {
            PelmetLog.log("livemirror: cover on display \(side.id) can't be built for \(Int(left))..\(Int(right)) (\(why)) — too narrow")
            return false
        }
        guard let cropped = ConcealGhostOverlay.cropped([picture], toPrimaryX: span).first,
              let cover = ConcealGhostOverlay.begin(from: [cropped], safety: Self.coverSafety, holdsBar: true),
              let overlay = cover.members.first
        else {
            PelmetLog.log("livemirror: cover on display \(side.id) can't be built for \(Int(left))..\(Int(right)) (\(why)); picture \(Int(picture.windowFrame.minX))..\(Int(picture.windowFrame.maxX))")
            return false
        }
        let old = side.cover
        side.cover = cover
        overlay.isLiveCover = true
        side.coverMinX = overlay.windowFrame.minX
        side.coverMaxX = overlay.windowFrame.maxX
        // A fading copy of an item Dimble hid (Shortcuts, Siri...) is above the
        // cover until its fade is over: it goes with the icons beneath the cover.
        let ghosts = StatusItemFader.cutGhosts(under: overlay.windowFrame)
        if ghosts > 0 { PelmetLog.log("livemirror: \(ghosts) fading item ghost(s) under the cover go with the icons beneath it (\(why))") }
        overlay.setClickHook { [weak self, weak side] point in
            guard let self, let side else { return }
            self.clicked(side, at: point)
        }
        if !keepMirrors {
            for mirror in side.mirrors { mirror.attached = false }
            side.aloneAttached = false
            layoutMirrors(side)
        } else if let alone = side.alone, let run = side.aloneRun {
            // The icons out on their own leave with the mirrors: this cover
            // holds a copy where the picture had them, where the « is back
            // once the extras are gone.
            let copy = CALayer()
            copy.contents = alone.contents
            copy.contentsScale = alone.contentsScale
            copy.frame = CGRect(x: run.lowerBound - overlay.windowFrame.minX, y: 0, width: alone.bounds.width, height: overlay.windowFrame.height)
            overlay.addLayer(copy)
        }
        if why != "enter" { PelmetLog.log("livemirror: cover #\(overlay.id) on display \(side.id) \(Int(side.coverMinX))..\(Int(side.coverMaxX)) (\(why))") }
        if coverLifted { overlay.setShown(false) } else { logOrder(overlay, why: "cover \(why)") }
        // The old cover stays until the new one is on screen: taken off at
        // once, the real pills showed for three frames (55 ms, measured on a
        // return, round 6). Overlap, never chain.
        if keepMirrors, let old, let from = old.members.first {
            overlay.order(beneath: from)
            let recipe = AnimationRecipe.recipe(for: appState?.settings.revealAnimation ?? .smooth)
            let leave: TimeInterval
            switch recipe.exit {
            case .pop: leave = 0
            case .fade(let d): leave = d
            case .slide(_, let d): leave = d
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + leave + 0.06) { old.dismiss() }
        } else if let old {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { old.dismiss() }
        }
        return true
    }

    /// The windows a still leaves out: Pelmet's own (the covers) and other
    /// apps' surfaces over the pill's spot (Sconce's notch glass draws its
    /// glyphs over it). The windows list needs a moment to name a window
    /// that just came up.
    private func windowsToExclude(over visual: CGRect, on side: Side) async -> [SCWindow] {
        let me = ProcessInfo.processInfo.processIdentifier
        let wanted = Set(sides.compactMap { $0.cover?.members.first?.windowNumber })
        let foreign = Set(ConcealGhostOverlay.foreignBandWindows(intersecting: visual, bandHeight: side.picture?.windowFrame.height ?? 39).map(\.id))
        let hostID = LiveActivityStatus.debugHost
        let barLevel = Int(CGWindowLevelForKey(.mainMenuWindow))
        var out: [SCWindow] = []
        for attempt in 0..<12 {
            let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let ordinary = Set(ConcealGhostOverlay.ordinaryAppWindows(content?.windows ?? []).map(\.windowID))
            out = content?.windows.filter { w in
                if w.owningApplication?.processID == me || foreign.contains(w.windowID) || ordinary.contains(w.windowID) { return true }
                // Harness runs only: the test pills sit over hidden icons the
                // real layout would have moved aside, and the icons are drawn
                // by the window server's "Menubar" window, above the pills'
                // windows. That window is left out of their still (the
                // capsules carry their own fill).
                guard let host = hostID, w.frame.intersects(visual) else { return false }
                if w.title == "Menubar" { return true }
                guard w.windowLayer >= barLevel, let app = w.owningApplication,
                      !app.bundleIdentifier.isEmpty, app.bundleIdentifier != host else { return false }
                return true
            } ?? []
            if wanted.isSubset(of: Set(out.map { Int($0.windowID) })) {
                if attempt > 0 { PelmetLog.log("livemirror: cover windows listed after \(attempt) retry(ies)") }
                break
            }
            try? await Task.sleep(for: .milliseconds(60))
        }
        return out
    }

    // MARK: Motion

    static let enterCurve = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
    static let exitCurve = CAMediaTimingFunction(controlPoints: 0.55, 0, 0.8, 0.4)
    static let fadeCurve = CAMediaTimingFunction(controlPoints: 0.42, 0, 0.58, 1)

    private func animation(_ keyPath: String, from: CGFloat, to: CGFloat, _ duration: CFTimeInterval, _ curve: CAMediaTimingFunction) -> CABasicAnimation {
        let a = CABasicAnimation(keyPath: keyPath)
        a.fromValue = from
        a.toValue = to
        a.duration = duration
        a.timingFunction = curve
        return a
    }

    /// A mirror comes and goes the way the bar's own items do, by the
    /// reveal animation the user chose: Smooth slides it out from behind the
    /// « (96 pt over 0.32 s, easing out) and back in (64 pt over 0.24 s,
    /// easing in), the cover's window ends at the « so the slide is clipped
    /// there; Fade is opacity alone; Instant is none. Same style both ways,
    /// the exit no longer than the entrance, the opposite curve (Design
    /// Sense: the hide is designed, one motion verb per product).
    private func present(_ mirror: PillMirror, _ on: Bool, move forced: AnimationRecipe.Move? = nil) {
        let layer = mirror.container
        let recipe = AnimationRecipe.recipe(for: appState?.settings.revealAnimation ?? .smooth)
        func translation(_ l: CALayer?) -> CGFloat { CGFloat((l?.value(forKeyPath: "transform.translation.x") as? NSNumber)?.doubleValue ?? 0) }
        if on {
            guard !mirror.shown else { return }
            mirror.shown = true
            let leaving = layer.animation(forKey: "pelmetOutFade") != nil
            let fromOpacity = leaving ? CGFloat(layer.presentation()?.opacity ?? 0) : 0
            let fromX = leaving ? translation(layer.presentation()) : nil
            CATransaction.begin(); CATransaction.setDisableActions(true)
            layer.removeAnimation(forKey: "pelmetOutFade"); layer.removeAnimation(forKey: "pelmetOut")
            layer.isHidden = false
            layer.opacity = 1
            layer.transform = CATransform3DIdentity
            CATransaction.commit()
            switch forced ?? recipe.entrance {
            case .pop: break
            case .fade(let d):
                layer.add(animation("opacity", from: fromOpacity, to: 1, d, Self.fadeCurve), forKey: "pelmetInFade")
            case .slide(let dx, let d):
                layer.add(animation("transform.translation.x", from: fromX ?? dx, to: 0, d, Self.enterCurve), forKey: "pelmetIn")
                layer.add(animation("opacity", from: fromOpacity, to: 1, min(d, 0.14), Self.enterCurve), forKey: "pelmetInFade")
            }
        } else {
            guard mirror.shown else { layer.isHidden = true; return }
            mirror.shown = false
            let duration: CFTimeInterval, dx: CGFloat, curve: CAMediaTimingFunction
            switch forced ?? recipe.exit {
            case .pop:
                CATransaction.begin(); CATransaction.setDisableActions(true)
                layer.isHidden = true
                CATransaction.commit()
                return
            case .fade(let d): duration = d; dx = 0; curve = Self.fadeCurve
            case .slide(let x, let d): duration = d; dx = x; curve = Self.exitCurve
            }
            let fromOpacity = CGFloat(layer.presentation()?.opacity ?? 1)
            let fromX = translation(layer.presentation())
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            CATransaction.setCompletionBlock { [weak mirror] in
                guard let mirror, !mirror.shown else { return }
                CATransaction.begin(); CATransaction.setDisableActions(true)
                mirror.container.removeAnimation(forKey: "pelmetOutFade"); mirror.container.removeAnimation(forKey: "pelmetOut")
                mirror.container.isHidden = true
                mirror.container.opacity = 1
                mirror.container.transform = CATransform3DIdentity
                CATransaction.commit()
            }
            layer.removeAnimation(forKey: "pelmetInFade"); layer.removeAnimation(forKey: "pelmetIn")
            layer.opacity = 0
            if dx != 0 { layer.transform = CATransform3DMakeTranslation(dx, 0, 0) }
            layer.add(animation("opacity", from: fromOpacity, to: 0, duration, curve), forKey: "pelmetOutFade")
            if dx != 0 { layer.add(animation("transform.translation.x", from: fromX, to: dx, duration, curve), forKey: "pelmetOut") }
            CATransaction.commit()
        }
    }

    // MARK: The mirrors

    /// Reads every pill's tree and brings the mirrors up to them: one new still
    /// of all the pills when a look or a text changed, the texts redrawn.
    private func refreshSide(_ side: Side, why: String, full: Bool = true) async {
        guard isActive, !exiting, !handingOver else { return }
        // The mirrors read are the ones held here: a discovery that runs
        // while the read waits may re-sort or drop mirrors, and a tree must
        // never be paired with another pill's mirror (by index). A mirror
        // drawn from memory has no pill to read yet.
        let read = side.mirrors.filter { !$0.provisional }
        guard !read.isEmpty else { return }
        let box = ElementBox(list: read.map(\.copy.element))
        let before = read.map(\.tree)
        let trees = await Task.detached(priority: .userInitiated) { () -> [PillTree?] in
            zip(box.list, before).map { element, was in
                // The quick read (frame and texts) serves unless a full one is
                // asked for: a clock moving is no reason to read the tree.
                if !full, let was {
                    switch PillProbe.quick(was, of: element) {
                    case .same: return was
                    case .values(let values): return was.patched(with: values)
                    case .reread: break
                    }
                }
                return PillProbe.readTree(element)
            }
        }.value
        let readAt = Date()
        guard isActive, !exiting, !handingOver, trees.count == read.count else { return }
        var live: [(mirror: PillMirror, tree: PillTree)] = []
        for (mirror, tree) in zip(read, trees) {
            // Removed by a discovery meanwhile: nothing to bring up to date.
            guard side.mirrors.contains(where: { $0 === mirror }) else { continue }
            guard let tree else {
                mirror.misses += 1
                if mirror.misses == 3 {
                    PelmetLog.log("livemirror: display \(side.id) pill \"\(mirror.key)\" unreadable — looking again")
                    side.needsDiscovery = true
                    mirror.container.isHidden = true
                }
                continue
            }
            mirror.misses = 0
            mirror.tree = tree
            mirror.visual = tree.visual
            live.append((mirror, tree))
        }
        guard !live.isEmpty else { return }
        // Wider than the cover starts: the pill lies left of it.
        if let leftmost = live.map(\.tree.frame.minX).min(), leftmost < side.coverMinX + 4, let picture = side.picture {
            let left = max(leftmost - 12, picture.windowFrame.minX + ConcealGhostOverlay.capturePadding, side.menusRight > 0 ? side.menusRight + 4 : 0)
            PelmetLog.log("livemirror: re-measure — pill left \(Int(leftmost)) is outside the cover \(Int(side.coverMinX))")
            buildCover(side, left: left, right: side.coverMaxX, why: "pill left of the cover")
        }
        layoutMirrors(side)
        // A kept still of the same look stands in for a capture.
        for (mirror, tree) in live where mirror.look == nil && mirror.base.contents == nil && !mirror.dropped {
            guard let still = kept[keptKey(side, mirror)] else { continue }
            let age = Int(Date().timeIntervalSince(still.at))
            // A pill with a graphic area is not trusted past the refresh interval.
            if age < (tree.images.isEmpty ? 900 : Int(Self.graphicRefresh)), tree.look.change(from: still.look) == nil {
                CATransaction.begin(); CATransaction.setDisableActions(true)
                mirror.base.contents = still.image
                mirror.base.contentsGravity = .resize
                CATransaction.commit()
                mirror.look = still.look
                mirror.snapTexts = still.texts
                PelmetLog.log("livemirror: still reused — \"\(mirror.key)\" is unchanged since \(age)s, no capture")
            }
        }
        var reasons: [String] = []
        var settling = false
        for (mirror, tree) in live {
            // A mirror with no room (dropped) is never drawn and never in a
            // still: waiting for its first still would take one capture per
            // tick for good.
            guard !mirror.dropped else { mirror.placeCandidate = nil; mirror.lookCandidate = nil; continue }
            let look = tree.look
            if let old = mirror.look, mirror.base.contents != nil {
                if let change = look.change(from: old) {
                    if let candidate = mirror.lookCandidate, candidate.look.change(from: look) == nil {
                        if Date().timeIntervalSince(candidate.since) >= Self.lookSettle { reasons.append(live.count > 1 ? "\(mirror.key) \(change)" : change) }
                        else { settling = true }
                    } else {
                        mirror.lookCandidate = (look, Date())
                        settling = true
                    }
                } else {
                    mirror.lookCandidate = nil
                }
            } else {
                // First still: the pill may still be sliding in (it returns
                // ~0.35 s after the assertion goes), so it must stand at one
                // place twice, 0.2 s apart; two seconds of moving is enough
                // waiting (a pill that animates for good).
                let place = tree.frame, now = Date()
                let tag = live.count > 1 ? "\(mirror.key) " : ""
                if let c = mirror.placeCandidate {
                    if abs(c.frame.minX - place.minX) < 1.5, abs(c.frame.minY - place.minY) < 1.5 {
                        if now.timeIntervalSince(c.since) >= Self.firstSettle { reasons.append("\(tag)first (\(why))") } else { settling = true }
                    } else if now.timeIntervalSince(c.first) > 2 {
                        reasons.append("\(tag)first (\(why), still moving)")
                    } else {
                        mirror.placeCandidate = (place, now, c.first)
                        settling = true
                    }
                } else {
                    mirror.placeCandidate = (place, now, now)
                    settling = true
                }
            }
        }
        if reasons.isEmpty, !settling, !side.snapping, let text = textTrigger(side, live) { reasons.append(text) }
        if reasons.isEmpty, !settling, !side.snapping, Date().timeIntervalSince(side.lastSnapshotAt) >= Self.graphicRefresh,
           live.contains(where: { !$0.tree.images.isEmpty && !$0.mirror.dropped }) {
            reasons.append("graphic refresh (\(Int(Self.graphicRefresh / 60)) min, no text or size change seen)")
        }
        if !reasons.isEmpty, !settling, !side.snapping {
            side.snapping = true
            _ = await snapshot(side, live, reason: reasons.joined(separator: "; "))
            side.snapping = false
        }
        for (mirror, tree) in live {
            mirror.tree = tree
            drawTexts(mirror, bits: tree.texts.map { TextBit(value: $0.value, frame: $0.frame) }, side: side, why: why, readAt: readAt)
        }
        // A mirror with its first still is shown (it may have waited for it).
        layoutMirrors(side)
    }

    /// The pills' texts differ from the ones in the still: a reason to take
    /// a new still now, or nil (nothing changed, or the rate limit holds it
    /// back and a trailing snapshot is waiting). One limit per display, for
    /// every pill together.
    private func textTrigger(_ side: Side, _ live: [(mirror: PillMirror, tree: PillTree)]) -> String? {
        var parts: [String] = []
        for (mirror, tree) in live {
            guard let was = mirror.snapTexts else { continue }
            let now = tree.texts.map(\.value)
            guard now != was else { continue }
            let change = "\(was.joined(separator: " ")) → \(now.joined(separator: " "))"
            parts.append(live.count > 1 ? "\(mirror.key) \(change)" : change)
        }
        guard !parts.isEmpty else { return nil }
        let change = parts.joined(separator: ", ")
        let interval = Self.textSnapshotInterval
        if let last = textSnapAt[side.id], Date().timeIntervalSince(last) < interval {
            let wait = interval - Date().timeIntervalSince(last)
            if side.skippedWindow != last {
                side.skippedWindow = last
                PelmetLog.log("livemirror: snapshot skipped — rate limit (text \(change), next in \(Int(wait.rounded(.up)))s)")
            }
            if side.trailing == nil {
                side.trailing = Task { @MainActor [weak self, weak side] in
                    try? await Task.sleep(for: .seconds(wait))
                    guard !Task.isCancelled, let self, let side else { return }
                    side.trailing = nil
                    await self.refreshSide(side, why: "trailing snapshot")
                }
            }
            return nil
        }
        textSnapAt[side.id] = Date()
        side.trailing?.cancel()
        side.trailing = nil
        return "text changed (\(change))"
    }

    /// One still of all the pills on a display (their union, one capture, so
    /// two pills do not double the capture indicator), cropped per pill with
    /// that pill's texts blanked out.
    private func snapshot(_ side: Side, _ entries: [(mirror: PillMirror, tree: PillTree)], reason: String) async -> Bool {
        let shown = entries.filter { !$0.mirror.dropped }
        guard let first = shown.first else { return false }
        // The capture rect sits on whole points: a fractional edge (a pill at
        // y 7.5) makes ScreenCaptureKit widen the source to its pixel grid and
        // scale the content to fit, which compresses it ~3% sideways with a
        // black strip on the right, and the texts blanked by their AX frames
        // would be off by up to 5 pt (measured, 2026-10-28).
        let raw = shown.dropFirst().reduce(first.tree.visual) { $0.union($1.tree.visual) }
        let union = CGRect(x: floor(raw.minX), y: floor(raw.minY),
                           width: ceil(raw.maxX) - floor(raw.minX), height: ceil(raw.maxY) - floor(raw.minY))
        let started = Date()
        let excluded = await windowsToExclude(over: union, on: side)
        let filter = SCContentFilter(display: side.scDisplay, excludingWindows: excluded)
        let config = SCStreamConfiguration()
        let local = union.offsetBy(dx: -side.bounds.minX, dy: -side.bounds.minY)
        config.sourceRect = local
        config.width = max(2, Int((local.width * side.scale).rounded()))
        config.height = max(2, Int((local.height * side.scale).rounded()))
        config.showsCursor = false
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.shouldBeOpaque = true
        config.ignoreShadowsDisplay = true
        let image: CGImage
        do { image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) }
        catch {
            PelmetLog.log("livemirror: snapshot on display \(side.id) failed — \(error.localizedDescription)")
            return false
        }
        // Read again right after the capture: a pill that moved while it ran
        // (sliding in, the capture indicator) was caught half-way.
        let afterBox = ElementBox(list: shown.map(\.mirror.copy.element))
        let after = await Task.detached(priority: .userInitiated) { afterBox.list.map { PillProbe.readTree($0) } }.value
        for ((mirror, tree), now) in zip(shown, after) {
            guard let now else { continue }
            let moved = abs(now.frame.minX - tree.frame.minX) > 1.5 || abs(now.frame.minY - tree.frame.minY) > 1.5
            if let why = now.look.change(from: tree.look) ?? (moved ? "moved \(Int(tree.frame.minX)) → \(Int(now.frame.minX))" : nil) {
                PelmetLog.log("livemirror: snapshot dropped — \"\(mirror.key)\" moved during the capture (\(why)), again once it stands still")
                mirror.placeCandidate = (now.frame, Date(), mirror.placeCandidate?.first ?? Date())
                mirror.lookCandidate = nil
                return false
            }
        }
        side.snapshots += 1
        side.lastSnapshotAt = Date()
        let scale = side.scale
        textSnapAt[side.id] = Date()
        for (mirror, tree) in shown {
            let v = tree.visual
            let pixels = CGRect(x: (v.minX - union.minX) * scale, y: (v.minY - union.minY) * scale,
                                width: v.width * scale, height: v.height * scale).integral
            guard let crop = image.cropping(to: pixels) else { continue }
            let rects = tree.texts.map { node in
                CGRect(x: (node.frame.minX - union.minX) * scale - pixels.minX, y: (node.frame.minY - union.minY) * scale - pixels.minY,
                       width: node.frame.width * scale, height: node.frame.height * scale)
            }
            let blanked = Self.blanked(crop, rects: rects)
            let had = mirror.base.contents
            CATransaction.begin(); CATransaction.setDisableActions(true)
            mirror.base.contents = blanked
            mirror.base.contentsGravity = .resize
            // A still replacing one that is on screen dissolves into it.
            if let had, mirror.shown {
                let fade = CABasicAnimation(keyPath: "contents")
                fade.fromValue = had
                fade.toValue = blanked
                fade.duration = 0.18
                mirror.base.add(fade, forKey: "pelmetStill")
            }
            CATransaction.commit()
            let texts = tree.texts.map(\.value)
            mirror.look = tree.look
            mirror.snapTexts = texts
            mirror.lookCandidate = nil
            mirror.placeCandidate = nil
            kept[keptKey(side, mirror)] = KeptStill(look: tree.look, image: blanked, at: Date(), texts: texts)
        }
        PelmetLog.log("livemirror: snapshot #\(side.snapshots) — \(reason) [display \(side.id), \(image.width)×\(image.height)px, \(Int(-started.timeIntervalSinceNow * 1000))ms, \(excluded.count) window(s) left out, \(shown.count) pill(s)]")
        return true
    }

    /// The still with each rect (pixels, top-left origin) painted over from
    /// the bar above and below it, column by column.
    nonisolated private static func blanked(_ image: CGImage, rects: [CGRect]) -> CGImage {
        let width = image.width, height = image.height
        guard let space = image.colorSpace,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
              let data = context.data
        else { return image }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let rowBytes = context.bytesPerRow
        let pixels = data.bindMemory(to: UInt8.self, capacity: rowBytes * height)
        for rect in rects {
            let x0 = max(0, Int(rect.minX.rounded(.down)) - 1), x1 = min(width, Int(rect.maxX.rounded(.up)) + 1)
            let y0 = max(0, Int(rect.minY.rounded(.down)) - 1), y1 = min(height, Int(rect.maxY.rounded(.up)) + 1)
            let top = max(0, y0 - 2), bottom = min(height - 1, y1 + 1)
            guard x1 > x0, y1 > y0 else { continue }
            for x in x0..<x1 {
                for y in y0..<y1 {
                    let t = y1 > y0 ? Double(y - y0) / Double(max(1, y1 - y0 - 1)) : 0
                    for c in 0..<4 {
                        let a = Double(pixels[top * rowBytes + x * 4 + c]), b = Double(pixels[bottom * rowBytes + x * 4 + c])
                        pixels[y * rowBytes + x * 4 + c] = UInt8(max(0, min(255, a + (b - a) * t)))
                    }
                }
            }
        }
        return context.makeImage() ?? image
    }

    /// One pill's texts, drawn by Dimble at their AX frames. A value that
    /// names a team ("Senators 1") shows its last word when the frame is
    /// the width of that alone. `readAt` is when the pill was read.
    private func drawTexts(_ mirror: PillMirror, bits nodes: [TextBit], side: Side, why: String, readAt: Date = Date(), bridge: Bool = false) {
        guard let visual = mirror.visual else { return }
        let values = nodes.map(\.value)
        if !bridge { noteClock(mirror, new: values, at: readAt) }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        while mirror.textLayers.count > nodes.count { mirror.textLayers.removeLast().removeFromSuperlayer() }
        while mirror.textLayers.count < nodes.count {
            let layer = CATextLayer()
            layer.alignmentMode = .center
            layer.truncationMode = .none
            layer.isWrapped = false
            layer.contentsScale = side.scale
            layer.foregroundColor = NSColor.white.cgColor
            mirror.container.addSublayer(layer)
            mirror.textLayers.append(layer)
        }
        var shown: [String] = []
        for (node, layer) in zip(nodes, mirror.textLayers) {
            let size = max(6, node.frame.height / 1.15)
            let font = Self.font(size: size, forDigits: node.value.contains { $0.isNumber } && !node.value.contains(":"))
            let text = Self.displayText(node.value, width: node.frame.width, font: font)
            shown.append(text)
            layer.font = font
            layer.fontSize = size
            layer.string = text
            let lineHeight = ceil(font.ascender - font.descender)
            let relX = node.frame.minX - visual.minX
            let relY = node.frame.midY - visual.minY
            layer.frame = CGRect(x: relX - 6, y: visual.height - relY - lineHeight / 2 + 0.5, width: node.frame.width + 12, height: lineHeight)
        }
        CATransaction.commit()
        mirror.bits = nodes
        mirror.values = values
        if !bridge { mirror.lastRead = readAt }
        if shown != mirror.texts {
            if !mirror.texts.isEmpty {
                if Date().timeIntervalSince(mirror.textLoggedAt) >= 10 {
                    let more = mirror.textHeld > 0 ? ", \(mirror.textHeld) change(s) not logged before" : ""
                    PelmetLog.log("livemirror: display \(side.id) \"\(mirror.key)\" text \(mirror.texts) → \(shown) (seen by \(why)\(more))")
                    mirror.textLoggedAt = Date(); mirror.textHeld = 0
                } else { mirror.textHeld += 1 }
            }
            mirror.texts = shown
            mirror.textChangedAt = Date()
        }
    }

    nonisolated private static func font(size: CGFloat, forDigits: Bool) -> NSFont {
        if forDigits {
            let base = NSFont.systemFont(ofSize: size, weight: .bold)
            let condensed = base.fontDescriptor.addingAttributes([.traits: [NSFontDescriptor.TraitKey.width: -0.35]])
            return NSFont(descriptor: condensed, size: size) ?? base
        }
        return NSFont.monospacedDigitSystemFont(ofSize: size, weight: .semibold)
    }

    nonisolated private static func displayText(_ value: String, width: CGFloat, font: NSFont) -> String {
        let full = (value as NSString).size(withAttributes: [.font: font]).width
        if full <= width * 1.6 { return value }
        return value.split(separator: " ").last.map(String.init) ?? value
    }

    /// The mirrors in the cover, right to left from the « (from the icons
    /// out on their own beside it) in the order macOS shows the pills (the
    /// rightmost nearest the «), with macOS's own gap between pills
    /// (measured from their AX frames). When they do not all fit, the most
    /// recently started ones stay.
    private func layoutMirrors(_ side: Side) {
        guard let overlay = side.cover?.members.first else { return }
        let window = overlay.windowFrame
        let placed = side.mirrors.filter { $0.visual != nil && $0.misses < 3 }
        var gaps: [CGFloat] = []
        for (a, b) in zip(placed, placed.dropFirst()) {
            let g = b.visual!.minX - a.visual!.maxX
            if g > 0, g < 60 { gaps.append(g) }
        }
        let gap = gaps.isEmpty ? Self.pillGap : gaps.sorted()[gaps.count / 2]
        var right = min(side.coverMaxX, side.predictedRight ?? .greatestFiniteMagnitude)
        if let alone = side.alone {
            // Beside the « only: a cover ended at the Hidden icons (a hover
            // under live mode) no longer reaches it.
            let beside = hiddenOut == nil
            CATransaction.begin(); CATransaction.setDisableActions(true)
            if !side.aloneAttached {
                alone.removeFromSuperlayer()
                overlay.addLayer(alone)
                side.aloneAttached = true
            }
            alone.isHidden = !beside
            alone.frame = CGRect(x: right - alone.bounds.width - window.minX, y: 0, width: alone.bounds.width, height: window.height)
            CATransaction.commit()
            if beside { right -= alone.bounds.width }
        }
        right -= Self.gap
        let left = side.coverMinX + 4
        func need(_ list: [PillMirror]) -> CGFloat { list.reduce(0) { $0 + $1.visual!.width } + gap * CGFloat(max(0, list.count - 1)) }
        var fit = placed
        var dropped: [PillMirror] = []
        while fit.count > 1, need(fit) > right - left {
            guard let oldest = fit.enumerated().min(by: { ($0.element.firstSeen, $0.offset) < ($1.element.firstSeen, $1.offset) })?.offset else { break }
            dropped.append(fit.remove(at: oldest))
        }
        let note = dropped.map(\.key).sorted().joined(separator: ", ")
        if note != side.droppedNote {
            side.droppedNote = note
            if !note.isEmpty { PelmetLog.log("livemirror: display \(side.id) no room for every mirror (\(Int(right - left))pt) — dropped [\(note)], kept [\(fit.map(\.key).joined(separator: ", "))]") }
        }
        var x = right
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for mirror in placed.reversed() {
            guard let visual = mirror.visual else { continue }
            mirror.dropped = !fit.contains { $0 === mirror }
            let leaving = handingOver || mirrorsLeaving
            guard !mirror.dropped else {
                mirror.global = nil
                if !leaving { present(mirror, false) }
                continue
            }
            x -= visual.width
            let cg = cocoa(visual)
            let global = NSRect(x: x, y: cg.minY, width: visual.width, height: visual.height)
            let was = mirror.global
            mirror.global = global
            mirror.container.frame = CGRect(x: global.minX - window.minX, y: global.minY - window.minY, width: visual.width, height: visual.height)
            mirror.base.frame = mirror.container.bounds
            if !mirror.attached {
                mirror.container.removeFromSuperlayer()
                overlay.addLayer(mirror.container)
                mirror.attached = true
            }
            // A mirror that moves on screen (the « shifted, a pill came or
            // went) slides to its place instead of jumping.
            if let was, mirror.shown, !leaving, abs(was.minX - global.minX) > 0.5, abs(was.minX - global.minX) < 400 {
                let slide = CABasicAnimation(keyPath: "position.x")
                slide.isAdditive = true
                slide.fromValue = was.minX - global.minX
                slide.toValue = 0
                slide.duration = 0.22
                slide.timingFunction = Self.enterCurve
                mirror.container.add(slide, forKey: "pelmetShift")
            }
            if !leaving { present(mirror, !missionControlUp && mirror.base.contents != nil) }
            x -= gap
        }
        CATransaction.commit()
        let placedNote = placed.filter { !$0.dropped }.compactMap { m in m.global.map { "\(m.key) \(Int($0.minX))..\(Int($0.maxX))" } }.joined(separator: ", ")
        if placedNote != side.placedNote {
            side.placedNote = placedNote
            PelmetLog.log("livemirror: display \(side.id) mirrors [\(placedNote)] in the cover \(Int(side.coverMinX))..\(Int(side.coverMaxX)), gap \(Int(gap))pt")
        }
    }

    // MARK: Watching the pills

    /// Finds the pills on a display and keeps the mirrors to them: a mirror
    /// per pill, a new one when an activity starts, gone after two passes
    /// that do not find it. The net is read every 2 s.
    private func discoverPills(_ side: Side) async {
        side.needsDiscovery = false
        let bounds = side.bounds
        let found = await Task.detached(priority: .userInitiated) { PillProbe.pills(in: bounds) }.value
        // A pill already mirrored is counted by its name: its tree is not read
        // again every pass. One not seen before is read, and counts when it
        // shows a text or a logo (a copy with neither is no pill to mirror).
        let known = Set(side.mirrors.filter { !$0.provisional }.map { $0.copy.name })
        let unknown = found.filter { !known.contains($0.name) }
        let box = ElementBox(list: unknown.map(\.element))
        let trees = await Task.detached(priority: .userInitiated) { () -> [PillTree?] in box.list.map { PillProbe.readTree($0) } }.value
        var usable = found.filter { known.contains($0.name) }
        for (copy, tree) in zip(unknown, trees) {
            if let tree, !tree.texts.isEmpty || !tree.images.isEmpty { usable.append(copy) }
        }
        usable.sort { $0.frame.minX < $1.frame.minX }
        let keys = PillProbe.keys(of: usable)
        let before = side.mirrors.map(\.key)
        var seen = Set<String>()
        for (copy, key) in zip(usable, keys) {
            seen.insert(key)
            if let mirror = side.mirrors.first(where: { $0.key == key }) {
                mirror.copy = copy
                mirror.absent = 0
                if mirror.provisional {
                    mirror.provisional = false
                    mirror.tree = nil
                    PelmetLog.log("livemirror: display \(side.id) pill \"\(key)\" is back — its mirror, drawn from memory, takes it over")
                }
            } else {
                side.mirrors.append(PillMirror(key: key, copy: copy))
            }
        }
        for mirror in side.mirrors where !seen.contains(mirror.key) && !mirror.provisional { mirror.absent += 1 }
        let gone = side.mirrors.filter { $0.absent >= 2 }
        for mirror in gone { retire(mirror) }
        side.mirrors.removeAll { $0.absent >= 2 }
        side.mirrors.sort { $0.copy.frame.minX < $1.copy.frame.minX }
        let after = side.mirrors.map(\.key)
        if before != after {
            PelmetLog.log("livemirror: pills [\(before.joined(separator: ", "))] → [\(after.joined(separator: ", "))] (display \(side.id))")
            side.droppedNote = ""
            layoutMirrors(side)
        }
    }

    /// A mirror that is done leaves with the exit motion, then its layer goes.
    private func retire(_ mirror: PillMirror) {
        present(mirror, false)
        let layer = mirror.container
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { layer.removeFromSuperlayer() }
    }

    // MARK: Clocks

    /// A read starts this long before the instant a clock is due (the read
    /// itself takes a few milliseconds, so it lands just after the tick); one
    /// that finds the old value tries again every `clockRetry`.
    private static let clockLead: TimeInterval = -0.010
    private static let clockRetry: TimeInterval = 0.012

    /// A pill's texts were read: which one is a clock, which way it counts
    /// and, from reads close together, when it ticks (so the next reads wait
    /// for it instead of polling). A text that moves by a second twice,
    /// a second apart, is a clock; a score that moved once is not.
    private func noteClock(_ mirror: PillMirror, new values: [String], at readAt: Date) {
        var c = mirror.clock
        let old = mirror.values
        defer { mirror.clock = c; if c.next != nil { ensureClockLoop() } }
        guard let i = values.indices.first(where: { ClockText.seconds(values[$0]) != nil }) else { c = ClockState(); return }
        if c.index != i { c = ClockState(); c.index = i }
        let b = ClockText.seconds(values[i])!
        let gap = mirror.lastRead.map { readAt.timeIntervalSince($0) } ?? 99
        let was = old.count == values.count ? ClockText.seconds(old[i]) : nil
        if let a = was, a != b {
            let delta = b - a
            let est = readAt.addingTimeInterval(-min(gap, 1) / 2)
            if gap > 0.3 {
                // Reads far apart say nothing of the instant. A locked clock
                // keeps its phase through a resync of a few seconds.
                if c.locked, let prev = c.tick, abs(delta) <= 5 { c.tick = prev.addingTimeInterval(floor(readAt.timeIntervalSince(prev))) }
                else if abs(delta) == 1 { c.dir = delta; c.tick = nil; c.locked = false }
                else { c = ClockState(); c.index = i }
            } else if abs(delta) == 1 {
                if c.dir == delta, let prev = c.tick {
                    let step = est.timeIntervalSince(prev), n = step.rounded()
                    if n >= 1, abs(step - n) < (gap <= 0.06 ? 0.3 : 0.35) {
                        if gap <= 0.06 { c.tick = est; c.locked = true }
                        else if c.locked, abs(step - n) < 0.12 { c.tick = prev.addingTimeInterval(n) }
                        else { c.tick = est; c.locked = false }
                    } else { c.tick = est; c.locked = false }
                } else {
                    c.dir = delta; c.tick = est; c.locked = false
                }
            } else { c = ClockState(); c.index = i }
        }
        c.text = values[i]
        c.seconds = b
        // The next read.
        guard c.dir != 0, let tick = c.tick else { c.next = nil; c.due = nil; return }
        if c.locked {
            let k = floor(readAt.timeIntervalSince(tick)) + 1
            c.due = tick.addingTimeInterval(k)
            c.next = c.due!.addingTimeInterval(Self.clockLead)
        } else {
            c.due = nil
            c.next = max(readAt.addingTimeInterval(0.04), tick.addingTimeInterval(0.72))
        }
    }

    /// Times the reads of the clocks that have a phase, and carries a clock
    /// on while its pill is not there. Ends when nothing is timed.
    private func ensureClockLoop() {
        guard clockLoop == nil else { return }
        clockLoop = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, self.isActive else { break }
                if self.handingOver || self.exiting {
                    try? await Task.sleep(for: .milliseconds(200))
                    continue
                }
                let timed = self.sides.flatMap { side in side.mirrors.compactMap { $0.clock.next != nil && !$0.dropped ? (side, $0) : nil } }
                guard !timed.isEmpty else { break }
                let now = Date().addingTimeInterval(0.002)
                for (side, mirror) in timed where (mirror.clock.next ?? .distantFuture) <= now { await self.clockStep(side, mirror) }
                let next = self.sides.flatMap(\.mirrors).compactMap { $0.dropped ? nil : $0.clock.next }.min()
                let wait = next.map { max(0.004, min(1.0, $0.timeIntervalSinceNow)) } ?? 0.05
                try? await Task.sleep(for: .seconds(wait))
            }
            self?.clockLoop = nil
        }
    }

    /// One clock read that is due: a quick read of the pill (the pill's
    /// frame and its texts), or, for a mirror whose pill is not there, the
    /// clock counted on from its last tick.
    private func clockStep(_ side: Side, _ mirror: PillMirror) async {
        guard side.mirrors.contains(where: { $0 === mirror }) else { return }
        let now = Date()
        if mirror.provisional {
            let c = mirror.clock
            guard c.locked, let tick = c.tick, let i = c.index, i < mirror.bits.count, let text = c.extrapolated(at: now) else { mirror.clock.next = nil; return }
            if mirror.bits[i].value != text {
                var bits = mirror.bits
                bits[i].value = text
                drawTexts(mirror, bits: bits, side: side, why: "carried on", readAt: now, bridge: true)
            }
            mirror.clock.next = tick.addingTimeInterval(floor(now.timeIntervalSince(tick) + 0.001) + 1)
            return
        }
        guard let tree = mirror.tree, !mirror.reading else { mirror.clock.next = now.addingTimeInterval(0.1); return }
        mirror.reading = true
        mirror.clock.next = nil
        let box = ElementBox(list: [mirror.copy.element])
        let result = await Task.detached(priority: .userInitiated) { PillProbe.quick(tree, of: box.list[0]) }.value
        mirror.reading = false
        guard isActive, !exiting, !handingOver, !mirror.provisional, side.mirrors.contains(where: { $0 === mirror }) else { return }
        let readAt = Date()
        switch result {
        case .values(let v):
            let patched = tree.patched(with: v)
            mirror.tree = patched
            drawTexts(mirror, bits: patched.texts.map { TextBit(value: $0.value, frame: $0.frame) }, side: side, why: "clock", readAt: readAt)
        case .same:
            mirror.lastRead = readAt
        case .reread:
            await refreshSide(side, why: "clock", full: true)
        }
        // Nothing set the next read: this one found no change.
        guard mirror.clock.next == nil, mirror.clock.dir != 0, let tick = mirror.clock.tick else { return }
        var c = mirror.clock
        if c.locked, let due = c.due {
            if readAt.timeIntervalSince(due) > 0.4 { c.locked = false; c.due = nil; c.next = readAt.addingTimeInterval(0.04) }
            else { c.next = readAt.addingTimeInterval(Self.clockRetry) }
        } else if readAt.timeIntervalSince(tick) > 2.6 {
            c = ClockState(); c.index = mirror.clock.index
        } else {
            c.next = readAt.addingTimeInterval(0.04)
        }
        mirror.clock = c
    }

    // MARK: Clicks

    private func clicked(_ side: Side, at point: NSPoint) {
        let visible = side.mirrors.filter { !$0.dropped && $0.global != nil }
        guard !visible.isEmpty else {
            PelmetLog.log("livemirror: click at \(Int(point.x)),\(Int(point.y)) on display \(side.id) — no mirror yet, swallowed")
            return
        }
        guard let mirror = visible.first(where: { !$0.container.isHidden && $0.global!.insetBy(dx: -2, dy: -4).contains(point) }) else {
            let span = visible.map { $0.global! }.reduce(visible[0].global!) { $0.union($1) }
            PelmetLog.log("livemirror: click at \(Int(point.x)),\(Int(point.y)) on display \(side.id) — outside the mirrors (\(Int(span.minX))..\(Int(span.maxX))), swallowed")
            return
        }
        guard !mirror.provisional else {
            PelmetLog.log("livemirror: click on \"\(mirror.key)\" — its pill is not back yet, swallowed")
            return
        }
        let id = side.id
        let name = mirror.copy.name
        // The cover was ordered front by the click: back under Sconce at once.
        for ms in [0, 20, 60, 120] {
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(ms)) { [weak self] in self?.enforceOrder("click +\(ms)ms") }
        }
        Task { @MainActor in
            let at = Date()
            // The card's state is read from AX on every click, never kept; the
            // open card's group is named for its pill.
            let probe = await self.cardProbe()
            if probe.open {
                let own = probe.owners.contains(name) || probe.owners.allSatisfy(\.isEmpty)
                if own {
                    // The click is already an outside interaction for the card
                    // and collapses it; a press on top interrupts that.
                    PelmetLog.log("livemirror: click — \"\(mirror.key)\" card open=true action=close result=the click closes it, no press (display \(id); \(probe.detail))")
                    await self.confirmCardClosed(from: at, side: side, name: name)
                    return
                }
                // Another pill's card is open: the click collapses it, then this one opens.
                PelmetLog.log("livemirror: click — \"\(mirror.key)\" while \(probe.owners) is open, action=close it first (the click does), then press")
                var closed = false
                for _ in 0..<14 {
                    try? await Task.sleep(for: .milliseconds(100))
                    if !(await self.cardProbe()).open { closed = true; break }
                }
                if !closed { PelmetLog.log("livemirror: card \(probe.owners) still open 1.4s after — pressing \"\(mirror.key)\" anyway") }
            }
            let result = await self.pressPill("mirror click", side: side, name: name)
            PelmetLog.log("livemirror: click — \"\(mirror.key)\" card open=false action=press result=\(result) (display \(id); \(probe.detail))")
            var last = probe
            for _ in 0..<12 {
                try? await Task.sleep(for: .milliseconds(100))
                last = await self.cardProbe()
                if last.owners.contains(name) || (last.open && last.owners.allSatisfy(\.isEmpty)) {
                    PelmetLog.log("livemirror: card \"\(name)\" opened \(Int(-at.timeIntervalSinceNow * 1000))ms after the click")
                    return
                }
            }
            PelmetLog.log("livemirror: card \"\(name)\" did not open within 1.2s of the press — \(last.detail)")
        }
    }

    private func confirmCardClosed(from start: Date, side: Side, name: String) async {
        var last = ""
        for _ in 0..<14 {
            try? await Task.sleep(for: .milliseconds(100))
            let probe = await cardProbe()
            last = probe.detail
            if !probe.open || !probe.owners.contains(name) && !probe.owners.allSatisfy(\.isEmpty) {
                PelmetLog.log("livemirror: card closed \(Int(-start.timeIntervalSinceNow * 1000))ms after the click (\(probe.detail))")
                return
            }
        }
        PelmetLog.log("livemirror: card still open 1.4s after the click — pressing the pill (\(last))")
        let result = await pressPill("click fallback", side: side, name: name)
        PelmetLog.log("livemirror: click — card open=true action=press (fallback) result=\(result)")
    }

    // MARK: Cover order

    private func logOrder(_ overlay: ConcealGhostOverlay, why: String) {
        let below = overlay.orderBelowForeign()
        PelmetLog.log("livemirror: cover order — \(below.map { "below \($0.owner) \($0.id)" } ?? "in front, no foreign surface over the strip") (\(why))")
    }

    /// Every cover shown again ends directly below the foreign surfaces.
    private func setCoversShown(_ shown: Bool, why: String) {
        for side in sides {
            guard let overlay = side.cover?.members.first else { continue }
            overlay.setShown(shown)
            if shown { logOrder(overlay, why: why) }
        }
    }

    /// The window server's order, not ours: a cover that sits above a
    /// foreign surface (a click orders it in front of its level; a strip made
    /// while Sconce's window was being redrawn) goes back below it.
    private func enforceOrder(_ why: String) {
        let lines = ConcealGhostOverlay.keepBelowForeign()
        guard !lines.isEmpty else { return }
        // Mission Control reorders the covers every pass: one line per 5 s.
        orderFixes += lines.count
        guard Date().timeIntervalSince(orderLoggedAt) >= 5 else { return }
        orderLoggedAt = Date()
        PelmetLog.log("livemirror: cover order — corrected \(orderFixes) time(s), last: \(lines.last ?? "") (\(why))")
        orderFixes = 0
    }
    private var orderLoggedAt = Date.distantPast
    private var orderFixes = 0

    /// A cover (a reveal's strip, a held bar) was just made: its order is
    /// checked now, and twice more while the window server settles, instead
    /// of waiting out the keeper's idle second.
    private func coverMade() {
        guard isActive || handingOver || entering else { return }
        Task { @MainActor [weak self] in
            for delay in [0, 40, 120] {
                if delay > 0 { try? await Task.sleep(for: .milliseconds(delay == 40 ? 40 : 80)) }
                self?.enforceOrder("new cover")
            }
        }
    }

    /// Covers are checked about every second, every 50ms while a transition
    /// runs. Mission Control is watched on its own, faster rest (`keeperRest`).
    private func startOrderKeeper() {
        guard orderKeeper == nil else { return }
        ConcealGhostOverlay.onNewCover = { [weak self] in self?.coverMade() }
        orderKeeper = Task { @MainActor [weak self] in
            var lastEnforce = Date.distantPast
            while !Task.isCancelled {
                guard let self else { return }
                let busy = ConcealGhostOverlay.coverCount > 1 || self.entering || self.exiting || self.handingOver
                if self.isActive { self.watchMissionControl() }
                let every: TimeInterval = busy ? 0.05 : (self.isActive ? 1.2 : 1.0)
                if ConcealGhostOverlay.coverCount > 0, Date().timeIntervalSince(lastEnforce) >= every - 0.01,
                   !self.coverLifted || ConcealGhostOverlay.coverCount > 1 {
                    lastEnforce = Date()
                    self.enforceOrder(busy ? "transition" : "keeper")
                }
                let rest = self.keeperRest(busy: busy)
                if rest >= .milliseconds(400) {
                    // Nobody is at the machine: the windows are listed every
                    // 0.4 s, but the input clock (one cheap call) is looked at
                    // every 0.1 s, and the first input starts the quick
                    // watch at once (Mission Control starts with one).
                    for _ in 0..<4 {
                        try? await Task.sleep(for: .milliseconds(100))
                        if Self.secondsSinceInput() < 0.3 { break }
                    }
                } else {
                    try? await Task.sleep(for: rest)
                }
            }
        }
    }

    nonisolated private static func secondsSinceInput() -> Double {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }

    /// How long the keeper rests. Mission Control opens from a key, a swipe or
    /// a hot corner, all input, so while the user has touched the Mac in the
    /// last 3 s the window server is asked every 80 ms (a call is ~0.2 ms),
    /// and every 400 ms otherwise (a scripted open has no input before it).
    private func keeperRest(busy: Bool) -> Duration {
        if busy { return .milliseconds(50) }
        guard isActive else { return .milliseconds(1000) }
        return Self.secondsSinceInput() < 3 ? .milliseconds(80) : .milliseconds(400)
    }

    /// Mission Control is up while the window server shows its "Spaces Bar"
    /// (or the Expose shield): the real bar is gone and a pill mirror would
    /// float on top of the Spaces bar, so the mirrors are hidden while it is
    /// up and back the moment it is gone. The covers STAY: the real bar comes
    /// back during Mission Control's closing animation (~0.45 s before its
    /// windows are gone), and a cover that had stepped aside let every hidden
    /// icon show for that long (measured, build 23).
    private var missionControlUp = false
    private static func missionControlIsUp() -> Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) else { return false }
        let ownerKey = Unmanaged.passUnretained(kCGWindowOwnerName).toOpaque(), nameKey = Unmanaged.passUnretained(kCGWindowName).toOpaque()
        for i in 0..<CFArrayGetCount(list) {
            let window = unsafeBitCast(CFArrayGetValueAtIndex(list, i), to: CFDictionary.self)
            guard let owner = CFDictionaryGetValue(window, ownerKey),
                  CFStringCompare(unsafeBitCast(owner, to: CFString.self), "WindowManager" as CFString, []) == .compareEqualTo,
                  let name = CFDictionaryGetValue(window, nameKey)
            else { continue }
            let title = unsafeBitCast(name, to: CFString.self) as String
            if title == "Spaces Bar" || title == "ExposeShieldWindow" { return true }
        }
        return false
    }

    private func watchMissionControl() {
        let up = Self.missionControlIsUp()
        guard up != missionControlUp, !exiting, !handingOver else { return }
        missionControlUp = up
        PelmetLog.log("livemirror: Mission Control \(up ? "is up — the mirrors step aside, the covers stay" : "is gone — the mirrors are back")")
        // A start has the mirrors' layout read the flag when it ends; a
        // retake (the Space changed under Mission Control) shows them back now,
        // not 2 s later when its pictures are done.
        guard !entering || retaking else { return }
        // Gone at once on the way in (the pills sat over Mission Control's
        // first frames, 0.12 s of fade made it worse); a short fade back,
        // Mission Control is moving everything itself.
        for side in sides {
            for mirror in side.mirrors { present(mirror, !up && !mirror.dropped && mirror.base.contents != nil, move: up ? .pop : .fade(0.12)) }
        }
    }

    /// The backdrop under the cover can't be told from here without a
    /// capture: the Space and the appearance changing are the signals. The
    /// pictures are taken again (`retake`) with the mirrors staying: they
    /// carry on from their kept stills and last texts, and the new stills
    /// replace the old ones in place (a still carries the backdrop in its
    /// rounded corners, so a Space's stills are always taken again).
    private func backdropMayHaveChanged(_ reason: String) async {
        try? await Task.sleep(for: .milliseconds(300))
        guard isActive, !handingOver, !entering, !exiting else { return }
        PelmetLog.log("livemirror: cover retake — \(reason)")
        await retake(reason)
    }

    /// A show rule put an icon on the bar or took it back (Wi-Fi dropped,
    /// Battery low). The covers hold the bar as it was, so the icon would
    /// stay under them until the activity ends. The converge has the new
    /// bar by now: the pictures are taken again, and a kept one is stale.
    func showRuleChangedBar() async {
        keptPictures = [:]
        let by = Date().addingTimeInterval(5)
        while entering, Date() < by { try? await Task.sleep(for: .milliseconds(50)) }
        guard isActive, !handingOver, !entering, !exiting else { return }
        PelmetLog.log("livemirror: cover retake — a show rule changed the bar")
        await retake("a show rule changed the bar")
    }

    private func retake(_ reason: String) async {
        await retakeOnce(reason)
        await leaveForDisplayChange()
    }

    private func retakeOnce(_ reason: String) async {
        guard let appState, isActive, !entering, !exiting, !handingOver else { return }
        hiddenOut = nil
        entering = true
        retaking = true
        defer { entering = false; retaking = false }
        let started = Date()
        func ms() -> Int { Int(-started.timeIntervalSinceNow * 1000) }
        let generation = backdropGeneration
        liftedReturn?.cancel()
        // The card goes with the pill.
        let open = await cardProbe()
        if open.open {
            PelmetLog.log("livemirror: card open (retake) — closing it")
            await pressPill("retake", name: open.owners.first { !$0.isEmpty })
        }
        guard isActive, !exiting, !handingOver, !standDown else { return }
        if coverLifted {
            coverLifted = false
            setCoversShown(true, why: "retake")
        }
        // Every mirror carries on as it is: no pill is read for it until its
        // pill is back, and its still is taken again then (the old one has
        // the old backdrop in its corners).
        kept = [:]
        for side in sides {
            side.trailing?.cancel()
            side.trailing = nil
            if let chevron = lastChevron { side.predictedRight = coverEnd(chevron, on: side) - 1 }
            for mirror in side.mirrors where !mirror.dropped {
                mirror.provisional = true
                mirror.look = nil
                mirror.snapTexts = nil
                mirror.lookCandidate = nil
                mirror.placeCandidate = nil
                if mirror.clock.locked { carryOn(mirror, now: Date()) }
            }
            // The « slides back and the extras leave: the cover reaches to the
            // concealed « again, where the picture ends.
            // (A display that shows every icon has its Hidden icons beyond the
            // cover's end: growing it would hide them.)
            if !side.showsAll, let picture = side.picture { buildCover(side, left: side.coverMinX, right: picture.windowFrame.maxX, why: "retake") }
        }
        // The assertion comes back; once the bar beneath is bare (the same
        // wait that lifts a cover) the pictures are taken, the old cover
        // staying up until the new one is.
        assertionDropped = false
        standDown = false
        await appState.engine.holdLift(false)
        PelmetLog.log("livemirror: retake — assertion back at \(ms())ms")
        await appState.waitUntilQuiesced(interval: 0.15, deadline: 2, poll: .milliseconds(30))
        let deadline = Date().addingTimeInterval(AppTiming.clockBlinkCoverDeadline)
        while Date() < deadline, await appState.engine.concealedItemsStillVisible() {
            try? await Task.sleep(for: .milliseconds(60))
        }
        await appState.waitUntilQuiesced(interval: 0.15, deadline: 1, poll: .milliseconds(30))
        PelmetLog.log("livemirror: retake — bar bare at \(ms())ms")
        guard wanted else { return }
        if let issue = prepIssue() { await abort("\(issue) (retake)"); return }
        guard let chevron = appState.chevronWindowFrame,
              let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        else { await abort("retake — no chevron or no shareable content", holdOff: true); return }
        for side in sides {
            if let display = content.displays.first(where: { $0.displayID == side.id }) { side.scDisplay = display }
            await measureMenus(side)
        }
        await goLive(chevron: chevron, started: started, retake: true)
        // Another change while this one ran: the pictures are not true yet.
        if generation != backdropGeneration, isActive, !exiting {
            Task { @MainActor [weak self] in await self?.backdropMayHaveChanged("the backdrop changed again") }
        }
    }

    /// The « (or the item) asked for a reveal: the cover goes, the real bar
    /// shows; the same again, or a few seconds, and it comes back.
    private func toggleCover(_ why: String) {
        coverLifted.toggle()
        liftedReturn?.cancel()
        PelmetLog.log("livemirror: cover \(coverLifted ? "lifted — the real bar shows" : "back") (\(why))")
        setCoversShown(!coverLifted, why: "cover back (\(why))")
        guard coverLifted else { return }
        liftedReturn = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.liftedCoverReturn))
            guard let self, !Task.isCancelled, self.coverLifted else { return }
            self.toggleCover("\(Int(Self.liftedCoverReturn))s")
        }
    }

    // MARK: Tick

    private func tick() async {
        guard let appState else { return }
        tickCount += 1
        // The « moved (extras came or went, the capture indicator lit or
        // went out): the cover's end follows it.
        if let chevron = appState.chevronWindowFrame, let last = lastChevron,
           abs(chevron.minX - last.minX) > 0.5 || abs(chevron.minY - last.minY) > 0.5 {
            PelmetLog.log("livemirror: re-measure — chevron \(Int(last.minX)) → \(Int(chevron.minX))")
            lastChevron = chevron
            var short = false
            for side in sides {
                if side.showsAll || hiddenOut != nil { await measureRunEdge(side) }
                // A picture that ends short of the « (an extra right of it,
                // Dimble's ▶, went away since it was taken) can't reach it:
                // the hidden icons showed in between until the activity
                // ended. The pictures are taken again.
                if !buildCover(side, left: side.coverMinX, right: coverEnd(chevron, on: side) - 1, why: "chevron moved"), !side.showsAll {
                    short = true
                }
                if side.showsAll { noteRun(side) }
            }
            if short { Task { @MainActor [weak self] in await self?.backdropMayHaveChanged("the « moved past the picture") } }
        }
        for side in sides {
            // The pills are looked for every 2 s (an activity starting or ending),
            // read every 2 s too; while a text moves (a countdown) or a look
            // settles they are read every tick, so the mirror skips no second.
            let now = Date()
            // A pill whose clock has a phase is read where it ticks (`clockLoop`),
            // not here.
            let moving = side.mirrors.contains { m in
                guard !m.provisional else { return false }
                return (m.clock.next == nil && (m.textChangedAt.map { now.timeIntervalSince($0) < 5 } ?? false)) || m.lookCandidate != nil || m.placeCandidate != nil
            }
            // Quick reads (the frame and the texts) every 2 s as the net, the
            // pills looked for every 4 s, the whole tree read every 10 s.
            let net = tickCount % Self.fallbackEvery == 0
            let discoverNet = tickCount % (Self.fallbackEvery * 2) == 0
            let deep = tickCount % (Self.fallbackEvery * 5) == 0
            var looked = false
            if !side.mirrors.contains(where: { !$0.provisional }) || side.needsDiscovery || discoverNet || now < lookEagerlyUntil {
                await discoverPills(side)
                looked = true
            }
            if side.mirrors.contains(where: { !$0.provisional }), moving || net || looked { await refreshSide(side, why: looked ? "found" : "poll", full: deep) }
        }
        for side in sides { side.cover?.keepUp(for: Self.coverSafety) }
        // Hidden out under live mode goes back once the pointer has been off
        // the bar for the re-hide delay (the tick's quarter second at least),
        // with no button down (a ⌘-drag may pass below the bar).
        if let out = hiddenOut {
            if Self.pointerInBar() || NSEvent.pressedMouseButtons != 0 {
                hiddenOut?.outSince = nil
            } else if let since = out.outSince {
                if Date().timeIntervalSince(since) >= max(0.2, appState.settings.rehideDelay) { await hideHidden("the pointer left the bar") }
            } else {
                hiddenOut?.outSince = Date()
            }
        }
        // The assertion is down for the pill's sake: with no pill to mirror
        // (the log said an activity runs, the bar shows none) live mode has
        // nothing to do and leaves, and waits longer each time in a row.
        let anyPill = sides.contains { $0.mirrors.contains { !$0.dropped && $0.misses < 3 && !$0.provisional } }
        if anyPill {
            noPillSince = nil
            emptyStrikes = 0
        } else if let since = noPillSince {
            if Date().timeIntervalSince(since) > Self.noPillGrace {
                emptyStrikes += 1
                let hold = min(600, 60 * pow(2, Double(emptyStrikes - 1)))
                retryNotBefore = Date().addingTimeInterval(hold)
                holdOffWhy = "no pill was found last time — holding off (a new activity ends the hold-off)"
                PelmetLog.log("livemirror: no pill to mirror for \(Int(Self.noPillGrace))s — leaving live mode, not trying again for \(Int(hold))s")
                await exit("no pill to mirror")
                return
            }
        } else {
            noPillSince = Date()
        }
        if Date().timeIntervalSince(lastSummaryAt) > 10 {
            let span = Int(Date().timeIntervalSince(lastSummaryAt))
            lastSummaryAt = Date()
            for side in sides {
                PelmetLog.log("livemirror: display \(side.id) \(span)s — snapshots \(side.snapshots) so far, pills \(side.mirrors.map { "\($0.key) \($0.texts)" })")
            }
        }
    }

    // MARK: Exit

    func exit(_ reason: String) async {
        guard let appState, isActive, !exiting else { return }
        exiting = true
        defer { exiting = false }
        hiddenOut = nil
        let started = Date()
        PelmetLog.log("livemirror: exit — \(reason)")
        // The mirrors leave first, the way the bar's own items do (the reveal
        // animation's exit); the cover stays up until the bar beneath is back.
        mirrorsLeaving = true
        for side in sides { for mirror in side.mirrors { present(mirror, false) } }
        liftedReturn?.cancel()
        kept = [:]; remembered = [:]; keptPictures = [:]
        // The card goes with the pill.
        let open = await cardProbe()
        if open.open {
            PelmetLog.log("livemirror: card open (exit) — closing it")
            await pressPill("exit", name: open.owners.first { !$0.isEmpty })
        }
        if coverLifted {
            coverLifted = false
            setCoversShown(true, why: "exit")
        }
        for side in sides {
            side.trailing?.cancel()
            side.trailing = nil
            PelmetLog.log("livemirror: display \(side.id) \(side.snapshots) snapshot(s) this run")
        }
        // The « slides back and the extras leave: the cover reaches to the
        // concealed « again, where the picture ends. The mirrors stay where
        // they stand while they go.
        for side in sides {
            if let chevron = lastChevron { side.predictedRight = coverEnd(chevron, on: side) - 1 }
            // (Not on a display that shows every icon: its Hidden icons stand
            // right of the cover, and the cover stays as it is until the bar
            // beneath is bare.)
            if !side.showsAll, let picture = side.picture { buildCover(side, left: side.coverMinX, right: picture.windowFrame.maxX, why: "exit", keepMirrors: true) }
        }
        await appState.engine.holdLift(false)
        PelmetLog.log("livemirror: assertion back at \(Int(-started.timeIntervalSinceNow * 1000))ms")
        // The assertion is held again: the coordinator's lift tail (`endLive`)
        // has the bar from here, and a reveal in these moments is an
        // ordinary one.
        appState.transitions.liveModeActive = false
        ConcealGhostOverlay.liveModeBlocksCaptures = false
        resetRunState()
        mirrorsLeaving = true
        await appState.transitions.endLive(covers: sides.compactMap(\.cover))
        sides = []
        isActive = false
        lastChevron = nil
        PelmetLog.log("livemirror: exit done in \(Int(-started.timeIntervalSinceNow * 1000))ms")
    }
}
