// StreamRestartBackoff.swift
// How long to wait before reopening a `log stream` child that ended.
//
// Dimble reads Focus, the Clock's timers, SharePlay and Live Activities off
// `/usr/bin/log stream`, and macOS ends those children on its own: logd
// restarts, the Mac sleeps, something kills them. A machine where
// `log stream` is refused outright ("Must be admin") would spin without a
// backoff, so each failure waits longer than the last.
//
// The part that was wrong until 0.4.0: the four copies of this counter only
// ever went up. A stream that came back, ran for an hour and then ended
// with the next logd restart was treated as the fifth failure in a row, so
// every later reopen waited the full minute for the rest of the launch, and
// a Focus change could sit a minute behind the bar. A stream that stayed up
// a while plainly was not a refusal, so its uptime resets the count.
//
// Pure value type, no clock of its own: the caller passes the uptime it
// measured, which is what makes the rule testable.

import Foundation

/// The growing wait between reopening a log stream, reset by a stream that
/// stayed up.
public struct StreamRestartBackoff: Sendable, Equatable {
    /// Never wait longer than this between tries.
    public static let cap: TimeInterval = 60
    /// A stream up at least this long ended for a reason of its own, not
    /// because Dimble cannot open one.
    public static let steady: TimeInterval = 60

    private var strikes = 0

    public init() {}

    /// Failures in a row, as the backoff counts them.
    public var consecutive: Int { strikes }

    /// The wait after a child that was up for `uptime` seconds ended.
    /// Pass `nil` when it never opened.
    public mutating func delay(afterUptime uptime: TimeInterval?) -> TimeInterval {
        if let uptime, uptime >= Self.steady { strikes = 0 }
        strikes += 1
        return min(Self.cap, TimeInterval(2 << min(strikes, 5)))
    }
}
