// LiveActivityLogParser.swift
// Live Activities as MenuBarAgent narrates them (#106). Any hide assertion
// takes every Live Activity pill off the bar, ~20ms after the acquire, and
// one that starts while it is held never shows; no allowlist key exempts
// them. What an activity shows sits behind Apple-only entitlements, but the
// agent's `liveActivities` log category names the app that asked for it and
// the activity's id, in the clear, when one starts and when it ends (macOS
// 27.2, read 2026-10-27 off an activity mirrored from the iPhone):
//
//   start  "Received live activity descriptor states: [… ActivityDescriptor(
//          id: "<UUID>", …, requester: <bundle id>, …" — os_log cuts it at
//          1 KB, before the activity's state, so the start and end copies
//          read the same — then "Create client element for Live Activity:
//          <the UUID's first 8 hex digits>"
//   end    the descriptor line again, "Not showing remote live activity
//          from <bundle id>: … state=dismissed", then "Keeping departed live
//          activity alive: <UUID>" and "Releasing kept-alive live activity:
//          <UUID>", all in the same millisecond
//
// The client element is created under the assertion too (only its scenes
// aren't), so a start is seen whether or not the pill could show. Pure
// string work so the shape of a real line can be pinned in a test.

import Foundation

/// One Live Activity MenuBarAgent is keeping, as far as its log tells.
public struct LiveActivity: Equatable, Sendable, Codable {
    /// The id's first eight hex digits, uppercased: all the start line
    /// carries of it.
    public let id: String
    /// The app that asked for it (an iPhone app's id for one mirrored from
    /// the phone, rarely installed on the Mac). Nil until a descriptor line
    /// names it: a second activity can fall past the line's 1 KB cut.
    public var bundleID: String?
    /// The process the activity's widget lives in (`containingProcess`),
    /// which for a service's activity is the app itself: the Shortcuts run
    /// indicator asks as com.apple.WorkflowKit.ShortcutsViewService, which
    /// no Mac has, and names com.apple.shortcuts here, which every Mac has.
    public var hostBundleID: String?
    /// When the start line was logged.
    public let startedAt: Date
    /// The MenuBarAgent process that announced it.
    public let agent: Int32
    /// Known from before the stream last opened: a replay or the last launch
    /// vouches for it, and it can be over without anything having said so.
    public var fromBefore = false

    public init(id: String, bundleID: String?, hostBundleID: String? = nil, startedAt: Date, agent: Int32) {
        self.id = id
        self.bundleID = bundleID
        self.hostBundleID = hostBundleID
        self.startedAt = startedAt
        self.agent = agent
    }
}

/// The Live Activities running now, folded from the agent's lines.
public struct LiveActivities: Equatable, Sendable {
    /// Oldest first.
    public private(set) var active: [LiveActivity] = []
    /// Requesters the descriptor lines named, by short id, kept for the
    /// start line a millisecond behind them.
    private var requesters: [String: String] = [:]
    /// Their `containingProcess`, the same way.
    private var hosts: [String: String] = [:]
    /// When each activity last ended, by short id. The replay can't be
    /// trusted to know: macOS quarantines a process that logs too much
    /// ("QUARANTINED DUE TO HIGH LOGGING VOLUME", MenuBarAgent 2026-11-05
    /// 16:28:24), and after that `log show` had none of its lines while
    /// `log stream` delivered them all, so an activity that ended at 17:20
    /// replayed as running. This is what the stream saw, kept across launches
    /// (`Saved`).
    public private(set) var ended: [String: Date] = [:]

    public init() {}

    /// What a launch hands the next one.
    public struct Saved: Codable, Equatable, Sendable {
        public var active: [LiveActivity] = []
        public var ended: [String: Date] = [:]
        public init() {}
    }

    public var saved: Saved {
        var saved = Saved()
        saved.active = active
        saved.ended = ended
        return saved
    }

    /// Folds what the last launch knew into a fresh replay of the log: a
    /// start the log lost still counts, and so does an end it lost. A start
    /// after the last end is a new run of the id. All of it is `fromBefore`.
    public mutating func merge(_ saved: Saved) {
        ended.merge(saved.ended) { max($0, $1) }
        for activity in saved.active {
            if let index = active.firstIndex(where: { $0.id == activity.id }) {
                if activity.startedAt > active[index].startedAt { active[index] = activity }
            } else {
                active.append(activity)
            }
        }
        active.removeAll { activity in ended[activity.id].map { $0 >= activity.startedAt } ?? false }
        active.sort { $0.startedAt < $1.startedAt }
        for index in active.indices { active[index].fromBefore = true }
    }

    /// The assertion was down and no pill came: what only the past vouched
    /// for isn't running. Not recorded as ended, so the next launch asks
    /// again if this was wrong. True when `active` changed.
    @discardableResult
    public mutating func dropFromBefore() -> Bool {
        let before = active
        active.removeAll(where: \.fromBefore)
        return active != before
    }

    /// Which activity each pill on the bar belongs to, as far as the names
    /// allow. A pill whose name is one an activity already has is claimed by
    /// it; when exactly one pill and one activity are left over, they can
    /// only be each other, so the pill's name is that activity's. Anything
    /// less certain is left alone — a wrong name here would be kept and
    /// shown for weeks. `pills` are AX descriptions left to right, `onBar`
    /// the activities macOS is drawing with the name this Mac can give them
    /// (nil when it has no app of that id).
    public static func pairNames(pills: [String],
                                 onBar: [(bundle: String, known: String?)]) -> [(bundle: String, name: String)] {
        var unclaimed = pills
        for activity in onBar {
            guard let known = activity.known else { continue }
            if let index = unclaimed.firstIndex(where: { Self.sameName($0, known) }) { unclaimed.remove(at: index) }
        }
        let unnamed = onBar.filter { $0.known == nil }
        guard unclaimed.count == 1, unnamed.count == 1 else { return [] }
        return [(unnamed[0].bundle, unclaimed[0])]
    }

    /// A pill's description against an app's name: macOS writes "Sports" for
    /// the Sports app, and a service's pill takes its app's name, so one
    /// being the start of the other counts.
    static func sameName(_ pill: String, _ app: String) -> Bool {
        let pill = pill.lowercased(), app = app.lowercased()
        return pill == app || pill.hasPrefix(app) || app.hasPrefix(pill)
    }

    /// The longest an activity can run: the system ends one at eight hours
    /// and takes it off the Dynamic Island at once (ActivityKit's rule).
    /// Only an end line the log never delivered leaves one here that long.
    public static let lifetime: TimeInterval = 8 * 60 * 60

    /// The activity the item shows: the latest to start.
    public var latest: LiveActivity? { active.last }

    /// How many pills macOS draws at once. Two, whatever the room: with four
    /// activities running it drew two 116pt pills into a 541pt free span and
    /// evicted the rest (measured 2026-11-07, macOS 27.3), so "Menu bar full"
    /// in its log means both slots are taken, not that the bar ran out of
    /// width. Apple's own camera and mic pill sits in the same pool and
    /// outranks every activity.
    public static let slots = 2

    /// What the bar can show and what it can't, newest first: the newest
    /// activity wins a slot and the oldest is the one evicted (every
    /// "Menu bar full: evicting liveActivity(…) for better-ranked …" line
    /// named the oldest). `avPill` is Apple's camera and mic pill, running
    /// or not; it takes a slot before any activity does.
    public func slotted(avPill: Bool) -> (onBar: [LiveActivity], hidden: [LiveActivity]) {
        let newestFirst = Array(active.reversed())
        let room = max(0, Self.slots - (avPill ? 1 : 0))
        return (Array(newestFirst.prefix(room)), Array(newestFirst.dropFirst(room)))
    }

    /// When the oldest one runs out of `lifetime`; nil while none runs.
    public var nextExpiry: Date? {
        active.map { $0.startedAt.addingTimeInterval(Self.lifetime) }.min()
    }

    /// Folds one `liveActivities` message in. `agent` is the logging
    /// MenuBarAgent's pid: a line from another one means it restarted, and
    /// the new one announces again what still runs. True when `active`
    /// changed.
    @discardableResult
    public mutating func read(_ message: String, at date: Date, agent: Int32) -> Bool {
        let before = active
        if active.contains(where: { $0.agent != agent }) {
            active.removeAll { $0.agent != agent }
        }
        if message.hasPrefix(Self.descriptorPrefix) {
            for (id, bundle, host) in Self.requesters(in: message) {
                requesters[id] = bundle
                hosts[id] = host
                if let index = active.firstIndex(where: { $0.id == id }) {
                    if active[index].bundleID == nil { active[index].bundleID = bundle }
                    if active[index].hostBundleID == nil { active[index].hostBundleID = host }
                }
            }
            // Only the ids still in play are worth keeping.
            if requesters.count > 32 {
                let live = Set(active.map(\.id))
                requesters = requesters.filter { live.contains($0.key) }
                hosts = hosts.filter { live.contains($0.key) }
            }
        } else if let id = Self.id(after: Self.createdPrefix, in: message) {
            if let index = active.firstIndex(where: { $0.id == id }) {
                active[index].fromBefore = false  // the agent just announced it
            } else {
                active.append(LiveActivity(id: id, bundleID: requesters[id], hostBundleID: hosts[id],
                                           startedAt: date, agent: agent))
            }
        } else if let id = Self.id(after: Self.departedPrefix, in: message)
                    ?? Self.id(after: Self.releasedPrefix, in: message) {
            active.removeAll { $0.id == id }
            requesters[id] = nil
            hosts[id] = nil
            ended[id] = date
        } else if message.hasPrefix(Self.notShownPrefix) {
            // A dismissal is followed by the per-id lines above; any other
            // state is the agent refusing the app's activities outright
            // (remote ones off, the app denied from the pill's menu).
            let rest = message.dropFirst(Self.notShownPrefix.count)
            let bundle = String(rest.prefix { $0 != ":" })
            let state = rest.range(of: "state=").map { String(rest[$0.upperBound...].prefix { $0 != "," && !$0.isWhitespace }) }
            if state != "dismissed", state != "ended" {
                for activity in active where activity.bundleID == bundle { ended[activity.id] = date }
                active.removeAll { $0.bundleID == bundle }
            }
        }
        return active != before
    }

    /// Lets go of what the log can no longer vouch for: an activity past
    /// `lifetime`, and one a MenuBarAgent that is gone announced (it died
    /// before its end lines; `agent`: the running one's pid, nil unknown).
    /// True when `active` changed.
    @discardableResult
    public mutating func prune(now: Date, agent: Int32?) -> Bool {
        let before = active
        active.removeAll { activity in
            now.timeIntervalSince(activity.startedAt) >= Self.lifetime || agent.map { $0 != activity.agent } ?? false
        }
        ended = ended.filter { now.timeIntervalSince($0.value) < Self.lifetime }
        return active != before
    }

    /// The two lines a start logs, cut to what `read` takes from them: for
    /// the app's debug activity (`pelmet.debug.fakeLiveActivity`), read
    /// like a real one, so the item and its lift can be tried with nothing
    /// running.
    public static func startLines(id: String, requester bundle: String) -> [String] {
        [#"\#(descriptorPrefix) [ActivityDescriptor(id: "\#(id)", requester: \#(bundle))]"#,
         createdPrefix + id.prefix(8)]
    }

    // MARK: Lines

    static let descriptorPrefix = "Received live activity descriptor states:"
    static let createdPrefix = "Create client element for Live Activity: "
    static let departedPrefix = "Keeping departed live activity alive: "
    static let releasedPrefix = "Releasing kept-alive live activity: "
    static let notShownPrefix = "Not showing remote live activity from "

    /// The lines worth reading, for a `log` predicate: the agent's own, and
    /// none of the scene chatter (eight lines per scene, again on every
    /// assertion cycle).
    public static let predicate =
        #"process == "MenuBarAgent" AND subsystem == "com.apple.menubar" AND category == "liveActivities" AND (eventMessage BEGINSWITH "Received live activity descriptor states" OR eventMessage BEGINSWITH "Create client element for Live Activity" OR eventMessage BEGINSWITH "Keeping departed live activity" OR eventMessage BEGINSWITH "Releasing kept-alive live activity" OR eventMessage BEGINSWITH "Not showing remote live activity")"#

    /// The short id after `prefix`: the start line's eight digits as they
    /// are, the end lines' UUID cut to them.
    static func id(after prefix: String, in message: String) -> String? {
        guard message.hasPrefix(prefix) else { return nil }
        let id = message.dropFirst(prefix.count).prefix { $0.isHexDigit }
        return id.count >= 8 ? id.prefix(8).uppercased() : nil
    }

    /// Every `ActivityDescriptor(id: "…"` with the `requester:` and the
    /// `containingProcess:` that follow it inside the same descriptor; one
    /// cut off before its requester names none.
    static func requesters(in message: String) -> [(id: String, bundle: String, host: String?)] {
        let marker = "ActivityDescriptor(id: \""
        var found: [(id: String, bundle: String, host: String?)] = []
        var rest = Substring(message)
        while let start = rest.range(of: marker) {
            let afterID = rest[start.upperBound...]
            let id = afterID.prefix { $0.isHexDigit }
            let next = afterID.range(of: marker)?.lowerBound ?? afterID.endIndex
            let descriptor = afterID[..<next]
            if id.count >= 8, let requester = descriptor.range(of: "requester: ") {
                let bundle = descriptor[requester.upperBound...].prefix { $0 != "," && $0 != ")" && !$0.isWhitespace }
                let host = descriptor.range(of: "containingProcess: ").map {
                    String(descriptor[$0.upperBound...].prefix { $0 != "," && $0 != ")" && !$0.isWhitespace })
                }
                if !bundle.isEmpty { found.append((id.prefix(8).uppercased(), String(bundle), host?.isEmpty == false ? host : nil)) }
            }
            rest = afterID[next...]
        }
        return found
    }
}

/// Telling same-named pills apart.
///
/// A pill's identity in AX is its description ("Sports", "myVW") and nothing
/// else. Two activities of one app share it, so a lookup by description alone
/// always lands on the leftmost of them: clicking the right-hand Sports pill
/// opened the left one's card (fif7y/dimble, 2026-11-08). The keys add " #2",
/// " #3" in bar order, which is what the menu bar's mirrors already carry.
public enum PillKeys {
    /// One key per name, in the order given (bar order, leftmost first).
    public static func keys(for names: [String]) -> [String] {
        var counts: [String: Int] = [:]
        return names.map { name in
            counts[name, default: 0] += 1
            return counts[name]! == 1 ? name : "\(name) #\(counts[name]!)"
        }
    }

    /// Where `wanted` sits in `names`. A key ("Sports #2") wins; a bare
    /// description ("Sports") falls back to the first pill of that name, so a
    /// caller holding only what AX reports — an open card's owner — still
    /// finds its pill. nil when nothing matches.
    public static func index(of wanted: String, in names: [String]) -> Int? {
        if let exact = keys(for: names).firstIndex(of: wanted) { return exact }
        return names.firstIndex(of: wanted)
    }
}
