// LayoutRestore.swift
// Set Menu Bar Layout (#169): a layout Get Menu Bar Layout handed out, or
// one written by hand, turned into the order each section should have.
// Pure: the app draws the plan with the editor's own moves and applies it
// once.
//
// What a layout can't name stays put: an icon it leaves out keeps its
// section, after the ones it lists. An icon it names that isn't in this bar
// (an app not running, another Mac's) is reported, not an error. A
// separator it names that isn't here takes a separator of this bar, in the
// same section, that the layout doesn't name; only when none is left is
// one made: a layout
// carries its separators to another Mac, and running it again makes none.
// The ones macOS pins never move.

import Foundation

public enum LayoutRestore {
    /// A layout is a few dozen icons: anything far past that isn't one.
    public static let maxLength = 256 * 1024
    public static let maxItems = 1000
    /// More separators than this in one go is a mistake, not a layout.
    public static let maxNewSeparators = 20

    public enum Failure: Error, Equatable, Sendable {
        /// Not JSON, or not shaped like a layout.
        case notALayout
        /// Written by a newer Dimble, whose keys may mean something else.
        case newerFormat(Int)
    }

    /// One item the layout lists. Get Menu Bar Layout writes `id`, `name`,
    /// `kind` and `bundleID`; by hand, an `id` or a `name` is enough.
    public struct Entry: Equatable, Sendable {
        public var id: String?
        public var name: String?
        public var isSeparator: Bool

        public init(id: String?, name: String?, isSeparator: Bool = false) {
            self.id = id
            self.name = name
            self.isSeparator = isSeparator
        }

        /// For the log and the action's report.
        public var label: String { name ?? id ?? "?" }
    }

    public struct Layout: Equatable, Sendable {
        public var sections: [(Section, [Entry])]

        public init(sections: [(Section, [Entry])]) {
            self.sections = sections
        }

        public static func == (a: Layout, b: Layout) -> Bool {
            a.sections.map(\.0) == b.sections.map(\.0) && a.sections.map(\.1) == b.sections.map(\.1)
        }
    }

    /// An icon on this bar, as the editor shows it.
    public struct BoardItem: Equatable, Sendable {
        public var key: ItemID
        public var name: String

        public init(key: ItemID, name: String) {
            self.key = key
            self.name = name
        }
    }

    public enum Slot: Equatable, Sendable {
        case item(ItemID)
        /// A separator the layout has and this bar doesn't: made here.
        case newSeparator
    }

    public struct Plan: Equatable, Sendable {
        /// Each section's order, left to right. A section absent keeps its own.
        public var order: [Section: [Slot]]
        /// What the layout lists that this bar doesn't have.
        public var missing: [Entry]

        public var newSeparators: Int {
            order.values.reduce(0) { $0 + $1.filter { $0 == .newSeparator }.count }
        }
    }

    // MARK: - Reading

    private struct RawItem: Decodable {
        var id: String?
        var name: String?
        var kind: String?
    }

    private struct RawSection: Decodable {
        var section: String
        var items: [RawItem]
    }

    private struct RawLayout: Decodable {
        var format: Int?
        var sections: [RawSection]
    }

    public static func read(_ text: String) throws -> Layout {
        guard text.utf8.count <= maxLength,
              let raw = try? JSONDecoder().decode(RawLayout.self, from: Data(text.utf8))
        else { throw Failure.notALayout }
        if let format = raw.format, format > 1 { throw Failure.newerFormat(format) }
        guard !raw.sections.isEmpty,
              raw.sections.reduce(0, { $0 + $1.items.count }) <= maxItems
        else { throw Failure.notALayout }
        var sections: [(Section, [Entry])] = []
        for rawSection in raw.sections {
            guard let section = AutomationLink.section(named: rawSection.section) else { throw Failure.notALayout }
            let entries = rawSection.items.compactMap { item -> Entry? in
                let id = item.id.flatMap(clean)
                let name = item.name.flatMap(clean)
                guard id != nil || name != nil else { return nil }
                let separator = item.kind?.lowercased() == "separator"
                    || id.map { ItemID(rawValue: $0).isPelmetSeparator } ?? false
                return Entry(id: id, name: name, isSeparator: separator)
            }
            sections.append((section, entries))
        }
        return Layout(sections: sections)
    }

    private static func clean(_ text: String) -> String? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    // MARK: - Planning

    /// `board`: each section's icons as the editor has them. `movable`:
    /// false for the icons macOS pins, which keep their place.
    public static func plan(_ layout: Layout, board: [Section: [BoardItem]], movable: (ItemID) -> Bool) -> Plan {
        let everything = Section.allCases.flatMap { board[$0] ?? [] }
        let onBoard = Set(everything.map(\.key))
        var placed: Set<ItemID> = []
        var order: [Section: [Slot]] = [:]
        var missing: [Entry] = []

        // This bar's separators the layout doesn't name by id: the ones a
        // separator it names from elsewhere takes, in order.
        let named = Set(layout.sections.flatMap { $0.1.compactMap { $0.id.map(ItemID.init(rawValue:)) } })
        var spare: [Section: [ItemID]] = [:]
        for section in Section.allCases {
            spare[section] = (board[section] ?? []).map(\.key).filter { $0.isPelmetSeparator && !named.contains($0) && movable($0) }
        }
        func takeSpare(in section: Section) -> ItemID? {
            while let key = spare[section]?.first {
                spare[section]?.removeFirst()
                if !placed.contains(key) { return key }
            }
            return nil
        }
        var made = 0

        func find(_ entry: Entry) -> ItemID? {
            if let id = entry.id, onBoard.contains(ItemID(rawValue: id)) { return ItemID(rawValue: id) }
            // A separator is its id: their names are all the same.
            guard !entry.isSeparator, let name = entry.name else { return nil }
            let loose: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
            let named = everything.filter { $0.name.compare(name, options: loose) == .orderedSame }
            return named.count == 1 ? named[0].key : nil
        }

        for (section, entries) in layout.sections {
            for entry in entries {
                if let key = find(entry) {
                    // Listed twice: the first place wins.
                    guard !placed.contains(key), movable(key) else { continue }
                    placed.insert(key)
                    order[section, default: []].append(.item(key))
                } else if entry.isSeparator, let key = takeSpare(in: section) {
                    placed.insert(key)
                    order[section, default: []].append(.item(key))
                } else if entry.isSeparator, made < maxNewSeparators {
                    made += 1
                    order[section, default: []].append(.newSeparator)
                } else {
                    missing.append(entry)
                }
            }
        }
        // The rest stay in their section, after what the layout put there.
        for section in Section.allCases {
            for item in board[section] ?? [] where !placed.contains(item.key) && movable(item.key) {
                placed.insert(item.key)
                order[section, default: []].append(.item(item.key))
            }
        }
        return Plan(order: order, missing: missing)
    }

    /// A section's stored order with `drawn` laid in it. What the plan can't
    /// draw keeps its place: an app not running stays after the icon it stood
    /// after, and the ones macOS pins stay at the end. Drawn one move at a
    /// time, the same layout set again left every quit app's icon at its
    /// section's left end. `elsewhere`: keys drawn in another section.
    public static func laid(_ drawn: [ItemID], over stored: [ItemID], elsewhere: Set<ItemID>) -> [ItemID] {
        let here = Set(drawn)
        let lastDrawn = stored.lastIndex(where: here.contains) ?? -1
        var order = drawn
        var anchor: ItemID?
        for (index, key) in stored.enumerated() where !elsewhere.contains(key) {
            if here.contains(key) {
                anchor = key
            } else if index > lastDrawn {
                order.append(key)
            } else {
                let after = anchor.flatMap { order.firstIndex(of: $0) }
                order.insert(key, at: after.map { $0 + 1 } ?? 0)
                anchor = key
            }
        }
        return order
    }
}
