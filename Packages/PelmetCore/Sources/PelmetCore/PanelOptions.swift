// PanelOptions.swift
// How the panel draws the hidden icons (docs/PANEL-PLAN.md §3). Lives in the
// settings blob next to `hiddenIconsIn`. Every field falls back on its own, so
// a blob from an older or newer build, or one edited by hand, costs only the
// field that is wrong.

import Foundation

public struct PanelOptions: Codable, Equatable, Sendable {
    /// What Always Hidden does when the panel opens. Raw values are the
    /// stored form; the names the user reads are Settings' business.
    public enum AlwaysHiddenMode: String, Codable, CaseIterable, Sendable {
        /// Behind a fold row, closed on every open.
        case folded
        /// Behind the fold row, open or closed as the user left it
        /// (`alwaysHiddenOpen`).
        case asLeft
        /// Not shown at rest. ⌥-click, search and dragging still reach it.
        case hidden
    }

    /// What opens Always Hidden's fold in the panel. None of them is wider
    /// than the grid, so the panel is as narrow as its icons.
    public enum AlwaysHiddenFold: String, Codable, CaseIterable, Sendable {
        /// A "+10" tile after the icons above it.
        case tile
        /// A small count under the icons.
        case count
        /// A grabber on the bottom edge, staying put as the tiles come out
        /// under it.
        case handle
    }

    /// Keep the chevron anchor by default; only empty-bar clicks can opt into centering.
    public var centersOnClick: Bool = false

    /// A name under every tile.
    public var showsNames: Bool = false
    /// Dimmed tiles for apps in a section that aren't running, a click
    /// opens one. Off, a search in the panel still finds them.
    public var showsClosedApps: Bool = false
    /// The most columns a row may have, one per names mode: the user sets
    /// them by dragging the panel's edge, and each mode keeps its own width.
    /// Nil is Auto, `autoColumns`.
    public var columnsWithNames: Int?
    public var columnsCompact: Int?
    /// A Pelmet separator starts a new row of tiles instead of being dropped.
    public var separatorsBreakRows: Bool = false
    public var alwaysHidden: AlwaysHiddenMode = .folded
    /// Where the fold was left; read only for `.asLeft`.
    public var alwaysHiddenOpen: Bool = false
    public var alwaysHiddenFold: AlwaysHiddenFold = .tile
    /// A cog under the tiles, in the panel's bottom-right corner, that opens
    /// Settings (#95). Off by default: the panel's own right-click menu
    /// already carries the row, and a control drawn at rest costs a line of
    /// the panel's height whether or not anyone reaches for it.
    public var showsSettingsButton: Bool = false

    /// What Auto means: the widest a row grows. The grid is never wider than
    /// its icons need, so a panel with three icons is three columns.
    public static let autoColumns = 5
    /// The drag handle's reach. A stored value outside it is pulled in.
    public static let columnRange = 2...10

    public init() {}

    /// The setting for the current names mode.
    public var columns: Int? {
        get { showsNames ? columnsWithNames : columnsCompact }
        set {
            if showsNames { columnsWithNames = newValue } else { columnsCompact = newValue }
        }
    }

    private enum CodingKeys: String, CodingKey {
        case showsNames, columnsWithNames, columnsCompact, separatorsBreakRows, alwaysHidden, alwaysHiddenOpen
        case alwaysHiddenFold, showsClosedApps, showsSettingsButton, centersOnClick
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = PanelOptions()
        // Per field, like the store (`KeyedDecodingContainer.field`): a present
        // but invalid value (an unknown mode from a newer build) must reset
        // that field, not the whole panel.
        func count(_ key: CodingKeys) -> Int? {
            c.field(Int?.self, key, nil)
                .map { min(max($0, Self.columnRange.lowerBound), Self.columnRange.upperBound) }
        }
        centersOnClick = c.field(Bool.self, .centersOnClick, defaults.centersOnClick)
        showsNames = c.field(Bool.self, .showsNames, defaults.showsNames)
        columnsWithNames = count(.columnsWithNames)
        columnsCompact = count(.columnsCompact)
        separatorsBreakRows = c.field(Bool.self, .separatorsBreakRows, defaults.separatorsBreakRows)
        alwaysHidden = c.field(AlwaysHiddenMode.self, .alwaysHidden, defaults.alwaysHidden)
        alwaysHiddenOpen = c.field(Bool.self, .alwaysHiddenOpen, defaults.alwaysHiddenOpen)
        alwaysHiddenFold = c.field(AlwaysHiddenFold.self, .alwaysHiddenFold, defaults.alwaysHiddenFold)
        showsClosedApps = c.field(Bool.self, .showsClosedApps, defaults.showsClosedApps)
        showsSettingsButton = c.field(Bool.self, .showsSettingsButton, defaults.showsSettingsButton)
    }
}
