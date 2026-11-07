// ChevronMenu.swift
// What the right-click menu shows, and in which order. One stored menu for
// every surface that opens it (the chevron, a separator, the empty bar), so
// a person who trims it once is not surprised by a fuller menu somewhere
// else.
//
// Separators are in the order like anything else, but they carry no choice
// of their own: `drawnFlags` drops one that would lead, trail or sit next to
// another, so no arrangement can produce a menu that opens on a divider or
// stacks two. The editor reads the same flags, so its preview says what the
// menu will do rather than what the order literally holds.

import Foundation

/// A row the right-click menu can show. The raw values are persisted, so
/// they are renamed only with a migration.
public enum ChevronMenuEntry: String, CaseIterable, Codable, Sendable {
    case search
    case settings
    case toggle
    case showAll
    case animation
    case revealTarget
    case checkForUpdates
    case editMenuBar
    case quit

    /// Settings and Quit are the two a trimmed menu must keep: without them
    /// a person who hid everything else would have no way back into the app
    /// and no way out of it.
    public var isAlwaysShown: Bool { self == .settings || self == .quit }

    /// Rows that open a submenu rather than acting. They move and hide as
    /// one row; what is inside them is not the editor's to arrange.
    public var hasSubmenu: Bool { self == .animation || self == .revealTarget }
}

public enum ChevronMenuSlot: Equatable, Sendable {
    case entry(ChevronMenuEntry)
    case separator

    /// The persisted form. No entry is called "separator", so the sentinel
    /// cannot collide (`separatorTokenIsNotAnEntry` holds it to that).
    public static let separatorToken = "separator"

    var token: String {
        switch self {
        case .entry(let entry): entry.rawValue
        case .separator: Self.separatorToken
        }
    }

    init?(token: String) {
        if token == Self.separatorToken {
            self = .separator
        } else if let entry = ChevronMenuEntry(rawValue: token) {
            self = .entry(entry)
        } else {
            return nil
        }
    }

    var entry: ChevronMenuEntry? {
        if case .entry(let entry) = self { return entry }
        return nil
    }
}

public struct ChevronMenu: Codable, Equatable, Sendable {
    /// Every row the menu knows, separators included, in the order they are
    /// drawn. Hidden rows stay in it so unticking and ticking again puts a
    /// row back where it was.
    public var order: [ChevronMenuSlot]
    /// Rows the user unticked. `isAlwaysShown` entries in here are ignored.
    public var hidden: Set<ChevronMenuEntry>

    /// The menu as it shipped before it could be edited, plus the two rows
    /// that were only ever reachable elsewhere, off. A new option's default
    /// reproduces what already shipped.
    public static let standardOrder: [ChevronMenuSlot] = [
        .entry(.search), .entry(.settings),
        .separator,
        .entry(.toggle), .entry(.showAll),
        .separator,
        .entry(.animation), .entry(.revealTarget), .entry(.checkForUpdates), .entry(.editMenuBar),
        .separator,
        .entry(.quit),
    ]
    public static let standardHidden: Set<ChevronMenuEntry> = [.checkForUpdates, .editMenuBar]

    public init(order: [ChevronMenuSlot] = ChevronMenu.standardOrder,
                hidden: Set<ChevronMenuEntry> = ChevronMenu.standardHidden) {
        self.order = order
        self.hidden = hidden
    }

    public func isHidden(_ entry: ChevronMenuEntry) -> Bool {
        !entry.isAlwaysShown && hidden.contains(entry)
    }

    /// Per slot of `order`, whether the menu actually draws it. An entry is
    /// drawn unless it is hidden; a separator is drawn only with a drawn
    /// entry before it and another after it.
    public var drawnFlags: [Bool] {
        var flags = [Bool](repeating: false, count: order.count)
        var openAfterEntry = false
        var pending: Int?
        for (index, slot) in order.enumerated() {
            switch slot {
            case .entry(let entry):
                guard !isHidden(entry) else { continue }
                if let separator = pending {
                    flags[separator] = true
                    pending = nil
                }
                flags[index] = true
                openAfterEntry = true
            case .separator:
                // Only the first separator after a drawn entry can survive;
                // the ones behind it have nothing to divide. A separator
                // still pending at the end was a trailing one, so it stays
                // false.
                if openAfterEntry {
                    pending = index
                    openAfterEntry = false
                }
            }
        }
        return flags
    }

    /// The rows to build the menu from.
    public var drawn: [ChevronMenuSlot] {
        zip(order, drawnFlags).compactMap { $1 ? $0 : nil }
    }

    /// The order with the row at `from` moved onto the row at `to`: it
    /// takes that row's place and pushes it along, which is what dropping
    /// one row on another reads as. Without this the index left over after
    /// the removal lands a downward drag one row further than the row it
    /// was dropped on.
    public func moving(from: Int, to: Int) -> ChevronMenu {
        guard from != to, order.indices.contains(from), order.indices.contains(to) else { return self }
        var moved = self
        let slot = moved.order.remove(at: from)
        moved.order.insert(slot, at: from < to ? to - 1 : to)
        return moved
    }

    /// Drops rows this build doesn't know, keeps the first of any repeat,
    /// adds entries added since the blob was written, and never lets
    /// Settings or Quit stay hidden. Run on decode and after every edit, so
    /// nothing downstream has to defend against a malformed order.
    public func normalized() -> ChevronMenu {
        // Nothing to trust: a fresh install, or a blob from before this
        // setting. The standard menu, never an empty one.
        guard !order.isEmpty else {
            return ChevronMenu(
                order: Self.standardOrder,
                hidden: hidden.isEmpty ? Self.standardHidden : hidden.filter { !$0.isAlwaysShown }
            )
        }
        var seen = Set<ChevronMenuEntry>()
        var slots: [ChevronMenuSlot] = []
        for slot in order {
            switch slot {
            case .entry(let entry):
                guard seen.insert(entry).inserted else { continue }
                slots.append(slot)
            case .separator:
                slots.append(slot)
            }
        }
        // An entry this build knows and the blob doesn't is new: it joins
        // before the last separator, so ticking it puts it with the group
        // above Quit rather than under it.
        let missing = ChevronMenuEntry.allCases.filter { !seen.contains($0) }
        if !missing.isEmpty {
            let insertion = slots.lastIndex(of: .separator) ?? slots.endIndex
            slots.insert(contentsOf: missing.map(ChevronMenuSlot.entry), at: insertion)
        }
        return ChevronMenu(
            order: slots,
            hidden: hidden.filter { !$0.isAlwaysShown }
                .union(missing.filter(Self.standardHidden.contains))
        )
    }

    // MARK: - Persistence

    private enum CodingKeys: String, CodingKey { case order, hidden }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let tokens = c.field([String].self, .order, [])
        let hiddenTokens = c.field([String].self, .hidden, [])
        let decoded = ChevronMenu(
            order: tokens.compactMap(ChevronMenuSlot.init(token:)),
            hidden: Set(hiddenTokens.compactMap(ChevronMenuEntry.init(rawValue:)))
        )
        // An empty or unreadable order is a fresh install or a blob from
        // before this setting: the standard menu, not an empty one.
        self = tokens.isEmpty ? ChevronMenu() : decoded.normalized()
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(order.map(\.token), forKey: .order)
        try c.encode(hidden.map(\.rawValue).sorted(), forKey: .hidden)
    }
}
