// SettingsIndex.swift
// The setting rows the command bar can jump to, by label and a few words
// people reach for instead of it ("hotkey", "startup"). Static on purpose: the
// panes are SwiftUI and carry no registry to read. Labels are the rows' own
// catalog keys, so a row renamed there must be renamed here. Return opens
// Settings on the row's tab.

import Foundation

struct SettingsIndexEntry {
    let id: String
    let title: String
    let tab: SettingsTab
    let keywords: [String]
}

enum SettingsIndex {
    /// Localized at call time (the command bar builds it when it opens).
    static func entries() -> [SettingsIndexEntry] {
        func general(_ id: String, _ title: String, _ keywords: [String]) -> SettingsIndexEntry {
            SettingsIndexEntry(id: id, title: title, tab: .general, keywords: keywords)
        }
        func behavior(_ id: String, _ title: String, _ keywords: [String]) -> SettingsIndexEntry {
            SettingsIndexEntry(id: id, title: title, tab: .behavior, keywords: keywords)
        }
        func menuBar(_ id: String, _ title: String, _ keywords: [String]) -> SettingsIndexEntry {
            SettingsIndexEntry(id: id, title: title, tab: .menuBar, keywords: keywords)
        }
        func panel(_ id: String, _ title: String, _ keywords: [String]) -> SettingsIndexEntry {
            SettingsIndexEntry(id: id, title: title, tab: .panel, keywords: keywords)
        }
        func search(_ id: String, _ title: String, _ keywords: [String]) -> SettingsIndexEntry {
            SettingsIndexEntry(id: id, title: title, tab: .search, keywords: keywords)
        }
        return [
            general("launchAtLogin", String(localized: "Launch at login"),
                    ["startup", "login items", "open at login", "boot"]),
            general("showStatusItem", String(localized: "Show Dimble icon in the menu bar"),
                    ["chevron", "icon", "iconless", "hide icon"]),
            general("hotkey", String(localized: "Show hidden icons"),
                    ["hotkey", "shortcut", "keyboard shortcut", "toggle", "show hide", "key", "always hidden", "notification center"]),
            general("settingsHotkey", String(localized: "Open Settings"),
                    ["hotkey", "shortcut"]),
            general("accentColor", String(localized: "Accent color"),
                    ["color", "colour", "theme", "tint", "purple", "blue", "green", "orange", "pink", "indigo", "custom", "choose your own"]),
            general("rightClickMenu", String(localized: "Right-click menu"),
                    ["context menu", "empty spot", "bar menu"]),
            general("language", String(localized: "Display language"),
                    ["language", "translation", "locale"]),
            general("accessibility", String(localized: "Accessibility"),
                    ["permission", "access", "grant", "allow"]),
            general("screenRecording", String(localized: "Screen Recording"),
                    ["permission", "capture", "grant", "allow", "cover"]),

            behavior("animation", String(localized: "Animation"),
                     ["reveal", "smooth", "fade", "instant", "transition", "style", "speed"]),
            behavior("iconSpacing", String(localized: "Space between icons"),
                     ["gap", "padding", "spacing", "tight", "wide"]),
            behavior("hoverReveal", String(localized: "Reveal on hover"),
                     ["hover", "pointer", "mouse", "hands-free", "delay", "wait"]),
            behavior("clickReveal", String(localized: "Reveal on click in empty space"),
                     ["click", "empty area", "blank"]),
            behavior("doubleClickReveal", String(localized: "Double-click shows Always Hidden too"),
                     ["double click", "always hidden"]),
            behavior("autoRehide", String(localized: "Hide again"),
                     ["auto hide", "rehide", "conceal", "timer", "delay", "seconds", "close", "never"]),
            behavior("rehideElsewhere", String(localized: "Hide again when you click elsewhere"),
                     ["click outside", "dismiss", "conceal", "rehide"]),
            behavior("clockClick", String(localized: "Clicking the clock opens Notification Center"),
                     ["notification center", "clock", "calendar", "shortcut"]),

            menuBar("systemExtras", String(localized: "System extras"),
                    ["now playing", "camera", "airdrop", "focus", "timer", "collateral"]),
            menuBar("liveActivities", String(localized: "Show Live Activities"),
                    ["live activity", "live mode", "pill", "dynamic island", "timer", "call", "screen recording"]),

            panel("hiddenIconsIn", String(localized: "Show hidden icons in"),
                  ["panel", "grid", "row", "notch", "overflow", "dropdown", "tray", "layout", "per display", "monitor", "external"]),
            panel("panelNames", String(localized: "Show names"),
                  ["labels", "names", "titles", "panel"]),
            panel("panelColumns", String(localized: "Columns"),
                  ["width", "per row", "grid", "panel"]),
            panel("panelClosedApps", String(localized: "Show closed apps"),
                  ["closed", "not running", "launcher", "dimmed", "apps", "panel"]),
            panel("panelGroups", String(localized: "Separators start a new row"),
                  ["groups", "separator", "dividers", "panel"]),
            panel("panelAlwaysHidden", String(localized: "Always Hidden"),
                  ["fold", "always hidden", "panel"]),
            panel("panelFold", String(localized: "Opens from"),
                  ["always hidden fold", "fold", "tile", "chip", "count", "handle", "grabber", "always hidden", "panel"]),

            search("searchHotkey", String(localized: "Search the menu bar"),
                   ["command bar", "find", "shortcut", "hotkey"]),
            search("itemShortcuts", String(localized: "Aliases and shortcuts"),
                   ["alias", "nickname", "shortcut", "hotkey", "icon shortcut"]),
            search("searchHistory", String(localized: "Search learns what you open"),
                   ["search history", "history", "forget", "learning", "frecency", "clear", "reset"]),
        ]
    }

    /// The tab's name as the sidebar shows it, for a row's subtitle.
    static func tabName(_ tab: SettingsTab) -> String {
        switch tab {
        case .general: String(localized: "General")
        case .behavior: String(localized: "Behavior")
        case .menuBar: String(localized: "Menu Bar")
        case .panel: String(localized: "Panel")
        case .search: String(localized: "Search")
        default: tab.rawValue
        }
    }
}
