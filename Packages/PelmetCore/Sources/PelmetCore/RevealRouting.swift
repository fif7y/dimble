// RevealRouting.swift
// Where hidden icons show up when a reveal fires (docs/PANEL-PLAN.md §2): the
// menu bar as today, or a panel. The panel is a second way to show the same
// sections, not a second reveal: the rehide machine still owns revealed /
// concealed, and this only decides which presenter draws it.

import Foundation

/// What the user chose for "Show hidden icons in". Stored in the settings
/// blob, so an unknown raw value (a newer build's, hand-edited) reads as the
/// menu bar: a downgrade lands on the behaviour every build has.
public enum RevealTarget: String, Codable, CaseIterable, Sendable {
    case menuBar
    case panel
    /// The panel as one row of bar-scale icons.
    case row

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = RevealTarget(rawValue: raw) ?? .menuBar
    }

    /// How the panel lays tiles out for this target; nil when the icons stay
    /// in the bar.
    public var panelLayout: PanelGrid.Layout? {
        switch self {
        case .menuBar: nil
        case .panel: .panel
        case .row: .row
        }
    }
}

public enum RevealRouting {
    /// A policy-opened bar is only the baseline; explicit Always Hidden
    /// requests still follow the panel setting.
    public static func replacesPolicyBarWithPanel(current: Set<Section>, openedBy: RevealReason,
                                                  requested: Set<Section>, reason: RevealReason,
                                                  target: RevealTarget) -> Bool {
        openedBy == .displayPolicy && !current.contains(.alwaysHidden)
            && requested.contains(.alwaysHidden) && destination(for: reason, target: target) == .panel
    }

    /// A click in the empty bar of a display that shows all icons asks for
    /// icons it already shows, so it opens no panel. The chevron is not one
    /// of these: there it widens to Always Hidden (#96, `clickWidensToAlwaysHidden`,
    /// which runs first), and a request that already carries Always Hidden
    /// is a deliberate one wherever it came from.
    public static func suppressesPanelClick(_ reason: RevealReason, sections: Set<Section>, behavior: DisplayBehavior, target: RevealTarget) -> Bool {
        behavior == .alwaysShowAll && target != .menuBar && !sections.contains(.alwaysHidden)
            && (reason == .click || reason == .doubleClick)
    }

    /// The show-all policy holds the native baseline open, not temporary
    /// panels or Always Hidden reveals.
    public static func displayPolicyHoldsReveal(behavior: DisplayBehavior, anchored: Bool, panelShowsReveal: Bool, sections: Set<Section>) -> Bool {
        behavior == .alwaysShowAll && !anchored && !panelShowsReveal && !sections.contains(.alwaysHidden)
    }

    /// Capture an empty-bar click only on opening, so an open panel stays put while aiming at a tile.
    public static func centersPanelOnClick(_ reason: RevealReason?, enabled: Bool, isOpen: Bool) -> Bool {
        enabled && !isOpen && (reason == .click || reason == .doubleClick)
    }

    public enum Destination: Equatable, Sendable {
        case bar
        case panel
    }

    /// Reveals a person asks for follow the setting, a ⌘-drag too: its drop
    /// target is wherever hidden icons show (the panel takes the drop through
    /// `BarDragRedirect`). The rest need the real bar: Apply and the editor's
    /// preview measure and drag icons that are on it, the always-show policy
    /// is "don't hide anything here", and an item asked for in the bar is the
    /// point. No `default:`, so a new reason has to pick a side.
    public static func destination(for reason: RevealReason, target: RevealTarget) -> Destination {
        switch reason {
        case .hover, .click, .doubleClick, .hotkey, .statusItem, .barDrag:
            target == .menuBar ? .bar : .panel
        case .displayPolicy, .settingsPreview, .itemInBar:
            .bar
        }
    }

    /// The bar whatever "Show hidden icons in" says, a reveal with no reason
    /// too (every reveal was the bar's before the setting existed).
    public static func needsBar(_ reason: RevealReason?) -> Bool {
        guard let reason else { return true }
        return destination(for: reason, target: .panel) == .bar
    }

    /// Started by the pointer on a bar: that bar's display is the one, a bar
    /// read or not. The rest can come with the pointer anywhere.
    public static func startsAtBar(_ reason: RevealReason) -> Bool {
        switch reason {
        case .hover, .displayPolicy, .click, .doubleClick, .statusItem, .barDrag:
            true
        case .hotkey, .settingsPreview, .itemInBar:
            false
        }
    }

    /// A chevron click on a display that shows all icons (#96): its Hidden
    /// icons are out already, so the click is for Always Hidden, the way a
    /// ⌥-click is. A hover there stays quiet.
    public static func clickWidensToAlwaysHidden(
        _ reason: RevealReason, sections: Set<Section>, behavior: DisplayBehavior
    ) -> Bool {
        reason == .statusItem && sections == [.hidden] && behavior == .alwaysShowAll
    }

    /// The display whose "Show hidden icons in" a reveal follows (#88), and
    /// where a panel for it opens: the one under the pointer, never macOS's
    /// active one (the bright bar, the last click's). A dimmed bar is still
    /// the bar the pointer is on. A reveal that didn't start on a bar (a
    /// shortcut, Search) takes the pointer's display only when a bar is drawn
    /// there, then the active display's, then the primary.
    public static func decidingDisplay<Display: Equatable>(
        atBar: Bool, pointer: Display?, active: Display?, primary: Display?, hasBar: (Display) -> Bool
    ) -> Display? {
        if let pointer, atBar || hasBar(pointer) { return pointer }
        if let active, active != pointer, hasBar(active) { return active }
        return primary
    }
}
