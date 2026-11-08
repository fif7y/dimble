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

/// Names learned from the pills macOS drew, by bundle id. The agent's log
/// carries ids only, and LaunchServices will not serve the placeholder
/// bundles macOS keeps for mirrored iPhone apps — `urlsForApplications` for
/// com.google.GoogleMobile returns none, and the Daemon Container holding
/// its Google.app is off limits (2026-11-07) — so a pill's own AX
/// description is the one place a phone app's name appears on this Mac.
/// Kept so the row for an activity macOS has since taken off the bar still
/// says what it is.
@MainActor
enum LiveActivityNames {
    private static let key = "pelmet.liveActivityNames.v1"
    /// Newest last. A pair is two short strings; the cap is there so a Mac
    /// that sees hundreds over a year doesn't carry them all.
    private static let cap = 32
    private static var pairs: [[String]] = (UserDefaults.standard.array(forKey: key) as? [[String]]) ?? []

    static func name(for bundle: String) -> String? {
        pairs.last { $0.count == 2 && $0[0] == bundle }?[1]
    }

    /// True when this is news, so the caller can say so and redraw.
    @discardableResult
    static func learn(_ bundle: String, as learned: String) -> Bool {
        guard !bundle.isEmpty, !learned.isEmpty, name(for: bundle) != learned else { return false }
        pairs.removeAll { $0.first == bundle }
        pairs.append([bundle, learned])
        if pairs.count > cap { pairs.removeFirst(pairs.count - cap) }
        UserDefaults.standard.set(pairs, forKey: key)
        return true
    }
}

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
    /// The growing wait between reopening the stream, reset by a stream
    /// that stayed up (`StreamRestartBackoff`).
    private var backoff = StreamRestartBackoff()
    /// When the running child opened, for that reset.
    private var streamOpenedAt: Date?
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
    /// from the lines a real start logs, so the item, its menu and its lift
    /// can be tried with nothing running. Several ids, comma separated,
    /// start one each a second apart (oldest first), which is what the menu
    /// needs to show its two slots and the rest under them. They end the way
    /// a real one does: the agent restarting, or their lifetime.
    private static func addDebugActivity(to activities: inout LiveActivities) {
        guard let setting = UserDefaults.standard.string(forKey: "pelmet.debug.fakeLiveActivity") else { return }
        let bundles = setting.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !bundles.isEmpty else { return }
        let agent = agentPID() ?? 0
        for (index, bundle) in bundles.enumerated() {
            // The parser keys on the first eight digits, so they are what has
            // to differ: one id per bundle, not one id for all of them.
            let id = String(format: "DEB0610%X-0000-4000-8000-000000000106", index)
            for line in LiveActivities.startLines(id: id, requester: bundle) {
                activities.read(line, at: Date().addingTimeInterval(Double(index) - Double(bundles.count)), agent: agent)
            }
        }
        PelmetLog.log("liveactivity: debug — fake activities running: \(bundles.joined(separator: ", "))")
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
            streamOpenedAt = Date()
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
        // A child that ran a while ended for a reason of its own (logd
        // restarted, the Mac slept), not because `log stream` is refused
        // here, so its uptime starts the wait over.
        let uptime = streamOpenedAt.map { Date().timeIntervalSince($0) }
        streamOpenedAt = nil
        let delay = backoff.delay(afterUptime: uptime)
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
