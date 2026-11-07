// SharePlayStatus.swift
// Whether a SharePlay session with no call is live, for the Camera & mic
// item's SharePlay face. Apple shows it as the camera pill wearing the
// SharePlay glyph, which the assertion hides (her Mac, 2026-09-25: it only
// stayed with Pelmet quit), and no camera or mic is on for the hardware
// monitor to see. Nothing public tells a third-party process: CallKit's
// observer is unavailable on macOS and GroupActivities' GroupStateObserver
// stayed false through a joined call without the group-session entitlement.
// Control Center narrates the controller behind the icon to the unified log
// in the clear, so one `log stream` child follows it the way FocusStatus
// follows donotdisturbd, and `log show` replays the recent lines at boot.

import AppKit
import PelmetCore
import PelmetEngine

@MainActor
final class SharePlayStatus {
    private(set) var state = SharePlayState() {
        didSet {
            if state.isLive != oldValue.isLive { onChange?() }
            watchControlCenter()
        }
    }
    var isLive: Bool { state.isLive }
    /// Fires on the main actor whenever `isLive` changes.
    var onChange: (() -> Void)?

    private var stream: Process?
    private var stopped = false
    /// Live lines that land while a replay is still reading the log: they
    /// are newer than it, so they fold in on top of it, not under it.
    private var recovering = false
    private var pending: [String] = []
    /// The growing wait between reopening the stream, reset by a stream
    /// that stayed up (`StreamRestartBackoff`).
    private var backoff = StreamRestartBackoff()
    /// When the running child opened, for that reset.
    private var streamOpenedAt: Date?
    /// Pelmet quitting takes the child with it (see FocusStatus).
    private var termination: NSObjectProtocol?
    /// When the last controller line was logged, and what checks it against
    /// the running Control Center while a session is on.
    private var lastController: Date?
    private var controlCenterWatch: Task<Void, Never>?

    /// The controller's activation and AV-mode lines; the rest of the
    /// category (members, devices, activities) is noise here.
    nonisolated private static let predicate =
        #"process == "ControlCenter" AND category == "faceTime" AND (eventMessage BEGINSWITH "[Controller] is " OR eventMessage BEGINSWITH "[Session] Updating state for avMode" OR eventMessage BEGINSWITH "[Controller] User requested to continue AVLess")"#

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
        pending = []
        controlCenterWatch?.cancel()
        controlCenterWatch = nil
        (stream?.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        stream?.terminate()
        stream = nil
    }

    /// Any `log stream` on our predicate re-parented to launchd is ours.
    private func reapOrphans() {
        Task.detached(priority: .utility) {
            let pids = FocusStatus.run(["/usr/bin/pgrep", "-P", "1", "-f", #"category == "faceTime""#])
                .compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
            for pid in pids { kill(pid, SIGTERM) }
            if !pids.isEmpty { PelmetLog.log("shareplay: reaped \(pids.count) orphaned log stream(s)") }
        }
    }

    // MARK: Boot

    /// Replays the last hour into a fresh state, a day when the hour holds
    /// no controller line: the activation is logged once, and a two-hour
    /// movie's last hour can be only session lines. A session Control Center
    /// never saw end — it relaunched, the Mac restarted — reads as over:
    /// its last controller line predates the running Control Center.
    private func recover() {
        recovering = true
        Task.detached(priority: .utility) { [weak self] in
            var entries: [(message: String, date: Date?)] = []
            for window in ["1h", "24h"] where !entries.contains(where: { $0.message.hasPrefix("[Controller] ") }) {
                let lines = FocusStatus.run(["show", "--last", window, "--style", "ndjson", "--predicate", Self.predicate])
                entries = lines.compactMap(Self.entry(in:))
            }
            var replayed = SharePlayState()
            for entry in entries { replayed.read(entry.message) }
            let started = Self.controlCenterStart()
            let lastController = entries.last { $0.message.hasPrefix("[Controller] ") }?.date
            var stale = false
            if replayed.controllerActive, let started { stale = (lastController ?? .distantPast) < started }
            if stale { replayed = SharePlayState() }
            await MainActor.run { [weak self] in
                guard let self, !self.stopped else { return }
                PelmetLog.log("shareplay: boot \(Self.describe(replayed))\(stale ? " (stale session dropped)" : "")\(entries.isEmpty ? ", nothing on record" : "")")
                for message in self.pending { replayed.read(message) }
                self.pending = []
                self.recovering = false
                self.lastController = [lastController, self.lastController].compactMap { $0 }.max()
                self.state = replayed
            }
        }
    }

    /// The boot's rule, while a session is on: Control Center restarting
    /// mid-session never logs its end, and a real session logs again.
    private func watchControlCenter() {
        guard state.controllerActive else {
            controlCenterWatch?.cancel()
            controlCenterWatch = nil
            return
        }
        guard controlCenterWatch == nil else { return }
        controlCenterWatch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard let self, !Task.isCancelled, !self.stopped else { return }
                guard !self.recovering, let started = Self.controlCenterStart(),
                      (self.lastController ?? .distantPast) < started else { continue }
                PelmetLog.log("shareplay: Control Center restarted, its session is over")
                self.state = SharePlayState()
                return
            }
        }
    }

    /// When the running Control Center started. launchd starts it, so
    /// `NSRunningApplication.launchDate` is nil; the kernel knows.
    nonisolated private static func controlCenterStart() -> Date? {
        guard let pid = NSRunningApplication.runningApplications(withBundleIdentifier: AudioVideoPill.controlCenterID)
            .first?.processIdentifier else { return nil }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec) + TimeInterval(info.pbi_start_tvusec) / 1_000_000)
    }

    // MARK: Live

    private func openStream() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        process.arguments = ["stream", "--style", "ndjson", "--predicate", Self.predicate]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        let lines = FocusStatus.LineSplitter()
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { handle.readabilityHandler = nil; return }
            for text in lines.split(appending: chunk) {
                guard let entry = Self.entry(in: text) else { continue }
                let message = entry.message
                Task { @MainActor [weak self] in
                    guard let self, !self.stopped else { return }
                    if message.hasPrefix("[Controller] ") { self.lastController = entry.date ?? Date() }
                    guard !self.recovering else { self.pending.append(message); return }
                    var next = self.state
                    guard next.read(message), next != self.state else { return }
                    if next.isLive != self.state.isLive || next.controllerActive != self.state.controllerActive || next.avMode != self.state.avMode {
                        PelmetLog.log("shareplay: \(Self.describe(next))")
                    }
                    self.state = next
                }
            }
        }
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor [weak self] in self?.streamEnded() }
        }
        do {
            try process.run()
            stream = process
            streamOpenedAt = Date()
        } catch {
            PelmetLog.log("shareplay: log stream failed — \(error.localizedDescription)")
        }
    }

    /// logd restarts (or a kill) end the child; back off like FocusStatus.
    private func streamEnded() {
        stream = nil
        guard !stopped else { return }
        // A child that ran a while ended for a reason of its own (logd
        // restarted, the Mac slept), not because `log stream` is refused
        // here, so its uptime starts the wait over.
        let uptime = streamOpenedAt.map { Date().timeIntervalSince($0) }
        streamOpenedAt = nil
        let delay = backoff.delay(afterUptime: uptime)
        PelmetLog.log("shareplay: log stream ended, retry in \(delay)s")
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !self.stopped, self.stream == nil else { return }
            self.recover()
            self.openStream()
        }
    }

    // MARK: Plumbing

    nonisolated private static func describe(_ state: SharePlayState) -> String {
        guard state.controllerActive else { return "off" }
        let mode = switch state.avMode {
        case 0: "AV-less"
        case 1: "audio"
        case 2: "video"
        case let other?: "avMode \(other)"
        case nil: "avMode ?"
        }
        return "\(state.isLive ? "live" : "in a call") — \(mode)"
    }

    /// The message and time of one ndjson line; nil for the header line the
    /// stream prints first and the trailing count `log show` appends.
    nonisolated private static func entry(in line: String) -> (message: String, date: Date?)? {
        guard line.hasPrefix("{"),
              let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              (object["userID"] as? Int).map({ $0 == Int(getuid()) }) ?? true,  // Control Center runs per user
              let message = object["eventMessage"] as? String
        else { return nil }
        // `log`'s ndjson timestamps: "2026-09-25 21:49:17.086123-0400".
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSSSSZ"
        return (message, (object["timestamp"] as? String).flatMap(formatter.date(from:)))
    }
}
