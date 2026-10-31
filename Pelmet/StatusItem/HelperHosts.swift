// HelperHosts.swift
// The main-app side of the section helpers (docs/HELPER-PROCESS-PLAN.md).
// One helper bundle per concealable section hosts that section's own items
// so the per-bundle hide assertion covers them like any third-party icon.
// This launches a helper lazily (first item wanted), hands it the full list
// to host, relaunches it if it dies, and routes its events to AppState.
//
// Adoption: the agent defers adopting a registration made while an
// assertion holds, so a helper's fresh items need an adoption window
// (`AgentBarEngine.openAdoptionWindow`) when they arrive mid-session —
// same as a relaunched third-party app. At boot the engine waits for the
// helpers before its first converge (`waitUntilHosted`).

import AppKit
import PelmetCore
import PelmetEngine

@MainActor
final class HelperHosts {
    private struct Host {
        let section: PelmetCore.Section
        let bundleID: String
        let appName: String
        /// Items wanted, keyed by the manager that wants them (separators,
        /// extras) — each manager owns its slice.
        var wanted: [String: [HostedItem]] = [:]
        var ready = false
        var hosted: Set<String> = []
        var running: NSRunningApplication?
        /// Kernel exit watch on `running`'s pid (kqueue NOTE_EXIT). The
        /// NSWorkspace termination notification is kept as a second
        /// source, but it never landed for a helper that died 4.5s into a
        /// reboot login (2026-09-16, pid 1399): nothing relaunched it and
        /// the Hidden separator stayed unhosted until a manual relaunch.
        var exitWatch: DispatchSourceProcess?
        var launching = false
        var relaunches = 0

        var wantedItems: [HostedItem] { wanted.values.flatMap { $0 } }
        var wantsAnything: Bool { !wantedItems.isEmpty }
    }

    private var hosts: [PelmetCore.Section: Host] = [
        .hidden: Host(section: .hidden, bundleID: PelmetBundle.hiddenHostID, appName: "DimbleItems-Hidden"),
        .alwaysHidden: Host(section: .alwaysHidden, bundleID: PelmetBundle.alwaysHiddenHostID, appName: "DimbleItems-AlwaysHidden"),
    ]
    private var listener: MessagePortListener?
    private var terminationObserver: NSObjectProtocol?
    private weak var appState: AppState?

    init(appState: AppState) {
        self.appState = appState
        listener = MessagePortListener(name: PelmetBundle.mainLinkPort) { data in
            guard let event = HelperWire.decode(HelperEvent.self, from: data), event.isValid else {
                PelmetLog.log("helpers: dropped a \(data.count)-byte message that fails the message checks")
                return
            }
            Task { @MainActor in appState.helperHosts?.handle(event) }
        }
        if listener == nil {
            PelmetLog.log("helpers: link port \(PelmetBundle.mainLinkPort) taken — another Pelmet listening?")
        }
        terminationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let bundle = app.bundleIdentifier, PelmetBundle.helperIDs.contains(bundle) else { return }
            Task { @MainActor [weak self] in self?.helperTerminated(bundle: bundle, pid: app.processIdentifier) }
        }
    }

    /// Bundle ids of helpers that host anything right now.
    var activeBundleIDs: Set<String> {
        Set(hosts.values.filter { $0.running != nil && $0.wantsAnything }.map(\.bundleID))
    }

    /// Replace `source`'s slice of `section`'s items. Idempotent: the helper
    /// diffs. An empty total quits the helper.
    func set(_ items: [HostedItem], for section: PelmetCore.Section, source: String) {
        guard var host = hosts[section] else { return }
        let before = host.wantedItems
        host.wanted[source] = items.isEmpty ? nil : items
        hosts[section] = host
        guard before != host.wantedItems else { return }
        push(section)
    }

    private func push(_ section: PelmetCore.Section) {
        guard let host = hosts[section] else { return }
        if !host.wantsAnything {
            if host.running != nil, let data = HelperWire.encode(HelperCommand.quit) {
                PelmetLog.log("helpers: \(host.appName) hosts nothing — quit")
                MessagePortLink.send(data, to: host.bundleID)
            }
            return
        }
        guard host.running != nil else { launch(section); return }
        guard host.ready else { return }
        // The helper drops a sync that fails the message checks (#117) and
        // keeps hosting what it had, so the miss is logged here: os.Logger
        // lines from the helper never reach the log store on macOS 27.
        let command = HelperCommand.sync(host.wantedItems)
        guard command.isValid, let data = HelperWire.encode(command) else {
            PelmetLog.log("helpers: \(host.appName) ← sync \(host.wantedItems.count) item(s) not sent, it fails the message checks")
            return
        }
        PelmetLog.log("helpers: \(host.appName) ← sync \(host.wantedItems.count) item(s)")
        if !MessagePortLink.send(data, to: host.bundleID) {
            PelmetLog.log("helpers: \(host.appName) not answering — relaunch")
            hosts[section]?.ready = false
            track(nil, for: section)
            launch(section)
        }
    }

    private func launch(_ section: PelmetCore.Section) {
        guard var host = hosts[section], !host.launching else { return }
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/\(host.appName).app")
        guard FileManager.default.fileExists(atPath: url.path) else {
            PelmetLog.log("helpers: \(host.appName) missing at \(url.path)")
            return
        }
        host.launching = true
        host.ready = false
        host.hosted = []
        hosts[section] = host
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        config.environment = ["PELMET_PARENT_PID": "\(ProcessInfo.processInfo.processIdentifier)"]
        NSWorkspace.shared.openApplication(at: url, configuration: config) { app, error in
            Task { @MainActor [weak self] in
                guard let self, var host = self.hosts[section] else { return }
                host.launching = false
                if let error {
                    PelmetLog.log("helpers: \(host.appName) launch failed — \(error.localizedDescription)")
                } else {
                    PelmetLog.log("helpers: \(host.appName) launched pid=\(app?.processIdentifier ?? 0)")
                    self.hosts[section] = host
                    self.track(app, for: section)
                    host = self.hosts[section] ?? host
                    // Launch Services hands back a running instance of the
                    // same bundle: after a quit-and-relaunch the previous
                    // Pelmet's helper is still winding down and would never
                    // say ready to this one. Kill it; its termination
                    // relaunches a fresh helper through `helperTerminated`.
                    if let app, let born = app.launchDate,
                       let ours = NSRunningApplication.current.launchDate, born < ours {
                        PelmetLog.log("helpers: \(host.appName) pid=\(app.processIdentifier) predates this Pelmet — replacing")
                        app.forceTerminate()
                    }
                }
                self.hosts[section] = host
            }
        }
    }

    /// Track the helper process behind `app`: remember it and arm the exit
    /// watch on its pid. A pid that is already gone reports its death now.
    private func track(_ app: NSRunningApplication?, for section: PelmetCore.Section) {
        guard var host = hosts[section] else { return }
        host.exitWatch?.cancel()
        host.exitWatch = nil
        host.running = app
        hosts[section] = host
        guard let app, app.processIdentifier > 0 else { return }
        let pid = app.processIdentifier
        let bundle = host.bundleID
        guard kill(pid, 0) == 0 else {
            helperTerminated(bundle: bundle, pid: pid)
            return
        }
        let watch = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        watch.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in self?.helperTerminated(bundle: bundle, pid: pid) }
        }
        watch.resume()
        hosts[section]?.exitWatch = watch
    }

    private func helperTerminated(bundle: String, pid: pid_t) {
        guard let section = hosts.first(where: { $0.value.bundleID == bundle })?.key,
              var host = hosts[section] else { return }
        // The exit watch and the NSWorkspace notification both report a
        // death; whichever comes second finds the pid already untracked.
        guard host.running?.processIdentifier == pid else { return }
        PelmetLog.log("helpers: \(host.appName) pid=\(pid) terminated")
        host.exitWatch?.cancel()
        host.exitWatch = nil
        host.running = nil
        host.ready = false
        host.hosted = []
        hosts[section] = host
        guard host.wantsAnything else { return }
        host.relaunches += 1
        hosts[section] = host
        guard host.relaunches <= 3 else {
            PelmetLog.log("helpers: \(host.appName) died \(host.relaunches) times — giving up this session")
            return
        }
        PelmetLog.log("helpers: \(host.appName) died — relaunching")
        launch(section)
    }

    private func handle(_ event: HelperEvent) {
        switch event {
        case .ready(let bundle):
            guard let section = hosts.first(where: { $0.value.bundleID == bundle })?.key else { return }
            PelmetLog.log("helpers: \(hosts[section]?.appName ?? bundle) ready")
            hosts[section]?.ready = true
            if hosts[section]?.running == nil {
                track(NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first, for: section)
            }
            push(section)
        case .hosted(let bundle, let title):
            guard let section = hosts.first(where: { $0.value.bundleID == bundle })?.key else { return }
            hosts[section]?.hosted.insert(title)
            PelmetLog.log("helpers: \(hosts[section]?.appName ?? bundle) hosts \(title)")
            appState?.helperHosted(title: title, bundle: bundle)
        case .clicked(_, let title, let rightButton, let x, let y):
            appState?.helperItemClicked(title: title, rightButton: rightButton, at: NSPoint(x: x, y: y))
        case .draggedOff(_, let title):
            appState?.helperItemDraggedOff(title: title)
        }
    }

    /// Live ids (helper bundle, Pelmet title) of every item the helpers have
    /// registered so far — the boot adoption wait expects their in-band
    /// frames. Wanted-but-unregistered items are left out: a missing helper
    /// already burned its own deadline in `waitUntilHosted`.
    var hostedLiveIDs: [ItemID] {
        hosts.values.flatMap { host in
            host.hosted.map { ItemID.status(bundle: host.bundleID, title: $0) }
        }
    }

    /// Boot: give the helpers a moment to register their items before the
    /// first converge asserts over them.
    func waitUntilHosted(deadline: TimeInterval = 3) async {
        let until = Date.now.addingTimeInterval(deadline)
        while Date.now < until {
            let pending = hosts.values.filter { host in
                host.wantsAnything && !Set(host.wantedItems.map(\.title)).isSubset(of: host.hosted)
            }
            if pending.isEmpty { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
        PelmetLog.log("helpers: not every item hosted within \(Int(deadline))s — continuing")
    }
}
