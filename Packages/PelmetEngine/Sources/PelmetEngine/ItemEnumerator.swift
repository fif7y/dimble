// ItemEnumerator.swift
// AX snapshot of MenuBarAgent's item tree. Verified structure (M1 findings):
// AXApplication → AXWindow (one per display) → `?`-role groups, one per item.
// On the active display's bar an app's item is its real AXButton; on every
// other bar it is a stand-in nesting the owning app's AXApplication node
// (probed 2026-10-13). System items are AXMenuBarItem leaves with a
// com.apple.menuextra.* identifier.

import AppKit
import ApplicationServices
import Foundation
import PelmetCore

public struct RawItem: Equatable, Sendable {
    public let id: ItemID
    public let frame: CGRect
    public let appName: String?
    /// See `ObservedItem.hostIsBundleless`.
    public let hostIsBundleless: Bool
    /// See `ObservedItem.pid`.
    public let pid: pid_t
}

/// Bundle attribution of an item's owning process.
private struct HostBundle {
    let id: String
    /// The process itself has no LS bundle id; `id` came from walking the
    /// executable path up to the enclosing .app.
    let bundleless: Bool
}

/// Runs off the main actor: AX calls into busy apps can block, so snapshots are
/// taken on a background executor with short messaging timeouts.
public actor ItemEnumerator {
    public init() {}
    static let agentBundleID = PelmetBundle.agentID

    private var agentElement: AXUIElement?
    private var agentPID: pid_t = 0

    /// Correlates each observed item group to a stable agent tag. Tags come
    /// from the positions plist domain (`status:<bundle>::<title>`); we build
    /// the same shape from the AX tree so both sources agree.
    public func snapshotItems() -> [RawItem] {
        lastCopies = [:]
        guard let agent = resolveAgent() else {
            noteEmpty("MenuBarAgent not running")
            return []
        }
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(agent, kAXChildrenAttribute as CFString, &value)
        guard let windows = value as? [AXUIElement] else {
            noteEmpty("agent tree unreadable (AXError \(error.rawValue))")
            return []
        }
        var byID: [ItemID: RawItem] = [:]
        var order: [ItemID] = []
        var copies: [ItemID: [CGRect]] = [:]
        // An app's extras bar is the same under every group of it, on every
        // display: read once per walk.
        var extrasByPID: [pid_t: StatusExtras] = [:]
        for window in windows {
            guard role(of: window) == "AXWindow" else { continue }
            guard let groups = copyAttribute(window, kAXChildrenAttribute) as? [AXUIElement] else {
                continue
            }
            var described: [RawItem?] = []
            var standIns: [pid_t: [(slot: Int, group: StandIn)]] = [:]
            for group in groups {
                switch describeGroup(group, extras: &extrasByPID) {
                case .item(let item):
                    described.append(item)
                case .standIn(let standIn):
                    standIns[standIn.pid, default: []].append((described.count, standIn))
                    described.append(nil)
                case nil:
                    continue
                }
            }
            // A stand-in neither its place nor its being the app's lone
            // group can name stays out of the walk: the active display's
            // real button still reports the item.
            for (pid, groupsOfApp) in standIns {
                guard let extras = extrasByPID[pid] else { continue }
                let bundle = groupsOfApp[0].group.host.id
                // A section helper hosts only `Pelmet.`-titled own items. Its
                // lone unread group as `Item-0` keyed the helper itself as an
                // app (`bundle:…items.alwaysHidden`): no section, so Visible,
                // a "Dimble Items" tile out of place and an Apply (1) that
                // came back after every Apply (Gab, 2026-10-29).
                let helperGuess = extras.naming == .unread && PelmetBundle.helperIDs.contains(bundle)
                let titles = helperGuess ? groupsOfApp.map { _ in nil } : Self.standInTitles(
                    forGroups: groupsOfApp.map(\.group.frame), naming: extras.naming, items: extras.items
                )
                for (entry, title) in zip(groupsOfApp, titles) {
                    guard let title else { continue }
                    described[entry.slot] = entry.group.item(titled: title)
                }
                let unnamed = titles.filter { $0 == nil }.count
                let unread = extras.naming == .unread
                logOnce(unnamed == 0
                    ? "enumerate: \(groupsOfApp.count) stand-in(s) of \(bundle) named " + (unread ? "as its one icon, no extras bar to read" : "by position")
                    : "enumerate: \(unnamed) of \(groupsOfApp.count) stand-in(s) of \(bundle) left unnamed — "
                        + (unread ? "no extras bar to read" : "\(extras.items.count) item(s) on its extras bar")
                        + (!unread && unnamed == groupsOfApp.count && groupsOfApp.count == extras.items.count ? ", places or width gaps disagree" : ""),
                    pid: nil)
            }
            for case let item? in described {
                copies[item.id, default: []].append(item.frame)
                if let existing = byID[item.id] {
                    // The same item appears once per display. Prefer the
                    // main-display occurrence so every frame lives in one
                    // coordinate space — boundary comparisons break across
                    // mixed display spaces. The band test alone is not
                    // enough: a display parked beside the main one, tops
                    // aligned, puts its bar at y ≈ 0 too, and its copies
                    // can come first in the walk (#27: every system item
                    // read past the main display's right edge, so the
                    // clock relay and the adopt pass measured nothing).
                    if !isMainDisplayFrame(existing.frame), isMainDisplayFrame(item.frame) {
                        byID[item.id] = item
                    }
                } else {
                    byID[item.id] = item
                    order.append(item.id)
                }
            }
        }
        let items = order.compactMap { byID[$0] }
        lastCopies = copies
        noteEmpty(items.isEmpty ? "agent tree has \(windows.count) window(s), no items" : nil)
        return items
    }

    /// Every frame the last walk named each item at, one per display's bar
    /// (the walk itself keeps the main display's): what a press made from
    /// another display clicks (#26).
    private var lastCopies: [ItemID: [CGRect]] = [:]
    public func barCopies() -> [ItemID: [CGRect]] { lastCopies }

    private var lastEmptyReason: String?
    /// Why a walk came back empty, once per reason, and once when the tree
    /// reads again: an empty walk holds converge off, so hidden icons stay
    /// on the bar for as long as these last.
    private func noteEmpty(_ reason: String?) {
        guard reason != lastEmptyReason else { return }
        lastEmptyReason = reason
        PelmetLog.log(reason.map { "enumerate: empty — \($0)" } ?? "enumerate: agent tree reads again")
    }

    /// In the band AND inside the main display's bounds (CG global space,
    /// main display at the origin) — the band alone admits a side-by-side
    /// display's bar.
    private func isMainDisplayFrame(_ frame: CGRect) -> Bool {
        MenuBarGeometry.isInBand(frame)
            && CGDisplayBounds(CGMainDisplayID()).contains(CGPoint(x: frame.midX, y: frame.midY))
    }

    // MARK: - Internals

    private func resolveAgent() -> AXUIElement? {
        if let cached = agentElement,
           NSRunningApplication(processIdentifier: agentPID)?.bundleIdentifier == Self.agentBundleID {
            return cached
        }
        guard let agent = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == Self.agentBundleID
        }) else { return nil }
        let element = AXUIElementCreateApplication(agent.processIdentifier)
        // A stuck app must never wedge a snapshot.
        AXUIElementSetMessagingTimeout(element, EngineTiming.axAgentTimeout)
        agentElement = element
        agentPID = agent.processIdentifier
        return element
    }

    /// A group read on its own, or a stand-in that only its place among its
    /// app's other groups on the same bar can name (`StandInMatch`).
    private enum Described {
        case item(RawItem)
        case standIn(StandIn)
    }

    /// A stand-in group its app's extras bar does not name on its own.
    private struct StandIn {
        let frame: CGRect
        let appName: String?
        let host: HostBundle
        let pid: pid_t

        func item(titled title: String?) -> RawItem {
            RawItem(
                id: .status(bundle: host.id, title: title ?? "Item-0"),
                frame: frame,
                appName: appName,
                hostIsBundleless: host.bundleless,
                pid: pid
            )
        }
    }

    private func describeGroup(_ group: AXUIElement, extras cache: inout [pid_t: StatusExtras]) -> Described? {
        guard let frame = frame(of: group) else {
            logDrop("no AXFrame", pid: nil, role: role(of: group))
            return nil
        }
        let kids = children(of: group)
        for child in kids {
            switch role(of: child) {
            case "AXApplication":
                // A stand-in: the owning app nested in the tree, with its
                // whole extras bar (every bar but the active display's).
                let appName = copyAttribute(child, kAXTitleAttribute) as? String
                var appPID: pid_t = 0
                AXUIElementGetPid(child, &appPID)
                guard let host = hostBundle(ofPID: appPID) else {
                    logDrop("no bundle id for AXApplication", pid: appPID, role: "AXApplication")
                    return nil
                }
                let extras = cache[appPID] ?? statusExtras(in: child)
                cache[appPID] = extras
                let standIn = StandIn(frame: frame, appName: appName, host: host, pid: appPID)
                guard let name = extras.name else { return .standIn(standIn) }
                return .item(standIn.item(titled: name))
            case "AXGroup":
                // System item: AXGroup wrapping an AXMenuBarItem.
                for leaf in children(of: child) where role(of: leaf) == "AXMenuBarItem" {
                    guard let identifier = copyAttribute(leaf, kAXIdentifierAttribute) as? String else {
                        continue
                    }
                    return .item(RawItem(
                        id: .status(bundle: Self.agentBundleID, title: identifier),
                        frame: frame,
                        appName: nil,
                        hostIsBundleless: false,
                        pid: agentPID
                    ))
                }
            case "AXButton":
                // Real NSStatusItem buttons on the active display's bar (and
                // other apps' dividers) sit in the tree as bare AXButtons — no
                // nested AXApplication. Attribute by the button's owning pid.
                if let item = describeLeaf(child, frame: frame) { return .item(item) }
            default:
                continue
            }
        }
        // Nothing matched the known shapes (a custom status view exposed as
        // AXStaticText/AXUnknown, issue #1: Little Snitch's two-line traffic
        // monitor). Any child with an owning pid outside the agent still
        // names its app; attribute by that rather than dropping the item.
        for child in kids {
            var pid: pid_t = 0
            AXUIElementGetPid(child, &pid)
            guard pid > 0, pid != agentPID else { continue }
            if let item = describeLeaf(child, frame: frame) {
                logOnce("enumerate: fallback — role=\(roleLabel(child)) → \(item.id.rawValue)", pid: pid)
                return .item(item)
            }
        }
        logDrop("unrecognized children \(kids.map { roleLabel($0) })", pid: nil, role: nil)
        return nil
    }

    /// Item attributed by a leaf element's owning pid, titled by whichever of
    /// title / identifier / description the element exposes.
    private func describeLeaf(_ element: AXUIElement, frame: CGRect) -> RawItem? {
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        guard pid > 0, let host = hostBundle(ofPID: pid) else {
            logDrop("no bundle id for leaf", pid: pid, role: role(of: element))
            return nil
        }
        let candidates = [
            copyAttribute(element, kAXTitleAttribute) as? String,
            copyAttribute(element, kAXIdentifierAttribute) as? String,
            copyAttribute(element, kAXDescriptionAttribute) as? String,
        ]
        var title = candidates.compactMap { $0?.isEmpty == false ? $0 : nil }.first
        // Time Machine's extra is a bare AXUnknown leaf with no title of its
        // own, so it collapsed onto "Item-0" and the editor called the tile
        // "System" (#19). SystemUIServer's extras bar still lists it: name
        // the leaf from there, the same way its AXApplication-shaped items
        // are named.
        if title == nil, host.id == PelmetBundle.systemUIServerID {
            title = statusExtras(in: AXUIElementCreateApplication(pid)).name
        }
        return RawItem(
            id: .status(bundle: host.id, title: title ?? "Item-0"),
            frame: frame,
            appName: NSRunningApplication(processIdentifier: pid)?.localizedName,
            hostIsBundleless: host.bundleless,
            pid: pid
        )
    }

    /// `NSRunningApplication.bundleIdentifier` first; when the process is not
    /// registered as an application (helper agents nested in another app's
    /// Components/ folder), read the Info.plist of the nearest enclosing .app
    /// on its executable path — and say so, because such an item is filed
    /// under a bundle the assertion can never hide.
    private func hostBundle(ofPID pid: pid_t) -> HostBundle? {
        guard pid > 0 else { return nil }
        let app = NSRunningApplication(processIdentifier: pid)
        if let id = app?.bundleIdentifier { return HostBundle(id: id, bundleless: false) }
        var url = app?.executableURL ?? executableURL(ofPID: pid)
        while let current = url, current.path != "/" {
            if current.pathExtension == "app", let id = Bundle(url: current)?.bundleIdentifier {
                logOnce("enumerate: bundle-less host → \(id) (\(app?.executableURL?.lastPathComponent ?? "?"))", pid: pid)
                return HostBundle(id: id, bundleless: true)
            }
            url = current.deletingLastPathComponent()
        }
        return nil
    }

    private func executableURL(ofPID pid: pid_t) -> URL? {
        var buffer = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        // proc_pidpath returns the byte count it wrote, excluding the
        // terminator — decode exactly that rather than the whole buffer.
        let written = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard written > 0 else { return nil }
        return URL(fileURLWithPath: String(decoding: buffer[..<Int(written)], as: UTF8.self))
    }

    /// Each distinct drop is logged once per process lifetime: the walk runs
    /// on every converge and the same unrecognized group would flood the log.
    private var loggedDrops: Set<String> = []

    private func logDrop(_ reason: String, pid: pid_t?, role: String?) {
        var line = "enumerate: skipped — \(reason)"
        if let role { line += " role=\(role)" }
        logOnce(line, pid: pid)
    }

    private func logOnce(_ message: String, pid: pid_t?) {
        var line = message
        if let pid, pid > 0 {
            let name = NSRunningApplication(processIdentifier: pid)?.localizedName
                ?? executableURL(ofPID: pid)?.lastPathComponent ?? "?"
            line += " pid=\(pid) (\(name))"
        }
        guard loggedDrops.insert(line).inserted else { return }
        PelmetLog.log(line)
    }

    /// An app's status items as its extras bar lists them.
    private struct StatusExtras {
        let naming: StandInNaming
        /// Read only for `.byPosition`: each item's title (the agent tag)
        /// and its frame on the active display's bar.
        let items: [(title: String?, frame: CGRect?)]

        /// The one title every group of this app takes.
        var name: String? {
            guard case .named(let name) = naming else { return nil }
            return name
        }
    }

    /// How the walk names an app's stand-ins, from what its extras bar lists.
    enum StandInNaming: Equatable {
        /// No extras bar to read, or one with no entries: how many icons
        /// the app has is unknown.
        case unread
        /// Every group of the app takes this one title.
        case named(String)
        /// Entries with ids of their own: each group is named by its place
        /// among the app's groups on its bar (`StandInMatch`).
        case byPosition
    }

    /// The app's status items (used in the agent tag). An app node exposes
    /// both its MAIN menu bar (Apple, File, Edit…) and its status-extras
    /// bar; the agent names the extras bar explicitly
    /// (`kAXExtrasMenuBarAttribute`). Not always: Velja and Pure Paste list
    /// the attribute with no value, and their main menu as their only bar
    /// (probed 2026-10-13), so the fallback only takes a bar of status items
    /// (`extrasBarFallback`). The items' frames are where the real buttons
    /// sit on the active display's bar (for Pelmet's own, its NSStatusItem
    /// button windows): never the stand-in group's, so they only order an
    /// app's items.
    private func statusExtras(in appNode: AXUIElement) -> StatusExtras {
        let menuBars = children(of: appNode).filter { role(of: $0) == "AXMenuBar" }
        let explicit = copyAttribute(appNode, kAXExtrasMenuBarAttribute)
            .flatMap { CFGetTypeID($0) == AXUIElementGetTypeID() ? ($0 as! AXUIElement) : nil }
        let extrasBar = Self.extrasBar(explicit: explicit, among: menuBars) { bar in
            (frame(of: bar)?.width, children(of: bar).map { copyAttribute($0, kAXSubroleAttribute) as? String })
        }
        let entries = extrasBar.map { children(of: $0) } ?? []
        let allTitles = entries.map { item -> String? in
            let title = copyAttribute(item, kAXTitleAttribute) as? String
            return title?.isEmpty == false ? title : nil
        }
        let titles = allTitles.compactMap { $0 }
        // SystemUIServer's extras (Siri, Time Machine) hide as one bundle and
        // every group of its carries the same extras bar: name the lot, so
        // the one editor tile can list them ("Siri, TimeMachine", #19). An
        // extra loaded from a .menu bundle (Time Machine) exposes no AX
        // title, description or identifier at all; the bundle list
        // SystemUIServer keeps names those.
        if extrasBar != nil, pid(of: appNode).flatMap(hostBundle(ofPID:))?.id == PelmetBundle.systemUIServerID {
            let untitled = entries.count - titles.count
            let named = titles + (untitled > 0 ? Array(Self.loadedMenuExtraNames().prefix(untitled)) : [])
            return StatusExtras(naming: .named(named.isEmpty ? "Item-0" : named.joined(separator: ", ")), items: [])
        }
        let naming = Self.standInNaming(titles: extrasBar.map { _ in allTitles })
        // Frames are read only to place an app's groups, so a one-icon app
        // walks as cheaply as before.
        guard naming == .byPosition else { return StatusExtras(naming: naming, items: []) }
        return StatusExtras(naming: naming, items: zip(allTitles, entries).map { ($0, frame(of: $1)) })
    }

    /// The bar to read an app's status items from: the one the app names,
    /// else `extrasBarFallback`'s pick among its AXMenuBar children (`shape`
    /// reads a bar's width and its entries' subroles), else none.
    static func extrasBar<Bar>(
        explicit: Bar?, among bars: [Bar], shape: (Bar) -> (width: CGFloat?, subroles: [String?])
    ) -> Bar? {
        explicit ?? extrasBarFallback(among: bars.map(shape)).map { bars[$0] }
    }

    /// Whether the app at `pid` lists a status item in its own extras bar,
    /// nil when its accessibility doesn't answer. A concealed icon leaves
    /// the bar's tree but stays listed here, and an app that switched its
    /// icon off lists none (Snib, probed 2026-10-13).
    public static func listsStatusItem(pid: pid_t) -> Bool? {
        let app = AXUIElementCreateApplication(pid)
        func value(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
            // Per element: a child read through a hung app waits the 6s default.
            AXUIElementSetMessagingTimeout(element, EngineTiming.axAgentTimeout)
            var out: CFTypeRef?
            return AXUIElementCopyAttributeValue(element, name as CFString, &out) == .success ? out : nil
        }
        func children(of element: AXUIElement) -> [AXUIElement] {
            value(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
        }
        guard let nodes = value(app, kAXChildrenAttribute) as? [AXUIElement] else { return nil }
        let bars = nodes.filter { value($0, kAXRoleAttribute) as? String == "AXMenuBar" }
        let explicit = value(app, kAXExtrasMenuBarAttribute)
            .flatMap { CFGetTypeID($0) == AXUIElementGetTypeID() ? ($0 as! AXUIElement) : nil }
        let bar = extrasBar(explicit: explicit, among: bars) { bar in
            var size = CGSize.zero
            let width = value(bar, kAXSizeAttribute).flatMap { AXValueGetValue($0 as! AXValue, .cgSize, &size) ? size.width : nil }
            return (width, children(of: bar).map { value($0, kAXSubroleAttribute) as? String })
        }
        return bar.map { !children(of: $0).isEmpty } ?? false
    }

    /// How an app's stand-ins are named, from its extras bar's entry titles
    /// (nil for an untitled entry), nil when there is no bar to read.
    static func standInNaming(titles: [String?]?) -> StandInNaming {
        // No bar, or an empty one: one name for every group would turn an
        // app with several icons into one phantom `…::Item-0` (Unclutter's
        // bar came and went mid-drag, live test 2026-10-13). The walk names
        // only a lone group.
        guard let titles, let first = titles.first else { return .unread }
        // One id names every group: a one-icon app can list several
        // untitled or same-titled entries, and position would leave its
        // only icon unnamed whenever an external display is active. An
        // untitled entry is an id of its own (Item-0), so [T, untitled]
        // goes by position as T and Item-0, never T twice.
        guard titles.count > 1, Set(titles).count > 1 else { return .named(first ?? "Item-0") }
        // Several ids: never all named after the first (every Pelmet
        // stand-in read as the chevron).
        return .byPosition
    }

    /// The title each of an app's stand-in groups on one bar takes, nil for
    /// a group that stays unnamed. `items` are the extras bar's, read for
    /// `.byPosition`.
    static func standInTitles(
        forGroups groups: [CGRect], naming: StandInNaming, items: [(title: String?, frame: CGRect?)]
    ) -> [String?] {
        switch naming {
        case .named(let name):
            return groups.map { _ in name }
        case .unread:
            // With no extras bar to count by, a lone group is the app's one
            // icon, under the tag the agent keeps for it
            // (`status:com.sindresorhus.Velja::Item-0`, 2026-10-13). Several
            // groups are a guess: unnamed, as before.
            return groups.count == 1 ? ["Item-0"] : groups.map { _ in nil }
        case .byPosition:
            return StandInMatch.items(forGroups: groups, items: items.map(\.frame))
                .map { $0.map { items[$0].title ?? "Item-0" } }
        }
    }

    /// Which of an app's AXMenuBar children (width, each entry's subrole)
    /// is its extras bar when the app names none: the narrowest whose
    /// entries are status items (`AXMenuExtra`, on every hosted app probed
    /// on macOS 27). No width cap: a text item can make the extras bar
    /// wider than a main menu (#17). Never a main menu, whose entries carry
    /// no subrole, even as the only bar: read for Velja's missing extras
    /// bar, its six distinct titles (Apple, Velja, Edit…) passed for six
    /// icons and its stand-ins went unnamed (live test, 2026-10-13).
    static func extrasBarFallback(among bars: [(width: CGFloat?, subroles: [String?])]) -> Int? {
        bars.indices
            .filter { bars[$0].subroles.contains("AXMenuExtra") }
            .min { (bars[$0].width ?? .greatestFiniteMagnitude) < (bars[$1].width ?? .greatestFiniteMagnitude) }
    }

    /// "/System/Library/CoreServices/Menu Extras/TimeMachine.menu" → "TimeMachine".
    private static func loadedMenuExtraNames() -> [String] {
        let paths = UserDefaults(suiteName: PelmetBundle.systemUIServerID)?.array(forKey: "menuExtras") as? [String] ?? []
        return paths.map { ($0 as NSString).lastPathComponent.replacingOccurrences(of: ".menu", with: "") }
    }

    private func pid(of element: AXUIElement) -> pid_t? {
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        return pid > 0 ? pid : nil
    }

    private func children(of element: AXUIElement) -> [AXUIElement] {
        copyAttribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
    }

    private func role(of element: AXUIElement) -> String {
        copyAttribute(element, kAXRoleAttribute) as? String ?? ""
    }

    /// `role(of:)` reports a missing role as "", so the `?? "?"` the log
    /// sites used was dead and they printed `role=` with nothing after it.
    private func roleLabel(_ element: AXUIElement) -> String {
        let role = role(of: element)
        return role.isEmpty ? "?" : role
    }

    private func frame(of element: AXUIElement) -> CGRect? {
        guard let value = copyAttribute(element, "AXFrame"),
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(value as! AXValue, .cgRect, &rect) else { return nil }
        return rect
    }

    private func copyAttribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(element, name as CFString, &value)
        return value
    }
}
