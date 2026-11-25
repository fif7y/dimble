// InstanceGuard.swift
// Makes sure this is the only Dimble running before it touches the bar, see
// SingleInstance for which copy stays.

import AppKit
import Darwin
import PelmetCore
import PelmetEngine

enum InstanceGuard {
    /// Waits, blocking, for any earlier copy to quit. False when this copy is
    /// the one that should go. Call once AppKit has finished launching: by
    /// then LaunchServices lists this process, so of two copies starting
    /// together at least one sees the other.
    static func claim() -> Bool {
        guard let bundleID = Bundle.main.bundleIdentifier, let me = copy(getpid()) else { return true }
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        let others = running.map(\.processIdentifier).filter { $0 != me.pid }.compactMap(copy)
        switch SingleInstance.verdict(me: me, others: others) {
        case .start:
            return true
        case .yield(let pid):
            PelmetLog.logBlocking("start: a newer copy is running (pid \(pid)), quitting this one")
            return false
        case .takeOver(let pids):
            PelmetLog.log("start: pid \(pids) is running too, asking it to quit")
            let old = running.filter { pids.contains($0.processIdentifier) }
            old.forEach { $0.terminate() }
            if !gone(pids, within: AppTiming.earlierCopyQuitDeadline) {
                PelmetLog.log("start: pid \(pids) still there, forcing it")
                old.forEach { $0.forceTerminate() }
                guard gone(pids, within: 1) else {
                    PelmetLog.logBlocking("start: pid \(pids) won't go, quitting this one")
                    return false
                }
            }
            PelmetLog.log("start: the earlier copy is gone")
            return true
        }
    }

    private static func gone(_ pids: [pid_t], within timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while pids.contains(where: { copy($0) != nil }) {
            guard Date() < deadline else { return false }
            usleep(20_000)
        }
        return true
    }

    /// nil when the process is gone.
    private static func copy(_ pid: pid_t) -> SingleInstance.Copy? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0,
              info.kp_proc.p_stat != UInt8(SZOMB) else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        return .init(pid: pid, startedAt: TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1_000_000)
    }
}
