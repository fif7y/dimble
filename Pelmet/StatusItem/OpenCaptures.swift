// OpenCaptures.swift
// The capture streams asked to start whose stop hasn't answered yet, so a
// quit can wait for them. A process that goes while its stream is starting
// leaves replayd pushing frames at nobody, with the recording indicator lit
// until replayd restarts (reproduced 2026-11-25: exit 25ms into
// startCapture, 290 errors a second; a quit 2026-11-24 left a pill for 15
// minutes). A stream that is running or stopping, and a
// SCScreenshotManager still, end with the process.

import Foundation

@MainActor
final class OpenCaptures {
    private var count = 0
    private var closed = false

    /// False once the app is quitting: no stream starts after that.
    func begin() -> Bool {
        guard !closed else { return false }
        count += 1
        return true
    }

    func end() { count -= 1 }

    /// Refuses new streams and waits for the open ones. False when some are
    /// still open at the deadline.
    func close(within timeout: TimeInterval) async -> Bool {
        closed = true
        let deadline = Date().addingTimeInterval(timeout)
        while count > 0, Date() < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        return count == 0
    }
}
