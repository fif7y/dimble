// LayoutExport.swift
// What the Get Layout action hands out (#169): each section with its icons
// in order, left to right, as Settings › Menu Bar shows them. Keys are
// sorted so a copy kept in a dotfiles repo only changes where the bar did.

import Foundation

public struct LayoutExport: Codable, Equatable, Sendable {
    public struct Item: Codable, Equatable, Sendable {
        public enum Kind: String, Codable, Sendable {
            /// An app's icon.
            case app
            /// One of Apple's (Wi-Fi, Battery, Siri…).
            case apple
            /// One Dimble draws (Media, Focus, a shortcut…).
            case dimble
            case separator
        }

        /// What Settings and Search call it.
        public var name: String
        /// The identity Dimble files it under, for a later action to name it by.
        public var id: String
        public var bundleID: String?
        public var kind: Kind

        public init(name: String, id: ItemID) {
            self.name = name
            self.id = id.rawValue
            kind = Self.kind(of: id)
            // Dimble's own items: the host is an implementation detail.
            bundleID = kind == .app || kind == .apple ? id.bundleID : nil
        }

        static func kind(of id: ItemID) -> Kind {
            if id.isPelmetSeparator { return .separator }
            guard let bundle = id.bundleID else { return .apple }
            if PelmetBundle.ownIDs.contains(bundle) || bundle == PelmetBundle.mainID { return .dimble }
            return bundle.hasPrefix("com.apple.") ? .apple : .app
        }
    }

    public struct SectionItems: Codable, Equatable, Sendable {
        public var section: Section
        public var items: [Item]

        public init(section: Section, items: [Item]) {
            self.section = section
            self.items = items
        }
    }

    /// Goes up if a key changes meaning, so an import can tell.
    public var format = 1
    public var sections: [SectionItems]

    public init(sections: [SectionItems]) {
        self.sections = sections
    }

    public func json() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(self) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}
