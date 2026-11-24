// AutomationLink.swift
// The dimble:// links (#146, #169). Any web page can open a link (the
// browser asks first), so a link never reads anything: it shows or hides
// the icons, opens Search, or changes the layout the way the editor would,
// which you can always change back. Reading the layout is the Shortcuts
// action's, since a link can't hand anything back without telling the page.

import Foundation

public enum AutomationLink: Equatable, Sendable {
    /// Where an icon or a separator goes: next to an icon, named as the
    /// layout names it (its name, or the id Get Menu Bar Layout prints).
    public enum Place: Equatable, Sendable {
        case before(String)
        case after(String)
    }

    /// Search, with this text typed in (nil or empty: an empty field).
    case search(String?)
    /// The Hidden icons out.
    case show
    /// Hidden and Always Hidden out.
    case showAll
    /// Everything back.
    case hide
    /// What the Hidden shortcut does: out, or back if they're out.
    case toggle
    /// An icon to a section, or next to another icon (then `to` is that
    /// icon's section unless given).
    case move(icon: String, to: Section?, place: Place?)
    /// A new separator in a section, or next to an icon.
    case addSeparator(to: Section?, place: Place?)
    /// The separator with this id, or the one right next to an icon.
    case removeSeparator(id: String?, place: Place?)

    public static let scheme = "dimble"
    /// A launcher's query, not a document: longer text is cut.
    public static let maxQueryLength = 200
    /// A link longer than this is not one a person or a launcher made.
    public static let maxLinkLength = 4096

    /// The first `maxQueryLength` scalars: a character can be made of
    /// thousands of combining marks, so characters don't bound the size.
    static func cut(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.prefix(maxQueryLength)))
    }

    /// `dimble://search?q=Tailscale`, `dimble://show`, `dimble:hide`,
    /// `dimble://move?icon=Tailscale&to=hidden`,
    /// `dimble://add-separator?after=HomeBar`. Nil for another scheme, an
    /// action Dimble doesn't know, or one missing what it needs.
    public init?(url: URL) {
        guard url.absoluteString.utf8.count <= Self.maxLinkLength,
              url.scheme?.lowercased() == Self.scheme,
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return nil }
        // dimble://show has it as the host, dimble:show as the path.
        let action = (parts.host ?? parts.path)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .lowercased()
        func value(_ name: String) -> String? {
            guard let raw = parts.queryItems?.first(where: { $0.name.lowercased() == name })?.value else { return nil }
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : Self.cut(text)
        }
        let place: Place? = value("after").map(Place.after) ?? value("before").map(Place.before)
        let to = value("to").flatMap(Self.section(named:))
        switch action {
        case "search":
            let text = parts.queryItems?.first { $0.name == "q" }?.value?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            self = .search(text.map(Self.cut))
        case "show": self = .show
        case "show-all": self = .showAll
        case "hide": self = .hide
        case "toggle": self = .toggle
        case "move":
            // A `to` Dimble can't read is a typo, not "stay where it is".
            guard let icon = value("icon"), to != nil || place != nil,
                  value("to") == nil || to != nil else { return nil }
            self = .move(icon: icon, to: to, place: place)
        case "add-separator":
            guard to != nil || place != nil, value("to") == nil || to != nil else { return nil }
            self = .addSeparator(to: to, place: place)
        case "remove-separator":
            let id = value("id")
            guard id != nil || place != nil else { return nil }
            self = .removeSeparator(id: id, place: place)
        default: return nil
        }
    }

    /// `visible`, `hidden`, `always-hidden` (or `alwaysHidden`, as the
    /// layout prints it).
    public static func section(named name: String) -> Section? {
        switch name.lowercased().replacingOccurrences(of: "-", with: "").replacingOccurrences(of: " ", with: "") {
        case "visible": .visible
        case "hidden": .hidden
        case "alwayshidden": .alwaysHidden
        default: nil
        }
    }

    /// For the log: the action, never the text typed.
    public var name: String {
        switch self {
        case .search: "search"
        case .show: "show"
        case .showAll: "show-all"
        case .hide: "hide"
        case .toggle: "toggle"
        case .move: "move"
        case .addSeparator: "add-separator"
        case .removeSeparator: "remove-separator"
        }
    }
}
