// StreamRestartBackoffTests.swift
// The numbers match what the four status streams waited before 0.4.0
// (4, 8, 16, 32, 60, 60 …); the reset is the new part.

import Foundation
import Testing
@testable import PelmetCore

struct StreamRestartBackoffTests {
    /// A stream that never opens backs off the way it always did.
    @Test func growsToTheCapOnRepeatedFailure() {
        var backoff = StreamRestartBackoff()
        let waits = (0..<6).map { _ in backoff.delay(afterUptime: nil) }
        #expect(waits == [4, 8, 16, 32, 60, 60])
    }

    /// A stream that stayed up ended for a reason of its own, so the next
    /// wait is a first wait again. This is what the four copies got wrong:
    /// one afternoon of logd restarts used to leave every later reopen at
    /// the full minute for the rest of the launch.
    @Test func aStreamThatStayedUpResetsTheWait() {
        var backoff = StreamRestartBackoff()
        for _ in 0..<5 { _ = backoff.delay(afterUptime: nil) }
        #expect(backoff.consecutive == 5)
        #expect(backoff.delay(afterUptime: 3600) == 4)
        #expect(backoff.consecutive == 1)
    }

    /// Just under the threshold is still a flap.
    @Test func aShortRunDoesNotReset() {
        var backoff = StreamRestartBackoff()
        _ = backoff.delay(afterUptime: nil)
        #expect(backoff.delay(afterUptime: StreamRestartBackoff.steady - 1) == 8)
    }

    /// Exactly at the threshold counts as steady.
    @Test func theThresholdItselfResets() {
        var backoff = StreamRestartBackoff()
        _ = backoff.delay(afterUptime: nil)
        #expect(backoff.delay(afterUptime: StreamRestartBackoff.steady) == 4)
    }
}
