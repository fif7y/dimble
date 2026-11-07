// FocusStatus.swift
// Which Focus is on, for Pelmet's own Focus item. Apple's indicator is a
// Control Center extra the assertion hides with the Live Activities (#29),
// and donotdisturbd keeps its state for entitled clients only — but it
// narrates every transition to the unified log with the mode's name and
// symbol in the clear (probed 2026-09-16). One `log stream` child follows
// those lines; `log show` reads the last one at boot. Nothing else worked:
// no distributed notification fires, the database needs Full Disk Access,
// and a Shortcut can only answer through a permission prompt.

import AppKit
import ApplicationServices
import PelmetCore
import PelmetEngine

@MainActor
final class FocusStatus {
    /// The active mode, nil while none is on.
    private(set) var active: FocusMode? {
        didSet { if active != oldValue { onChange?() } }
    }
    /// Fires on the main actor whenever `active` changes.
    var onChange: (() -> Void)?

    private var stream: Process?
    private var stopped = false
    /// Transitions the stream has applied; the boot read yields to them.
    private var streamed = 0
    /// The growing wait between reopening the stream, reset by a stream
    /// that stayed up (`StreamRestartBackoff`).
    private var backoff = StreamRestartBackoff()
    /// When the running child opened, for that reset.
    private var streamOpenedAt: Date?
    /// Pelmet quitting takes the child with it — a `Process` outlives its
    /// parent, and a `log stream` left behind at every relaunch was found
    /// re-parented to launchd (2026-09-16).
    private var termination: NSObjectProtocol?

    /// donotdisturbd's one line per transition; the state it carries is
    /// what `FocusLogParser` reads. Its assertion snapshots ride along: a
    /// Focus that ends while the Mac sleeps (a location one run from the
    /// iPhone) comes back at wake as an empty snapshot and no state line (#70).
    nonisolated private static let predicate =
        #"process == "donotdisturbd" AND ((category == "ServiceProvider" AND eventMessage BEGINSWITH "Did receive state update") OR (category == "StateProvider" AND eventMessage BEGINSWITH "Calculate DND state for snapshot"))"#

    func start() {
        stopped = false
        reapOrphans()
        if termination == nil {
            termination = NotificationCenter.default.addObserver(
                forName: NSApplication.willTerminateNotification, object: nil, queue: .main
            ) { [weak self] _ in MainActor.assumeIsolated { self?.stop() } }
        }
        recover()
        openStream()
    }

    func stop() {
        stopped = true
        (stream?.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        stream?.terminate()
        stream = nil
    }

    /// A crash (or a quit before the observer existed) can still strand a
    /// child; any `log stream` running our predicate under launchd is ours.
    private func reapOrphans() {
        Task.detached(priority: .utility) {
            let pids = Self.run(["/usr/bin/pgrep", "-P", "1", "-f", "Did receive state update"])
                .compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
            for pid in pids { kill(pid, SIGTERM) }
            if !pids.isEmpty { PelmetLog.log("focus: reaped \(pids.count) orphaned log stream(s)") }
        }
    }

    // MARK: Boot

    /// The last transition on record. An hour covers a mode switched
    /// moments before a relaunch; a day catches the ones that outlive it
    /// (a Sleep schedule, a Do Not Disturb left on). Nothing in a day
    /// reads as off — Focus is off far more often than not — unless a
    /// snapshot in it still holds an assertion: a Focus on for days (the
    /// reboot in #70 logged snapshots only) is named a week back.
    private func recover() {
        let seen = streamed
        Task.detached(priority: .utility) { [weak self] in
            var found: String?
            var held = false
            for window in ["1h", "24h", "7d"] where found == nil {
                if window == "7d", !held { break }
                let messages = Self.run(["show", "--last", window, "--style", "ndjson", "--predicate", Self.predicate])
                    .compactMap(Self.message(in:))
                found = messages.last(where: Self.isDecisive)
                held = messages.contains { $0.hasPrefix(FocusLogParser.snapshotPrefix) }
            }
            let mode = found.flatMap(FocusLogParser.activeMode(in:))
            await MainActor.run { [weak self] in
                guard let self, !self.stopped else { return }
                // A transition the stream caught while `log show` ran is newer.
                guard self.streamed == seen else { return }
                PelmetLog.log("focus: boot \(mode.map { "\($0.name) (\($0.symbol))" } ?? "off")\(found == nil ? ", no transition on record" : "")")
                self.active = mode
            }
        }
    }

    // MARK: Live

    private func openStream() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        process.arguments = ["stream", "--style", "ndjson", "--predicate", Self.predicate]
        let pipe = Pipe()
        process.standardOutput = pipe
        let errors = Pipe()
        process.standardError = errors
        let lines = LineSplitter()
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { handle.readabilityHandler = nil; return }
            for text in lines.split(appending: chunk) {
                guard let message = Self.message(in: text), Self.isDecisive(message) else { continue }
                let mode = FocusLogParser.activeMode(in: message)
                Task { @MainActor [weak self] in
                    guard let self, !self.stopped else { return }
                    if mode != self.active {
                        PelmetLog.log("focus: \(mode.map { "on — \($0.name) (\($0.symbol))" } ?? "off")")
                    }
                    self.streamed += 1
                    self.active = mode
                }
            }
        }
        process.terminationHandler = { [weak self] _ in
            // Why `log` quit, when it says (it has a "Must be admin" refusal).
            let why = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .split(separator: "\n").first.map(String.init) ?? ""
            Task { @MainActor [weak self] in self?.streamEnded(why) }
        }
        do {
            try process.run()
            stream = process
            streamOpenedAt = Date()
        } catch {
            PelmetLog.log("focus: log stream failed — \(error.localizedDescription)")
        }
    }

    /// logd restarts (or a kill) end the child; come back with a backoff so
    /// a machine where `log stream` is refused doesn't spin.
    private func streamEnded(_ why: String) {
        stream = nil
        guard !stopped else { return }
        // A child that ran a while ended for a reason of its own (logd
        // restarted, the Mac slept), not because `log stream` is refused
        // here, so its uptime starts the wait over.
        let uptime = streamOpenedAt.map { Date().timeIntervalSince($0) }
        streamOpenedAt = nil
        let delay = backoff.delay(afterUptime: uptime)
        PelmetLog.log("focus: log stream ended\(why.isEmpty ? "" : " (\(why.prefix(120)))"), retry in \(delay)s")
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !self.stopped, self.stream == nil else { return }
            self.recover()
            self.openStream()
        }
    }

    // MARK: Plumbing

    /// A state update, or a snapshot that says no Focus is on. A snapshot
    /// still naming an assertion leaves the mode to the state update beside it.
    nonisolated private static func isDecisive(_ message: String) -> Bool {
        !message.hasPrefix(FocusLogParser.snapshotPrefix) || FocusLogParser.snapshotSaysOff(message)
    }

    /// The `eventMessage` of one ndjson line; nil for the header line the
    /// stream prints first, the trailing count `log show` appends, and
    /// another logged-in user's lines (donotdisturbd runs once per user).
    nonisolated private static func message(in line: String) -> String? {
        guard line.hasPrefix("{"),
              let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              (object["userID"] as? Int).map({ $0 == Int(getuid()) }) ?? true
        else { return nil }
        return object["eventMessage"] as? String
    }

    /// Reassembles the pipe's chunks into lines. The readability handler
    /// runs serially on the handle's own queue, hence the unchecked mark.
    /// SharePlayStatus reads its stream through this too.
    nonisolated final class LineSplitter: @unchecked Sendable {
        private var pending = Data()

        func split(appending chunk: Data) -> [String] {
            pending.append(chunk)
            var lines: [String] = []
            while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
                if let line = String(data: pending[pending.startIndex..<newline], encoding: .utf8) {
                    lines.append(line)
                }
                pending.removeSubrange(pending.startIndex...newline)
            }
            return lines
        }
    }

    /// `qualityOfService`: how the child is scheduled (a long replay of the
    /// log runs at `.background`); unset it inherits the caller's.
    nonisolated static func run(_ arguments: [String], qualityOfService: QualityOfService? = nil) -> [String] {
        let process = Process()
        if let qualityOfService { process.qualityOfService = qualityOfService }
        if let tool = arguments.first, tool.hasPrefix("/") {
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = Array(arguments.dropFirst())
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
            process.arguments = arguments
        }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            PelmetLog.log("log: \(arguments.first ?? "") failed — \(error.localizedDescription)")
            return []
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)?.components(separatedBy: "\n") ?? []
    }
}

// MARK: - Control Center's Focus module

/// What a click on Apple's Focus item does: open Control Center on its
/// Focus panel — every mode, the durations, Focus Settings — and close it
/// on the next click. Two accessibility actions get there (2026-09-16):
/// press the Control Center item MenuBarAgent hosts, then the Focus tile's
/// own "show details" custom action (a plain press on the tile would toggle
/// Do Not Disturb). A real click on Pelmet's item also dismisses any panel
/// Control Center has up, the way a click anywhere outside it does, and the
/// panel's tree is torn down before the click reaches us — so the panel is
/// never read at click time: `moduleOpen` remembers what Pelmet put up
/// (a watcher clears it when the panel goes away), and an open waits for
/// the dismissal to finish before pressing the item, which is a toggle.
/// A panel that comes up without the Focus tile stays up for the user; no
/// panel at all opens Focus settings, so a click never does nothing (#70).
@MainActor
enum ControlCenterFocus {
    private static var moduleOpen = false
    private static var watcher: Task<Void, Never>?

    static func toggle() {
        if moduleOpen {
            // The click already closed it; a press now would reopen it.
            moduleOpen = false
            watcher?.cancel()
            return
        }
        Task {
            let opened = await Task.detached(priority: .userInitiated) { await open() }.value
            guard opened else { return }
            moduleOpen = true
            watch()
        }
    }

    /// Clears `moduleOpen` once the panel is gone (the user clicked away
    /// or picked a mode); a few AX calls a second, only while it is up.
    private static func watch() {
        watcher?.cancel()
        watcher = Task {
            for _ in 0..<300 {
                try? await Task.sleep(for: .milliseconds(200))
                if Task.isCancelled { return }
                let up = await Task.detached { !panels().isEmpty }.value
                if !up { break }
            }
            moduleOpen = false
        }
    }

    nonisolated private static func open() async -> Bool {
        // A panel the click dismissed is still coming down.
        for _ in 0..<16 where !panels().isEmpty {
            try? await Task.sleep(for: .milliseconds(25))
        }
        guard let agent = NSRunningApplication.runningApplications(withBundleIdentifier: PelmetBundle.agentID).first,
              let item = find(in: AXUIElementCreateApplication(agent.processIdentifier), depth: 8, where: {
                  attribute($0, kAXIdentifierAttribute) == "com.apple.menuextra.controlcenter"
              })
        else {
            PelmetLog.log("focus: Control Center item not found, opening Focus settings")
            await openSettings()
            return false
        }
        AXUIElementPerformAction(item, kAXPressAction as CFString)
        // The panel takes a few frames to build; the tile appears with it.
        for _ in 0..<80 {
            try? await Task.sleep(for: .milliseconds(20))
            if panels().contains(where: showFocusModule(in:)) { return true }
        }
        let windows = panels()
        guard !windows.isEmpty else {
            PelmetLog.log("focus: Control Center panel never opened, opening Focus settings")
            await openSettings()
            return false
        }
        let tiles = windows.flatMap { modules(in: $0, depth: 8) }
        PelmetLog.log("focus: Control Center panel has no Focus tile (\(windows.count) window(s), modules: \(tiles.joined(separator: ", ")))")
        return true
    }

    @MainActor static func openSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Focus-Settings.extension")!)
    }

    /// The Focus tile's "show details" custom action, the one that swaps
    /// the panel to the Focus module. Its name is localized ("Details
    /// einblenden"), so it's taken as the tile's one custom action. False
    /// when the tile isn't there.
    nonisolated private static func showFocusModule(in panel: AXUIElement) -> Bool {
        guard let tile = find(in: panel, depth: 8, where: { attribute($0, kAXIdentifierAttribute) == "module-FocusModes" }),
              let box = find(in: tile, depth: 2, where: { attribute($0, kAXRoleAttribute) == kAXCheckBoxRole })
        else { return false }
        var names: CFArray?
        AXUIElementCopyActionNames(box, &names)
        guard let details = ((names as? [String]) ?? []).first(where: { $0.hasPrefix("Name:") })
        else { PelmetLog.log("focus: Focus tile has no details action"); return true }
        AXUIElementPerformAction(box, details as CFString)
        return true
    }

    /// Control Center's windows, empty while none is up. Searched whole, in
    /// case the panel isn't the first.
    nonisolated private static func panels() -> [AXUIElement] {
        guard let controlCenter = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.controlcenter").first
        else { return [] }
        var value: AnyObject?
        AXUIElementCopyAttributeValue(AXUIElementCreateApplication(controlCenter.processIdentifier), kAXWindowsAttribute as CFString, &value)
        return (value as? [AXUIElement]) ?? []
    }

    /// The panel's `module-…` tiles, named in the log when Focus isn't one.
    nonisolated private static func modules(in element: AXUIElement, depth: Int) -> [String] {
        let own = attribute(element, kAXIdentifierAttribute).flatMap { $0.hasPrefix("module-") ? [String($0.dropFirst(7))] : nil } ?? []
        guard depth > 0 else { return own }
        var children: AnyObject?
        axCopyAttribute(element, kAXChildrenAttribute as CFString, &children)
        return own + ((children as? [AXUIElement]) ?? []).flatMap { modules(in: $0, depth: depth - 1) }
    }

    nonisolated private static func attribute(_ element: AXUIElement, _ name: String) -> String? {
        var value: AnyObject?
        axCopyAttribute(element, name as CFString, &value)
        return value as? String
    }

    nonisolated private static func find(in element: AXUIElement, depth: Int, where matches: (AXUIElement) -> Bool) -> AXUIElement? {
        if matches(element) { return element }
        guard depth > 0 else { return nil }
        var children: AnyObject?
        axCopyAttribute(element, kAXChildrenAttribute as CFString, &children)
        for child in (children as? [AXUIElement]) ?? [] {
            if let hit = find(in: child, depth: depth - 1, where: matches) { return hit }
        }
        return nil
    }
}
