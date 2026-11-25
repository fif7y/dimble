// SingleInstance.swift
// One Dimble at a time. MenuBarAgent can start Dimble again by itself within
// 30 ms of it quitting (3 of 170 quits on macOS 27.3, 2026-11-24). Whatever
// was about to open it, an update or the relaunch after a language change,
// then starts a second one, and two of them fight over the bar.

import Foundation

public enum SingleInstance {
    public struct Copy: Equatable, Sendable {
        public let pid: Int32
        /// When the process started, in seconds. Not NSRunningApplication's
        /// launch date, which is nil for a copy LaunchServices didn't open.
        public let startedAt: TimeInterval

        public init(pid: Int32, startedAt: TimeInterval) {
            self.pid = pid
            self.startedAt = startedAt
        }
    }

    public enum Verdict: Equatable, Sendable {
        case start
        /// These started earlier: they quit, then this one starts.
        case takeOver([Int32])
        /// This one started later and is the one to keep.
        case yield(to: Int32)
    }

    /// The copy that started last stays. After an update the one MenuBarAgent
    /// brought back is the old version, and it always starts first. Two copies
    /// that judge each other at the same moment must agree, hence the pid.
    public static func verdict(me: Copy, others: [Copy]) -> Verdict {
        func later(_ a: Copy, than b: Copy) -> Bool { (a.startedAt, a.pid) > (b.startedAt, b.pid) }
        let others = others.filter { $0.pid != me.pid }
        if let last = others.filter({ later($0, than: me) }).max(by: { later($1, than: $0) }) {
            return .yield(to: last.pid)
        }
        return others.isEmpty ? .start : .takeOver(others.map(\.pid).sorted())
    }
}
