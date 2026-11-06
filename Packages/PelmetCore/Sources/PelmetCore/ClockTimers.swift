// ClockTimers.swift
// The Clock app's timers as mobiletimerd narrates them. Their state sits
// behind the private `com.apple.private.mobiletimerd` entitlement (probed
// 2026-09-15), but the daemon logs every change in the clear at the default
// level (macOS 27.2, read 2026-10-29 off a start, pause, resume, ring,
// dismiss and cancel):
//
//   start   "<MTTimerDurationManager: 0x...> didAddTimers (
//              "<MTMutableTimer:0x... TimerID: <UUID>, Title: , state:Running,
//              duration:120, firedDate: (null), dismissedDate: (null), ...>")"
//   change  "... didUpdateTimers fromTimers: ( <before> ) toTimers: ( <now> )"
//
// States are Running, Paused and Stopped. A cancel stops with no firedDate,
// a ring stops with one and no dismissedDate, a dismiss sets dismissedDate.
// Not always: a ring answered from its banner 23 min later (08:55) never
// got its dismissedDate, so the banner's answer counts too (usernoted logs
// "Remove record from response action: <NotificationRecord
// app:"com.apple.clock" ... req:"<TimerID>"", every dismissal that day),
// and a new start ends any ring.
// No end is logged in a fixed format (the trigger lines print a localized
// date), so it's kept from the lines' own times: a start ends `duration`
// later, a pause keeps what was left, a resume ends that much later. Off a
// 2 min run with a pause, that came within 40 ms of the Clock's own ring.
// Pure string work so the shape of a real line can be pinned in a test.

import Foundation

/// The Clock app's timers, as far as mobiletimerd's log tells.
public struct ClockTimers: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case running(ends: Date)
        case paused(left: TimeInterval)
        /// Rang; waits for a dismiss (in the Clock app or its banner).
        case rang
    }

    /// Each followed timer by its id. One whose start wasn't read (it began
    /// before the replayed window) isn't followed: its end is unknown.
    public private(set) var timers: [String: Phase] = [:]
    /// When each ringing timer rang.
    private var rangAt: [String: Date] = [:]
    /// Given up on past their end. At wake from sleep the bound can pass just
    /// before the line that says it rang, and that line still counts.
    private var gaveUp: Set<String> = []

    public init() {}

    /// How long past its end a running timer waits for the line that says it
    /// rang. Without this bound a lost line held the item at 0:00, and being
    /// the earliest end it put the next real timer at 0:00 too.
    static let overdue: TimeInterval = 60
    /// How long a ring waits for its answer. A dismissal that left no line
    /// held the item with no ring left to answer. The longest wait on record
    /// is 23 min (2026-10-29), and Clock's own banner stays up regardless.
    static let ringLimit: TimeInterval = 60 * 60

    private func expiry(of id: String, _ phase: Phase) -> Date? {
        switch phase {
        case .running(let ends): ends.addingTimeInterval(Self.overdue)
        case .rang: rangAt[id]?.addingTimeInterval(Self.ringLimit)
        case .paused: nil
        }
    }

    /// When the next timer is due to be given up on.
    public var nextExpiry: Date? {
        timers.compactMap { expiry(of: $0.key, $0.value) }.min()
    }

    /// Gives up on what's past its bound. True when a timer went.
    @discardableResult
    public mutating func expire(now: Date) -> Bool {
        let before = timers
        timers = timers.filter { id, phase in expiry(of: id, phase).map { $0 > now } ?? true }
        rangAt = rangAt.filter { timers[$0.key] == .rang }
        for (id, phase) in before where timers[id] == nil {
            if case .running = phase { gaveUp.insert(id) }
        }
        return timers != before
    }

    /// The one the bar shows: a ringing timer, else the one ending first,
    /// else the paused one with the least left.
    public var current: Phase? {
        let phases = timers.values
        if phases.contains(.rang) { return .rang }
        let ends = phases.compactMap { phase -> Date? in
            if case .running(let ends) = phase { ends } else { nil }
        }
        if let first = ends.min() { return .running(ends: first) }
        let lefts = phases.compactMap { phase -> TimeInterval? in
            if case .paused(let left) = phase { left } else { nil }
        }
        return lefts.min().map { .paused(left: $0) }
    }

    /// Folds one mobiletimerd message in. True when a timer changed.
    @discardableResult
    public mutating func read(_ message: String, at date: Date) -> Bool {
        let before = timers
        if let added = message.range(of: Self.added) {
            let started = Self.timers(in: message[added.upperBound...]).filter { $0.state == "Running" }
            if !started.isEmpty { timers = timers.filter { $0.value != .rang } }
            for timer in started {
                timers[timer.id] = .running(ends: date.addingTimeInterval(timer.duration))
            }
        } else if message.hasPrefix(Self.answered), message.contains(Self.clockApp),
                  let req = message.range(of: #"req:""#) {
            let id = String(message[req.upperBound...].prefix(36))
            if timers[id] == .rang { timers[id] = nil }
        } else if message.contains(Self.updated), let now = message.range(of: Self.toTimers) {
            for timer in Self.timers(in: message[now.upperBound...]) { fold(timer, at: date) }
        }
        return timers != before
    }

    private mutating func fold(_ timer: Logged, at date: Date) {
        let was = timers[timer.id]
        switch timer.state {
        case "Running":
            switch was {
            case .paused(let left)?: timers[timer.id] = .running(ends: date.addingTimeInterval(left))
            case .rang?: timers[timer.id] = .running(ends: date.addingTimeInterval(timer.duration))
            case .running?, nil: break  // running already, or never followed
            }
        case "Paused":
            if case .running(let ends)? = was { timers[timer.id] = .paused(left: max(0, ends.timeIntervalSince(date))) }
        case "Stopped":
            // The Clock keeps its presets as stopped timers: never followed.
            guard was != nil || gaveUp.remove(timer.id) != nil else { return }
            if timer.fired && !timer.dismissed {
                timers[timer.id] = .rang
                rangAt[timer.id] = date
            } else {
                timers[timer.id] = nil
            }
        default:
            break
        }
    }

    static let added = "didAddTimers ("
    static let updated = "didUpdateTimers fromTimers:"
    static let toTimers = ") toTimers: ("
    static let answered = "Remove record from response action: "
    static let clockApp = #"app:"com.apple.clock""#

    /// The lines worth reading, for a `log` predicate.
    public static let predicate =
        #"(process == "mobiletimerd" AND subsystem == "com.apple.mobiletimer.logging" AND category == "Timers" AND (eventMessage CONTAINS "didAddTimers" OR eventMessage CONTAINS "didUpdateTimers")) OR (process == "usernoted" AND eventMessage BEGINSWITH "Remove record from response action: " AND eventMessage CONTAINS "com.apple.clock")"#

    struct Logged: Equatable {
        let id: String
        let state: String
        let duration: TimeInterval
        let fired: Bool
        let dismissed: Bool
    }

    /// Every timer description in `text`, in order.
    static func timers(in text: Substring) -> [Logged] {
        var found: [Logged] = []
        var rest = text
        while let start = rest.range(of: "TimerID: ") {
            rest = rest[start.upperBound...]
            let end = rest.range(of: "TimerID: ")?.lowerBound ?? rest.endIndex
            let one = rest[..<end]
            let id = String(one.prefix(36))
            guard id.count == 36,
                  let state = field(", state:", in: one, upTo: ","),
                  let duration = field(", duration:", in: one, upTo: ",").flatMap({ TimeInterval($0) }),
                  let fired = field(", firedDate: ", in: one, upTo: ", dismissedDate:"),
                  let dismissed = field(", dismissedDate: ", in: one, upTo: ",")
            else { continue }
            found.append(Logged(id: id, state: String(state), duration: duration,
                                fired: fired != "(null)", dismissed: dismissed != "(null)"))
        }
        return found
    }

    /// The text between `name` and the next `stop`.
    static func field(_ name: String, in text: Substring, upTo stop: String) -> Substring? {
        guard let start = text.range(of: name) else { return nil }
        let value = text[start.upperBound...]
        guard let end = value.range(of: stop) else { return nil }
        return value[..<end.lowerBound]
    }
}
