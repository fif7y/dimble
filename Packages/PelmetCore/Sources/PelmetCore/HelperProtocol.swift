// HelperProtocol.swift
// The wire between the main app and a section helper (docs/HELPER-PROCESS-
// PLAN.md). A helper hosts NSStatusItems and nothing else: it is told the
// full list to host (idempotent `sync`) and reports what the user did.

import Foundation

/// One status item a helper should host.
public struct HostedItem: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case separator
        case launcher
        case extra
    }

    /// The Pelmet-minted title (`SeparatorSpec.itemTitle` …): identity on
    /// both sides, the AX title, and the autosave name.
    public var title: String
    public var kind: Kind
    /// Button text (separator glyph) — empty for image items.
    public var text: String
    /// Fixed length in points; nil = variable.
    public var length: Double?
    public var alpha: Double
    /// PNG for image items (launcher / extra glyph), nil for text items.
    public var imagePNG: Data?
    public var imageIsTemplate: Bool
    public var removable: Bool

    public init(
        title: String, kind: Kind, text: String = "", length: Double? = nil,
        alpha: Double = 1, imagePNG: Data? = nil, imageIsTemplate: Bool = true,
        removable: Bool = true
    ) {
        self.title = title
        self.kind = kind
        self.text = text
        self.length = length
        self.alpha = alpha
        self.imagePNG = imagePNG
        self.imageIsTemplate = imageIsTemplate
        self.removable = removable
    }
}

/// Main → helper.
public enum HelperCommand: Codable, Sendable {
    /// The complete list; the helper diffs against what it hosts.
    case sync([HostedItem])
    case quit

    public var isValid: Bool {
        switch self {
        case .quit: return true
        case .sync(let items):
            return items.count <= 256 && Set(items.map(\.title)).count == items.count
                && items.allSatisfy {
                    !$0.title.isEmpty && $0.title.utf8.count <= 256 && $0.text.utf8.count <= 1024
                        && $0.alpha.isFinite && (0...1).contains($0.alpha)
                        && ($0.length.map { $0.isFinite && (0...1024).contains($0) } ?? true)
                        && ($0.imagePNG?.count ?? 0) <= 256 * 1024
                }
        }
    }
}

/// Helper → main.
public enum HelperEvent: Codable, Sendable {
    /// The helper is listening and hosting nothing yet.
    case ready(bundle: String)
    /// A hosted item is registered with the bar.
    case hosted(bundle: String, title: String)
    case clicked(bundle: String, title: String, rightButton: Bool, x: Double, y: Double)
    /// The user ⌘-dragged the item off the bar; the helper already unhosted it.
    case draggedOff(bundle: String, title: String)

    public var isValid: Bool {
        func validName(_ value: String) -> Bool { !value.isEmpty && value.utf8.count <= 256 }
        switch self {
        case .ready(let bundle):
            return validName(bundle)
        case .hosted(let bundle, let title), .draggedOff(let bundle, let title):
            return validName(bundle) && validName(title)
        case .clicked(let bundle, let title, _, let x, let y):
            return validName(bundle) && validName(title) && x.isFinite && y.isFinite
        }
    }
}

public enum HelperWire {
    public static let maximumMessageBytes = 4 * 1024 * 1024

    public static func encode<T: Encodable>(_ value: T) -> Data? {
        guard let data = try? JSONEncoder().encode(value), data.count <= maximumMessageBytes else { return nil }
        return data
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) -> T? {
        guard data.count <= maximumMessageBytes else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
