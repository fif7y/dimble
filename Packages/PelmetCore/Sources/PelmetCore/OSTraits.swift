// OSTraits.swift
// What Dimble has learned about THIS macOS by trying it, rather than by
// reading a version number.
//
// Dimble reaches into undocumented menu bar behaviour, and Apple moves it in
// point releases: 27.3 (26C5035r, measured 2026-11-06) renamed the camera
// and mic pill, moved its panel to another process and stopped taking it off
// the bar under an assertion. None of that is an API addition, so
// `if #available` cannot see it, and `operatingSystemVersion` would pin
// Dimble to Apple's release schedule and need a ship for every point
// release — including one to undo the check if Apple restores the old
// behaviour in 27.4.
//
// So each answer here is measured once per launch. Dimble starts from the
// assumption that matches the newest macOS the behaviour was measured on,
// and the first observation that disagrees corrects it for the rest of the
// launch. Nothing is persisted: an OS update is a new boot, and a behaviour
// Apple puts back corrects itself with no release from us.
//
// A positive outranks a negative. Seeing the behaviour happen is proof;
// not seeing it can mean the thing was late, ghosted in AX, or never drawn.
// So a `true` is final and a `false` only lands while nothing has proved
// otherwise.
//
// Every trait names the build its assumption was measured on, and every
// change writes a log line, so a report says which macOS Dimble thinks it
// is running on without naming a version at all.
//
// Pure value type: no AX, no AppKit, no clock, so each rule can be pinned
// in a test.

import Foundation

/// Behaviours of the running macOS that Dimble can only learn by trying.
public struct OSTraits: Sendable, Equatable {
    public enum Trait: String, CaseIterable, Sendable {
        /// macOS leaves Apple's camera and mic pill on the menu bar while
        /// Dimble holds an assertion.
        ///
        /// Assumed true: that is 27.3's behaviour (26C5035r, measured
        /// 2026-11-06), where the pill became a Live Activity pill and live
        /// mode has to mirror it or the held cover paints over a privacy
        /// indicator. Up to 27.2 the assertion took the pill off the bar,
        /// which is the whole reason Dimble has a Camera & mic replica. On
        /// those, counting a camera session as an activity would send live
        /// mode looking for a pill that was never going to come: it leaves
        /// after the 10s grace, and each entry costs a screen capture that
        /// lights the recording indicator.
        case systemPillSurvivesAssertion
    }

    /// What Dimble believes before it has seen anything, per trait.
    public static func assumption(_ trait: Trait) -> Bool {
        switch trait {
        case .systemPillSurvivesAssertion: return true
        }
    }

    private var answers: [Trait: Bool] = [:]
    private var pinned: Set<Trait> = []

    public init() {}

    /// Forces an answer and stops this launch learning another.
    ///
    /// This is how the other macOS's path gets run without the other macOS.
    /// Dimble has no second Mac held at an older version, and these are
    /// exactly the branches no test here can reach, so every trait is
    /// deliberately forceable from a debug default. Nothing in the app sets
    /// one; a pinned trait says so in the log.
    public mutating func pin(_ trait: Trait, _ answer: Bool) {
        answers[trait] = answer
        pinned.insert(trait)
    }

    /// Whether this launch is being told what to think about a trait.
    public func isPinned(_ trait: Trait) -> Bool { pinned.contains(trait) }

    /// What Dimble is acting on: the measured answer, or the assumption
    /// until one lands.
    public func value(_ trait: Trait) -> Bool {
        answers[trait] ?? Self.assumption(trait)
    }

    /// The measured answer, or `nil` while this launch has not seen one.
    public func learned(_ trait: Trait) -> Bool? { answers[trait] }

    /// Records an observation and returns the line to log, or `nil` when it
    /// changed nothing. A `true` is final (proof); a `false` lands only
    /// while no `true` has.
    public mutating func learn(_ trait: Trait, _ answer: Bool, why: String) -> String? {
        guard !pinned.contains(trait) else { return nil }
        if answer {
            guard answers[trait] != true else { return nil }
            answers[trait] = true
        } else {
            guard answers[trait] == nil else { return nil }
            answers[trait] = false
        }
        return "ostraits: \(trait.rawValue) is \(answer) on this macOS — \(why)"
            + (answer == Self.assumption(trait) ? "" : " (assumed \(Self.assumption(trait)))")
    }
}
