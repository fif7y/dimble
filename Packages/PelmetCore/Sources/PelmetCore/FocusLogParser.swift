// FocusLogParser.swift
// The Focus state as donotdisturbd narrates it. Its "Did receive state
// update" log line carries the whole DNDState — active mode identifier, and
// the mode's name, SF Symbol and tint — in the clear (macOS 27, probed
// 2026-09-16), which is the only door a third-party process has: the daemon
// rejects unentitled XPC clients and its database sits behind Full Disk
// Access. Pure string work so the shape of a real line can be pinned in a test.

import Foundation

/// A Focus mode as macOS describes it.
public struct FocusMode: Equatable, Sendable {
    /// `com.apple.donotdisturb.mode.default`, `com.apple.sleep.sleep-mode`, a
    /// UUID-style id for a custom Focus.
    public let identifier: String
    /// Localised display name ("Do Not Disturb").
    public let name: String
    /// SF Symbol the OS draws for it ("moon.fill").
    public let symbol: String

    public init(identifier: String, name: String, symbol: String) {
        self.identifier = identifier
        self.name = name
        self.symbol = symbol
    }
}

/// What a window of donotdisturbd's log says was on when Pelmet started.
public enum FocusBootRead: Equatable, Sendable {
    /// The lines decided it: a mode, or nil for no Focus on.
    case settled(FocusMode?)
    /// A Focus is on and these lines never named it — read a wider window.
    case unnamed
    /// Not a line on record.
    case nothing
}

public enum FocusLogParser {
    /// What the log says is on, from one window of it in the order `log
    /// show` hands it out (oldest first).
    ///
    /// A state update is the mode's only name, so the newest one normally
    /// decides. It cannot decide alone: a boot into a Focus that was already
    /// on writes no state update at all, only snapshots that hold its
    /// assertion (Gab's 2026-11-05 boot into Sleep logged three of them and
    /// nothing else; the first state update came four minutes later, when
    /// the schedule rolled over). So a held snapshot newer than the newest
    /// state update means a Focus is on whatever that update said, and the
    /// mode is taken from the last update that named one — the pre-shutdown
    /// "off" that used to win left a scheduled Do Not Disturb reading off
    /// for the whole session (#92).
    public static func bootRead(_ messages: [String]) -> FocusBootRead {
        let decisive = messages.lastIndex(where: isDecisive)
        let held = messages.lastIndex(where: holdsAssertion)
        if let held, decisive.map({ held > $0 }) ?? true {
            guard let mode = messages[...held].reversed().lazy
                .compactMap(activeMode(in:)).first
            else { return .unnamed }
            return .settled(mode)
        }
        guard let decisive else { return .nothing }
        return .settled(activeMode(in: messages[decisive]))
    }

    /// A state update, or a snapshot that says no Focus is on. A snapshot
    /// still naming an assertion leaves the mode to the state update beside
    /// it; `bootRead` is what weighs the two.
    public static func isDecisive(_ message: String) -> Bool {
        !message.hasPrefix(snapshotPrefix) || snapshotSaysOff(message)
    }

    /// A snapshot that still names an assertion: a Focus is on, unnamed.
    public static func holdsAssertion(_ message: String) -> Bool {
        message.hasPrefix(snapshotPrefix) && !snapshotSaysOff(message)
    }

    /// The mode a `Did receive state update` message says is active now, or
    /// nil when it says none is. Only the `state:` half is read — the
    /// message repeats the previous state after it, and os_log cuts the
    /// whole line at 1 KB, so the fields are taken from the mode block
    /// (which comes first) rather than the trailing `activeModeIdentifier`.
    public static func activeMode(in message: String) -> FocusMode? {
        var state = Substring(message)
        if let previous = state.range(of: "previousState:") {
            state = state[..<previous.lowerBound]
        }
        guard !state.contains("activeModeConfiguration: (null)"),
              let mode = state.range(of: "mode: <DNDMode")
        else { return nil }
        let block = state[mode.upperBound...]
        guard let identifier = value(after: "modeIdentifier", in: block)
            ?? value(after: "activeModeIdentifier", in: state),
            identifier != "(null)"
        else { return nil }
        return FocusMode(
            identifier: identifier,
            name: value(after: "name", in: block) ?? identifier,
            symbol: value(after: "symbolImageName", in: block) ?? "moon.fill"
        )
    }

    /// Whether a `Calculate DND state for snapshot` message says no Focus is
    /// on (an empty `activeAssertionUUIDs` list). donotdisturbd recomputes
    /// that list on every change, including the ones it never announces with
    /// a state update: a location Focus that ended on the iPhone while the
    /// Mac slept came back at wake as an empty list and nothing else (#70).
    /// A list that still names an assertion says nothing about which mode,
    /// so it reads false and the state update stays in charge.
    public static func snapshotSaysOff(_ message: String) -> Bool {
        guard message.hasPrefix(snapshotPrefix),
              let open = message.range(of: "activeAssertionUUIDs=("),
              let close = message[open.upperBound...].firstIndex(of: ")")
        else { return false }
        return message[open.upperBound..<close].allSatisfy(\.isWhitespace)
    }

    /// The start of donotdisturbd's snapshot message, for predicates.
    public static let snapshotPrefix = "Calculate DND state for snapshot"

    /// `key: value;` in the `<DNDMode …>` description style, the value
    /// ending at the field separator or the object's closing bracket.
    private static func value(after key: String, in text: Substring) -> String? {
        guard let range = text.range(of: " \(key): ") else { return nil }
        let rest = text[range.upperBound...]
        let end = rest.firstIndex { $0 == ";" || $0 == ">" } ?? rest.endIndex
        let value = rest[..<end].trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }
}
