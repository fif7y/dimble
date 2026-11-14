// PerfTrace.swift
// One `perf` log line per reveal/conceal: where the time went between the
// trigger (hover timer, click, hotkey) and the cover lifting. Diagnostics
// only — read it with `grep 'perf ' ~/Library/Logs/Dimble/dimble.log`.
//
//   perf reveal(hover): trigger→dispatch 3ms, cover 4ms (precaptured),
//     engine 141ms [walk 96ms plan 1ms activate 41ms walk2 88ms],
//     settled 240ms, lift 470ms
//
// A cover that was not precaptured names why, so the slow reveals in a
// log can be grouped by cause: `cover (live capture, picture 1240s old,
// over 900s)`, `no picture`, `picture from another active display`,
// `picture taken with the panel open`.
//
// Every number is ms since `dispatch` except the first, which is how long
// the intent took to reach `AppState.dispatch` (the hover re-verify's
// window-server IPCs, the click path's AX hit-test). No signposts: the
// unified log store is unreachable on this build (see PelmetLog).

import Foundation
import PelmetCore
import PelmetEngine

@MainActor
final class PerfTrace {
    /// The last trigger the input layer stamped, consumed by the next trace.
    /// Kept short-lived so a stale stamp never attributes to a later
    /// transition (a hover that re-verified and declined, then a hotkey).
    private static var pendingTrigger: (label: String, at: Date)?
    private static let triggerMaxAge: TimeInterval = 1

    /// Input layer: call the moment an intent is decided, BEFORE any gate
    /// that can be slow (hit-test, re-verify). A stamp already pending and
    /// fresh wins — the band monitor's mark precedes `AppState.reveal`'s.
    static func markTrigger(_ label: String) {
        if let pending = pendingTrigger, Date().timeIntervalSince(pending.at) < triggerMaxAge { return }
        pendingTrigger = (label, Date())
    }

    let kind: String
    private let started = Date()
    private var marks: [(label: String, ms: Int)] = []
    private var triggerNote = ""
    private var finished = false

    /// Begins at `dispatch`; pulls the pending trigger stamp if fresh.
    init(kind: String, reason: RevealReason?) {
        if let pending = Self.pendingTrigger, Date().timeIntervalSince(pending.at) < Self.triggerMaxAge {
            triggerNote = "trigger→dispatch \(Int((Date().timeIntervalSince(pending.at) * 1000).rounded()))ms"
            Self.pendingTrigger = nil
        }
        let label = reason.map { "\($0)" } ?? "engine"
        self.kind = "\(kind)(\(label))"
    }

    private var elapsedMS: Int { Int((-started.timeIntervalSinceNow * 1000).rounded()) }

    /// A phase that just ended, stamped with the time since dispatch.
    func mark(_ label: String, detail: String? = nil) {
        marks.append((detail.map { "\(label) (\($0))" } ?? label, elapsedMS))
    }

    /// The engine's own phase split, appended to the last mark.
    func note(_ timing: ConvergeTiming?) {
        guard let timing, let last = marks.popLast() else { return }
        marks.append(("\(last.label) [\(timing.summary)]", last.ms))
    }

    /// Emits the line once; later calls are no-ops so a safety-lifted cover
    /// and a normal lift cannot log twice.
    func finish(_ label: String) {
        guard !finished else { return }
        finished = true
        marks.append((label, elapsedMS))
        let phases = marks.map { "\($0.label) \($0.ms)ms" }
        let head = triggerNote.isEmpty ? [] : [triggerNote]
        PelmetLog.log("perf \(kind): \((head + phases).joined(separator: ", "))")
    }
}
