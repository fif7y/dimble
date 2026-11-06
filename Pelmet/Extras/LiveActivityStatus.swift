// LiveActivityStatus.swift
// Which Live Activities are running, for live mode (the "Show Live Activities"
// setting) and Dimble's Live Activities item (#106). One watcher serves both,
// alive while either is on (`ExtrasManager.sync`). MenuBarAgent takes their pills off the bar under any hide
// assertion, and what an activity shows is for Apple's own processes only
// (the session and chrono services check private entitlements). The agent
// does narrate each one's start and end to the unified log, naming the app
// (`LiveActivities`), so one `log stream` child follows those lines the way
// FocusStatus follows donotdisturbd, and `log show` replays the last eight
// hours at boot: no activity runs longer. The replay can miss lines the stream
// delivered, so what the stream saw is saved and folded into it
// (`LiveActivities.Saved`). What's left over from before this launch is checked
// against the bar (`noPillFound`).

import AppKit
import PelmetCore
import PelmetEngine

@MainActor
final class LiveActivityStatus {
    private(set) var activities = LiveActivities() {
        didSet {
            if activities.saved != oldValue.saved { Self.save(activities.saved) }
            guard activities.active != oldValue.active else { return }
            onChange?()
            scheduleExpiry()
        }
    }
    /// Oldest first.
    var active: [LiveActivity] { activities.active }
    /// Fires on the main actor whenever `active` changes.
    var onChange: (() -> Void)?

    private var stream: Process?
    private var stopped = false
    /// Live lines that land while the replay is still reading the log: they
    /// are newer than it, so they fold in on top of it.
    private var recovering = false
    private var pending: [Entry] = []
    private var restarts = 0
    /// When the stream last ended, until a new one is running: a restart
    /// replays the log only from then (`recover(since:)`).
    private var gapStart: Date?
    /// Pelmet quitting takes the child with it (see FocusStatus); the
    /// observer goes with `stop()`.
    private var termination: NSObjectProtocol?
    /// Wakes for the oldest activity's lifetime, or sooner to check the
    /// agent that announced them is still the one running.
    private var expiry: Task<Void, Never>?

    /// One ndjson line: the message, when it was logged, and by which
    /// MenuBarAgent.
    struct Entry: Sendable {
        let message: String
        let date: Date
        let agent: Int32
    }

    func start() {
        stopped = false
        gapStart = nil
        reapOrphans()
        if termination == nil {
            termination = NotificationCenter.default.addObserver(
                forName: NSApplication.willTerminateNotification, object: nil, queue: .main
            ) { [weak self] _ in MainActor.assumeIsolated { self?.stop() } }
        }
        recover(since: nil)
        openStream()
    }

    func stop() {
        stopped = true
        pending = []
        expiry?.cancel()
        (stream?.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        stream?.terminate()
        stream = nil
        if let termination { NotificationCenter.default.removeObserver(termination) }
        termination = nil
    }

    /// Any `log stream` on our predicate re-parented to launchd is ours.
    private func reapOrphans() {
        Task.detached(priority: .utility) {
            let pids = FocusStatus.run(["/usr/bin/pgrep", "-P", "1", "-f", "Create client element for Live Activity"])
                .compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
            for pid in pids { kill(pid, SIGTERM) }
            if !pids.isEmpty { PelmetLog.log("liveactivity: reaped \(pids.count) orphaned log stream(s)") }
        }
    }

    // MARK: Boot

    /// Replays the last eight hours, then lets go of what the running agent
    /// can't still be showing: one past its lifetime, one a MenuBarAgent
    /// that has since gone announced (the Mac restarted, the agent died
    /// before its end lines). This Mac's log kept these lines ~21 hours
    /// (2026-10-27), so eight is always on record; reading them took 2.1s.
    /// With `since` (a stream that ended and is being reopened) only the
    /// lines from then are read, folded into what is known: an end line the
    /// gap swallowed is all the replay is for. It runs at background QoS:
    /// the eight hours measured 2.7s, 0.7s of CPU and 379 MB at peak
    /// (2026-10-28).
    private func recover(since: Date?) {
        recovering = true
        let window = since.map { "\(min(8 * 60 * 60, Int(Date().timeIntervalSince($0)) + 5))s" } ?? "8h"
        Task.detached(priority: .background) { [weak self] in
            let entries = FocusStatus.run(["show", "--last", window, "--style", "ndjson", "--predicate", Self.predicate],
                                          qualityOfService: .background)
                .compactMap(Self.entry(in:))
            await MainActor.run { [weak self] in
                guard let self, !self.stopped else { return }
                var replayed = since == nil ? LiveActivities() : self.activities
                for entry in entries { replayed.read(entry.message, at: entry.date, agent: entry.agent) }
                // A stream gap can have swallowed an end the store lost too.
                replayed.merge(since == nil ? Self.loadSaved() : LiveActivities.Saved())
                let dropped = replayed.prune(now: Date(), agent: Self.agentPID())
                for entry in self.pending { replayed.read(entry.message, at: entry.date, agent: entry.agent) }
                self.pending = []
                self.recovering = false
                if since == nil {
                    Self.addDebugActivity(to: &replayed)
                    PelmetLog.log("liveactivity: boot \(Self.describe(replayed))\(dropped ? " (ended ones the log never closed dropped)" : "")\(entries.isEmpty ? ", nothing on record" : "")")
                } else {
                    PelmetLog.log("liveactivity: replayed the last \(window) after the stream ended — \(Self.describe(replayed))\(dropped ? " (ended ones the log never closed dropped)" : "")")
                }
                self.activities = replayed
            }
        }
    }

    /// Live mode or the item's lift had the assertion down and no pill came.
    func noPillFound() {
        var next = activities
        guard next.dropFromBefore() else { return }
        PelmetLog.log("liveactivity: no pill for what came from before this launch — \(Self.describe(next))")
        activities = next
    }

    private static let savedKey = "pelmet.liveActivities.v1"
    /// The debug activities are for the launch that asked for them.
    private static var savesState: Bool {
        debugHost == nil && (UserDefaults.standard.string(forKey: "pelmet.debug.fakeLiveActivity") ?? "").isEmpty
    }

    private static func save(_ saved: LiveActivities.Saved) {
        guard savesState, let data = try? JSONEncoder().encode(saved) else { return }
        UserDefaults.standard.set(data, forKey: savedKey)
    }

    private static func loadSaved() -> LiveActivities.Saved {
        guard savesState, let data = UserDefaults.standard.data(forKey: savedKey),
              let saved = try? JSONDecoder().decode(LiveActivities.Saved.self, from: data)
        else { return LiveActivities.Saved() }
        return saved
    }

    /// Debug: `open -a Dimble --args -pelmet.debug.fakeLiveActivity <bundle id>`
    /// starts one activity of that app at boot, read through the parser
    /// from the lines a real start logs, so the item and its lift can be
    /// tried with nothing running. It ends the way a real one does: the
    /// agent restarting, or its lifetime.
    private static func addDebugActivity(to activities: inout LiveActivities) {
        guard let bundle = UserDefaults.standard.string(forKey: "pelmet.debug.fakeLiveActivity"), !bundle.isEmpty else { return }
        let agent = agentPID() ?? 0
        for line in LiveActivities.startLines(id: "DEB06106-0000-4000-8000-000000000106", requester: bundle) {
            activities.read(line, at: Date(), agent: agent)
        }
        PelmetLog.log("liveactivity: debug — a fake activity of \(bundle) running")
    }

    /// The running MenuBarAgent's pid; nil when it isn't up.
    nonisolated private static func agentPID() -> Int32? {
        if debugHost != nil { return nil }  // the harness's activities were announced by another process
        return NSRunningApplication.runningApplications(withBundleIdentifier: PelmetBundle.agentID).first?.processIdentifier
    }

    /// Debug: `defaults write app.fif7y.Pelmet pelmet.debug.pillHost local.pillharness`
    /// makes the PillHarness test app a second source of pills: its start
    /// and end lines (MenuBarAgent's wording, logged by process
    /// "PillHarness") count as activities, and live mode reads its pills.
    nonisolated static var debugHost: String? {
        UserDefaults.standard.string(forKey: "pelmet.debug.pillHost").flatMap { $0.isEmpty ? nil : $0 }
    }

    /// With `pelmet.debug.pillHostOnly` the harness is the only source: the
    /// real agent's activities and pills are left out, so a test has exactly
    /// the pills it starts.
    nonisolated static var debugHostOnly: Bool {
        debugHost != nil && UserDefaults.standard.bool(forKey: "pelmet.debug.pillHostOnly")
    }

    nonisolated private static var predicate: String {
        guard debugHost != nil else { return LiveActivities.predicate }
        return LiveActivities.predicate.replacingOccurrences(
            of: #"process == "MenuBarAgent""#,
            with: debugHostOnly ? #"process == "PillHarness""# : #"(process == "MenuBarAgent" OR process == "PillHarness")"#)
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
        let lines = FocusStatus.LineSplitter()
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { handle.readabilityHandler = nil; return }
            for text in lines.split(appending: chunk) {
                guard let entry = Self.entry(in: text) else { continue }
                Task { @MainActor [weak self] in
                    guard let self, !self.stopped else { return }
                    guard !self.recovering else { self.pending.append(entry); return }
                    var next = self.activities
                    guard next.read(entry.message, at: entry.date, agent: entry.agent) else {
                        self.activities = next  // a requester noted for the start line behind it
                        return
                    }
                    PelmetLog.log("liveactivity: \(Self.describe(next))")
                    self.activities = next
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
            gapStart = nil
        } catch {
            // Retried like a stream that ended.
            PelmetLog.log("liveactivity: log stream failed — \(error.localizedDescription)")
            streamEnded("could not start (\(error.localizedDescription))")
        }
    }

    /// logd restarts (or a kill) end the child; back off like FocusStatus.
    /// The replay on the way back reads only the gap, to catch an end it
    /// swallowed.
    private func streamEnded(_ why: String) {
        stream = nil
        guard !stopped else { return }
        // A standard account: `log stream` is refused, and will be every
        // time. Said once, not retried (the activities stay as the boot
        // replay left them).
        if why.contains("Must be admin") {
            PelmetLog.log("liveactivity: log stream refused (\(why.prefix(120))) — not trying again")
            return
        }
        // Where the replay on the way back starts: the first end of a run
        // of failures, until a stream is running again.
        if gapStart == nil { gapStart = Date() }
        restarts += 1
        let delay = min(60, 2 << min(restarts, 5))
        PelmetLog.log("liveactivity: log stream ended\(why.isEmpty ? "" : " (\(why.prefix(120)))"), retry in \(delay)s")
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !self.stopped, self.stream == nil else { return }
            self.recover(since: self.gapStart)
            self.openStream()
        }
    }

    // MARK: Expiry

    /// An end line the log never delivered would keep an activity forever:
    /// it goes at its lifetime, or as soon as the agent that announced it
    /// is gone. Checked every ten minutes while any runs.
    private func scheduleExpiry() {
        expiry?.cancel()
        guard let due = activities.nextExpiry else { return }
        let wake = min(due, Date().addingTimeInterval(600))
        expiry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(1, wake.timeIntervalSinceNow)))
            // A replay landing after this one only overwrites what it pruned.
            guard let self, !Task.isCancelled, !self.stopped else { return }
            var next = self.activities
            if next.prune(now: Date(), agent: Self.agentPID()) {
                PelmetLog.log("liveactivity: no end line came — \(Self.describe(next))")
                self.activities = next
            } else {
                self.scheduleExpiry()
            }
        }
    }

    // MARK: Plumbing

    nonisolated private static func describe(_ activities: LiveActivities) -> String {
        guard !activities.active.isEmpty else { return "none running" }
        return "\(activities.active.count) running — " + activities.active
            .map { "\($0.id) \($0.bundleID ?? "app unnamed")" }
            .joined(separator: ", ")
    }

    /// The message, time and agent pid of one ndjson line; nil for the
    /// header line the stream prints first, the trailing count `log show`
    /// appends, and another logged-in user's agent (one runs per user).
    nonisolated private static func entry(in line: String) -> Entry? {
        guard line.hasPrefix("{"),
              let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              (object["userID"] as? Int).map({ $0 == Int(getuid()) }) ?? true,
              let message = object["eventMessage"] as? String,
              let pid = object["processID"] as? Int
        else { return nil }
        // `log`'s ndjson timestamps: "2026-10-27 08:16:19.694652-0400".
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSSSSZ"
        let date = (object["timestamp"] as? String).flatMap(formatter.date(from:)) ?? Date()
        return Entry(message: message, date: date, agent: Int32(pid))
    }
}
