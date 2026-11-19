import Foundation

/// Live mode standing down because every pill it draws is turned off in
/// Settings: holding the bar under a cover with nothing to show costs the
/// pictures and the covers for no pill. It stays down while the same
/// activities run with the same pills off, so the loop doesn't come
/// straight back for them (with the assertion up, no pill can be read to
/// tell it otherwise). The Live Activities item stands in meanwhile.
public struct PillsOffStandDown: Equatable, Sendable {
    /// How many activities ran when it stood down (the watcher's count).
    public let count: Int
    /// The pills that were up then, every one turned off, by the name macOS
    /// gives them.
    public let seen: Set<String>
    /// How many pills were up then. Fewer than `count` means an activity ran
    /// with no pill on the bar (Now Playing, paused): its pill can come back
    /// with no change in the count.
    public let pills: Int

    public init(count: Int, seen: Set<String>, pills: Int? = nil) {
        self.count = count
        self.seen = seen
        self.pills = pills ?? seen.count
    }

    /// Whether a running activity has no pill up, so one may come back with
    /// nothing reported: playback resuming is the only word of it (#156).
    public var pillMayReturn: Bool { pills < count }

    /// Whether every pill drawn is one Settings turned off. macOS's own pill
    /// (Camera & mic) has no switch, so it always keeps live mode up.
    public static func everyPillOff(_ pills: [(off: Bool, system: Bool)]) -> Bool {
        !pills.isEmpty && pills.allSatisfy { $0.off && !$0.system }
    }

    /// After the watcher reports: nil once another activity starts or none
    /// runs. One ending leaves the rest off as they were.
    public func after(running: Bool, count: Int) -> PillsOffStandDown? {
        guard running, count <= self.count else { return nil }
        // Which activity ended isn't known: its pill is taken as one of those
        // up, so a pill that may still come back isn't ruled out.
        return PillsOffStandDown(count: count, seen: seen, pills: max(0, pills - (self.count - count)))
    }

    /// After Settings changes which pills are off: nil once one of the pills
    /// that was up is on again. Turning on one that isn't running keeps it
    /// down: it has no pill to draw, and coming back for it would only film
    /// the bar and leave again.
    public func after(hidden now: Set<String>) -> PillsOffStandDown? {
        seen.isSubset(of: now) ? self : nil
    }

    /// How long every pill has been off without a break. Live mode stands
    /// down only once that lasts `grace`: a new activity's pill lands a
    /// moment after its log line (a camera's long after), and a stand-down
    /// before it lands would keep it off the bar for as long as the count
    /// stays the same.
    public struct Clock: Equatable, Sendable {
        public private(set) var since: Date?

        public init() {}

        public mutating func reset() { since = nil }

        /// True once every pill has been off for `grace`, counted from the
        /// first look that found them all off since the last reset. A look
        /// that finds one on starts it over.
        public mutating func due(allOff: Bool, now: Date, grace: TimeInterval) -> Bool {
            guard allOff else {
                since = nil
                return false
            }
            let start = since ?? now
            since = start
            return now.timeIntervalSince(start) >= grace
        }
    }
}
