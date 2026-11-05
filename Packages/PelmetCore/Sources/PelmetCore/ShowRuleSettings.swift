// ShowRuleSettings.swift
// "Show when it matters" (#86): a hidden icon that comes back on the bar while
// its state matters. These are the rules for Apple's own Battery and Wi-Fi,
// which only the app can watch. Pelmet's own items keep theirs on their spec
// (`ExtraItemSpec.showRule`): the extras manager already knows when a backup
// runs or audio plays.

import Foundation

/// When Battery shows on the bar from a hidden section.
public enum BatteryShowCondition: String, Codable, CaseIterable, Sendable {
    /// Whenever the Mac runs on its battery.
    case onBattery
    /// Running on the battery and under `lowCharge` percent.
    case below20

    /// The charge `below20` is under.
    public static let lowCharge = 20

    /// `percent` is nil when the charge can't be read: a low-charge rule
    /// stays quiet rather than guess.
    public func isMet(onBattery: Bool, percent: Int?) -> Bool {
        switch self {
        case .onBattery: onBattery
        case .below20: onBattery && (percent.map { $0 < Self.lowCharge } ?? false)
        }
    }
}

public struct ShowRuleSettings: Codable, Equatable, Sendable {
    public var batteryOn = false
    /// Kept while the rule is off, so switching it back on finds the
    /// condition the person picked.
    public var batteryCondition: BatteryShowCondition = .onBattery
    /// Wi-Fi is on and joined to no network.
    public var wifiOn = false
    /// Also while Wi-Fi is on a hotspot (#121). Kept while the rule is off,
    /// like Battery's condition. A plain flag, so an older build ignores it.
    public var wifiHotspot = false

    public init() {}

    /// The condition in force, nil with the rule off.
    public var battery: BatteryShowCondition? { batteryOn ? batteryCondition : nil }

    /// Whether anything needs to read Wi-Fi's path for a hotspot.
    public var wifiWatchesHotspot: Bool { wifiOn && wifiHotspot }

    private enum CodingKeys: String, CodingKey {
        case batteryOn, batteryCondition, wifiOn, wifiHotspot
    }

    // Per field, like the store: a blob from before this existed, or one bad
    // value, falls back to the default for that field alone.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = ShowRuleSettings()
        batteryOn = c.field(Bool.self, .batteryOn, defaults.batteryOn)
        batteryCondition = c.field(BatteryShowCondition.self, .batteryCondition, defaults.batteryCondition)
        wifiOn = c.field(Bool.self, .wifiOn, defaults.wifiOn)
        wifiHotspot = c.field(Bool.self, .wifiHotspot, defaults.wifiHotspot)
    }
}

public extension SettingsStore {
    /// One-shot for stores from before "Show when it matters": 0.3.1's Focus
    /// came out on the bar while a Focus was on, whatever its section. The
    /// new default only rides the section, so every Focus in Hidden or Always
    /// Hidden gets `.whenActive` (its section's reveal, or a Focus on), the
    /// bar it had. One in Visible shows either way. Returns the sections of
    /// the items it changed, empty when there was nothing to do.
    mutating func keepFocusOutWhileActive() -> [Section] {
        var changed: [Section] = []
        for index in extraItems.indices where extraItems[index].kind == .focus {
            let key = ItemID.status(bundle: PelmetBundle.mainID, title: extraItems[index].itemTitle).sectionKey
            let section = sectionModel.section(of: key)
            guard section != .visible, extraItems[index].resolvedShowRule != .whenActive else { continue }
            extraItems[index].showRule = .whenActive
            changed.append(section)
        }
        return changed
    }
}

/// Whether a rule on one of Apple's icons has anything to do. A rule that
/// can't apply is shown off and its switch disabled; the choice itself is
/// kept for when it can.
public enum ShowRuleAvailability: Equatable, Sendable {
    case applies
    /// The icon isn't in the menu bar at all (off in System Settings).
    case notInMenuBar
    /// The icon sits in Visible: it is on the bar whatever the rule says.
    case inVisible

    public init(inMenuBar: Bool, section: Section) {
        if !inMenuBar {
            self = .notInMenuBar
        } else if section == .visible {
            self = .inVisible
        } else {
            self = .applies
        }
    }
}
