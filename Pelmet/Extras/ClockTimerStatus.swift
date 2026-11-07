// ClockTimerStatus.swift
// The Clock app's timer, for the Timer item. Apple's own timer item is a
// Control Center extra the assertion hides whatever its section, and it
// comes late (4.6 s after a start) and goes late (9-10 s after a cancel,
// 2026-10-29). mobiletimerd narrates every change to the unified log in the
// clear (ClockTimers), so one `log stream` child follows it the way
// SharePlayStatus follows Control Center, and `log show` replays the last
// day at boot (a Clock timer runs 24 h at most).

import AppKit
import PelmetCore
import PelmetEngine

@MainActor
final class ClockTimerStatus {
    private(set) var timers = ClockTimers() {
        didSet {
            if timers.current != oldValue.current { onChange?() }
            if timers != oldValue { scheduleExpiry() }
        }
    }
    var current: ClockTimers.Phase? { timers.current }
    /// Fires on the main actor whenever `current` changes.
    var onChange: (() -> Void)?

    private var stream: Process?
    private var stopped = false
    /// Live lines that land while a replay is still reading the log: they
    /// are newer than it, so they fold in on top of it, not under it.
    private var recovering = false
    private var pending: [(message: String, date: Date)] = []
    /// The growing wait between reopening the stream, reset by a stream
    /// that stayed up (`StreamRestartBackoff`).
    private var backoff = StreamRestartBackoff()
    /// When the running child opened, for that reset.
    private var streamOpenedAt: Date?
    /// Pelmet quitting takes the child with it (see FocusStatus).
    private var termination: NSObjectProtocol?
    /// Wakes when a timer is past its bound (`ClockTimers.expire`).
    private var expiry: Task<Void, Never>?

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
        expiry?.cancel()
        (stream?.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        stream?.terminate()
        stream = nil
    }

    /// Any `log stream` on our predicate re-parented to launchd is ours.
    private func reapOrphans() {
        Task.detached(priority: .utility) {
            let pids = FocusStatus.run(["/usr/bin/pgrep", "-P", "1", "-f", #"process == "mobiletimerd""#])
                .compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
            for pid in pids { kill(pid, SIGTERM) }
            if !pids.isEmpty { PelmetLog.log("clocktimer: reaped \(pids.count) orphaned log stream(s)") }
        }
    }

    // MARK: Boot

    private func recover() {
        recovering = true
        Task.detached(priority: .utility) { [weak self] in
            let lines = FocusStatus.run(["show", "--last", "24h", "--style", "ndjson", "--predicate", ClockTimers.predicate])
            var replayed = ClockTimers()
            for entry in lines.compactMap(Self.entry(in:)) { replayed.read(entry.message, at: entry.date) }
            await MainActor.run { [weak self] in
                guard let self, !self.stopped else { return }
                PelmetLog.log("clocktimer: boot \(Self.describe(replayed.current))")
                for entry in self.pending { replayed.read(entry.message, at: entry.date) }
                self.pending = []
                self.recovering = false
                replayed.expire(now: Date())
                self.timers = replayed
            }
        }
    }

    // MARK: Live

    private func openStream() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        process.arguments = ["stream", "--style", "ndjson", "--predicate", ClockTimers.predicate]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        let lines = FocusStatus.LineSplitter()
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { handle.readabilityHandler = nil; return }
            for text in lines.split(appending: chunk) {
                guard let entry = Self.entry(in: text) else { continue }
                Task { @MainActor [weak self] in
                    guard let self, !self.stopped else { return }
                    guard !self.recovering else { self.pending.append(entry); return }
                    var next = self.timers
                    guard next.read(entry.message, at: entry.date) else { return }
                    if next.current != self.timers.current { PelmetLog.log("clocktimer: \(Self.describe(next.current))") }
                    self.timers = next
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
            PelmetLog.log("clocktimer: log stream failed — \(error.localizedDescription)")
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
        PelmetLog.log("clocktimer: log stream ended, retry in \(delay)s")
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !self.stopped, self.stream == nil else { return }
            self.recover()
            self.openStream()
        }
    }

    private func scheduleExpiry() {
        expiry?.cancel()
        guard let due = timers.nextExpiry else { return }
        expiry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(1, due.timeIntervalSinceNow)))
            guard let self, !Task.isCancelled, !self.stopped else { return }
            var next = self.timers
            guard next.expire(now: Date()) else { return self.scheduleExpiry() }
            PelmetLog.log("clocktimer: no line came for one past its end — \(Self.describe(next.current))")
            self.timers = next
        }
    }

    // MARK: Plumbing

    nonisolated private static func describe(_ phase: ClockTimers.Phase?) -> String {
        switch phase {
        case .running(let ends)?: "a timer runs, \(Int(ends.timeIntervalSinceNow.rounded()))s left"
        case .paused(let left)?: "a timer is paused, \(Int(left.rounded()))s left"
        case .rang?: "a timer rang"
        case nil: "no timer"
        }
    }

    /// The message and time of one ndjson line; nil for the header line the
    /// stream prints first and the trailing count `log show` appends.
    nonisolated private static func entry(in line: String) -> (message: String, date: Date)? {
        guard line.hasPrefix("{"),
              let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              (object["userID"] as? Int).map({ $0 == Int(getuid()) }) ?? true,  // mobiletimerd runs per user
              let message = object["eventMessage"] as? String,
              let stamp = object["timestamp"] as? String
        else { return nil }
        // `log`'s ndjson timestamps: "2026-10-29 10:29:03.436123-0400".
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSSSSZ"
        return formatter.date(from: stamp).map { (message, $0) }
    }
}
