// TimeMachineBackup.swift
// Time Machine's state for Pelmet's own Time Machine item: whether a backup
// runs (`tmutil status`, polled slowly while idle and every couple of
// seconds during a backup), the latest backup and its disk (the
// com.apple.TimeMachine domain, which cfprefsd serves without Full Disk
// Access — the plist itself is off limits), and the same verbs Apple's menu
// offers. `tmutil latestbackup` is never used: it mounts the destination,
// which hangs for half a minute on an unreachable Time Capsule.

import AppKit
import PelmetEngine

@MainActor
final class TimeMachineBackup {
    struct Status: Equatable {
        var running = false
        /// 0…1 while `tmutil` reports one; nil while preparing.
        var percent: Double?
        var stopping = false
        /// `BackupPhase` as `tmutil` names it ("Copying", "Finishing", …).
        var phase: String?
        /// The last attempt failed (Apple's "!" mark): see `Destination.failed`.
        var failed = false
    }

    struct Destination {
        /// Apple's wording: the server for a network disk ("Time Capsule.local"),
        /// the volume name otherwise.
        let name: String
        let latestBackup: Date?
        /// The latest attempt ended in an error (`RESULT` ≠ 0) without a
        /// snapshot, within the last day. Apple's own mark reads a fresh
        /// failure the same way and ignores years-old ones (Gab's 2023
        /// attempts, RESULT 22, drew nothing).
        let failed: Bool
    }

    private(set) var status = Status()
    /// Fires on the main actor whenever `status` changes.
    var onChange: (() -> Void)?

    private var timer: Timer?
    private var refreshing = false
    /// For the log (#168): when the running backup was first seen, and the
    /// latest backup's date, so one that came and went between two checks
    /// still leaves a line.
    private var runningSince: Date?
    private var lastSeenRunning: Date?
    private var latestBackup: Date?

    func start() {
        PelmetLog.log("timemachine: watching backups, every 30 s while idle")
        refresh()
        schedule()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func schedule() {
        timer?.invalidate()
        let interval: TimeInterval = status.running ? 2 : 30
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        timer?.tolerance = interval / 4
    }

    /// Re-reads `tmutil status` off the main thread.
    func refresh() {
        guard !refreshing else { return }
        refreshing = true
        Task.detached(priority: .utility) { [weak self] in
            var parsed = Self.parseStatus(Self.run("/usr/bin/tmutil", ["status"]))
            let destination = Self.destination()
            parsed?.failed = destination?.failed ?? false
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.refreshing = false
                self.noteLatest(destination?.latestBackup, running: parsed?.running ?? false)
                guard let parsed, parsed != self.status else { return }
                let wasRunning = self.status.running
                self.status = parsed
                if wasRunning != parsed.running {
                    self.logEdge(parsed)
                    self.schedule()
                }
                self.onChange?()
            }
        }
    }

    private func logEdge(_ parsed: Status) {
        if parsed.running {
            runningSince = Date()
            PelmetLog.log("timemachine: backup running (\(parsed.phase ?? "preparing"))")
        } else {
            let seconds = runningSince.map { Int(-$0.timeIntervalSinceNow) }
            runningSince = nil
            PelmetLog.log("timemachine: backup ended\(seconds.map { " after about \($0) s" } ?? "")")
        }
    }

    /// A backup shorter than the idle poll is never seen running: its only
    /// trace is a newer latest backup. One seen running in the last two
    /// minutes is the one that wrote it; a failed or stopped one long before isn't.
    /// The date only counts going forward: with two disks it can step back.
    private func noteLatest(_ latest: Date?, running: Bool) {
        if running { lastSeenRunning = Date() }
        guard let latest else { return }
        defer { latestBackup = max(latest, latestBackup ?? latest) }
        guard let before = latestBackup, latest > before else { return }
        if lastSeenRunning.map({ -$0.timeIntervalSinceNow > 120 }) ?? true {
            PelmetLog.log("timemachine: a backup finished between two checks, never seen running")
        }
    }

    // MARK: Verbs

    func backUpNow() {
        PelmetLog.log("time machine: back up now")
        Task.detached(priority: .utility) { [weak self] in
            _ = Self.run("/usr/bin/tmutil", ["startbackup"])
            try? await Task.sleep(for: .seconds(1))
            await self?.refresh()
        }
    }

    func skipBackup() {
        PelmetLog.log("time machine: skip this backup")
        Task.detached(priority: .utility) { [weak self] in
            _ = Self.run("/usr/bin/tmutil", ["stopbackup"])
            try? await Task.sleep(for: .seconds(1))
            await self?.refresh()
        }
    }

    static func browseBackups() {
        let url = URL(fileURLWithPath: "/System/Applications/Time Machine.app")
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            if let error { PelmetLog.log("time machine: browse failed — \(error.localizedDescription)") }
        }
    }

    static func openSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Time-Machine-Settings.extension")!)
    }

    // MARK: Latest backup

    /// The last-used destination, read fresh on every poll and menu open.
    nonisolated static func destination() -> Destination? {
        let domain = "com.apple.TimeMachine" as CFString
        func value(_ key: String) -> Any? {
            CFPreferencesCopyValue(key as CFString, domain, kCFPreferencesAnyUser, kCFPreferencesCurrentHost)
        }
        guard let destinations = value("Destinations") as? [[String: Any]], !destinations.isEmpty else { return nil }
        let lastID = value("LastDestinationID") as? String
        let record = destinations.first { $0["DestinationID"] as? String == lastID }
            ?? destinations.max { latest(in: $0) ?? .distantPast < latest(in: $1) ?? .distantPast }
        guard let record else { return nil }
        let volume = record["LastKnownVolumeName"] as? String
        let server = (record["NetworkURL"] as? String).flatMap(serverName(fromNetworkURL:))
        let latestBackup = latest(in: record)
        let lastAttempt = (record["AttemptDates"] as? [Date])?.max()
        let result = (record["RESULT"] as? NSNumber)?.intValue ?? 0
        let failed = result != 0
            && lastAttempt.map { $0 > (latestBackup ?? .distantPast) && Date().timeIntervalSince($0) < 86_400 } == true
        return Destination(name: server ?? volume ?? "", latestBackup: latestBackup, failed: failed)
    }

    nonisolated private static func latest(in record: [String: Any]) -> Date? {
        (record["SnapshotDates"] as? [Date])?.max()
    }

    /// "afp://Gab;AUTH=SRP@Time%20Capsule._afpovertcp._tcp.local./Data" →
    /// "Time Capsule.local", the way Apple's menu names a network disk.
    nonisolated private static func serverName(fromNetworkURL string: String) -> String? {
        guard let host = URL(string: string)?.host?.removingPercentEncoding, !host.isEmpty else { return nil }
        var name = host
        for service in ["._afpovertcp._tcp", "._smb._tcp"] {
            name = name.replacingOccurrences(of: service, with: "")
        }
        if name.hasSuffix(".") { name.removeLast() }
        return name
    }

    // MARK: tmutil

    /// `tmutil status` prints a header line, then an old-style plist.
    nonisolated static func parseStatus(_ output: String?) -> Status? {
        guard let output, let brace = output.firstIndex(of: "{"),
              let data = output[brace...].data(using: .utf8),
              let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        func number(_ key: String) -> Double? {
            if let n = dict[key] as? NSNumber { return n.doubleValue }
            return (dict[key] as? String).flatMap(Double.init)
        }
        var status = Status()
        status.running = (number("Running") ?? 0) != 0
        status.stopping = (number("Stopping") ?? 0) != 0
        status.phase = dict["BackupPhase"] as? String
        if let percent = number("Percent"), percent >= 0 {
            status.percent = min(max(percent, 0), 1)
        }
        return status
    }

    nonisolated private static func run(_ path: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            PelmetLog.log("time machine: \(arguments.joined(separator: " ")) failed — \(error.localizedDescription)")
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }
}
