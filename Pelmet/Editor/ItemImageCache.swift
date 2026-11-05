// ItemImageCache.swift
// Icon resolution for the layout editor: the owning app's icon for
// third-party items, the system symbol for Apple items, and Pelmet's own
// rendered glyphs for its items. (Live bar-glyph capture existed once —
// SCK crops of the shared "Menubar" window — but proved unfixable: faded
// captures from an inactive bar, notch-occluded garbage, tag-drift misses.
// Removed 2026-08-21 in favor of app icons only.)

import AppKit
import PelmetCore
import PelmetEngine

@MainActor
enum ItemImageCache {
    private static var appIcons: [String: NSImage] = [:]

    private static var pelmetItemSymbols: [String: String] = [:]
    private static var pelmetItemImages: [String: NSImage] = [:]

    /// ExtrasManager registers each Pelmet item's SF Symbol by item title.
    static func registerPelmetItem(title: String, symbol: String) {
        pelmetItemSymbols[title] = symbol
    }

    /// Direct image registration for Pelmet items whose glyph is not an SF
    /// Symbol (separators render their text glyph).
    static func registerPelmetItem(title: String, image: NSImage) {
        pelmetItemImages[title] = image
    }

    /// Back to the symbol registration (a media button switched to static).
    static func unregisterPelmetItemImage(title: String) {
        pelmetItemImages.removeValue(forKey: title)
    }

    static func icon(for item: ItemID) -> NSImage? {
        if item.bundleID == PelmetBundle.textInputAgentID {
            return InputSourcePresentation.shared.icon
        }
        if let image = pelmetItemImages.first(where: { item.rawValue.hasSuffix($0.key) })?.value {
            return image
        }
        if let symbol = pelmetItemSymbols.first(where: { item.rawValue.hasSuffix($0.key) })?.value {
            return NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        }
        if let bundleID = item.bundleID {
            if bundleID == PelmetBundle.agentID {
                return systemSymbol(for: item)
            }
            if let cached = appIcons[bundleID] {
                return cached
            }
            // Copy before sizing: `NSRunningApplication.icon` hands back the
            // app's own image, and setting `size` on it mutates what every
            // other AppKit consumer of that instance draws.
            guard let icon = NSRunningApplication
                .runningApplications(withBundleIdentifier: bundleID).first?.icon,
                let sized = icon.copy() as? NSImage
            else { return nil }
            sized.size = NSSize(width: 20, height: 20)
            appIcons[bundleID] = sized
            return sized
        }
        return nil
    }

    /// com.apple.menuextra.* → the SF Symbol the real item draws.
    private static func systemSymbol(for item: ItemID) -> NSImage? {
        let id = item.rawValue
        if id.hasSuffix("menuextra.bluetooth"), let bluetoothIcon { return bluetoothIcon }
        // Marks our own extras already draw: Apple's Siri menu icon read from
        // Siri.bundle, and the drawn AirDrop mark (no symbol on 27.2).
        if id.hasSuffix("menuextra.siri") { return ExtraGlyph.siri.copy() as? NSImage }
        if id.hasSuffix("menuextra.airdrop") { return ExtraGlyph.airdrop.copy() as? NSImage }
        let symbol: String
        if id.contains("wifi") { symbol = "wifi" }
        else if id.contains("battery") { symbol = "battery.75percent" }
        else if id.contains("screen-mirroring") { symbol = "rectangle.on.rectangle" }
        else if id.contains("clock") { symbol = "clock" }
        else if id.contains("audiovideo") { symbol = "video" }
        else if id.contains("controlcenter") { symbol = "switch.2" }
        else if id.contains("sound") { symbol = "speaker.wave.2" }
        // Unmapped, Display stood in as a dashed circle on the panel (#26).
        else if id.hasSuffix("menuextra.display") { symbol = "display" }
        else if id.hasSuffix("menuextra.user") { symbol = "person.crop.circle" }
        else if id.hasSuffix("menuextra.now-playing") { symbol = "play.fill" }
        else if id.hasSuffix("menuextra.focusmode") { symbol = "moon.fill" }
        // Two more that fell through to the dashed circle (#26): Time
        // Machine draws the symbol our replica draws, VPN a shield.
        else if id.hasSuffix("menuextra.TimeMachine") { symbol = ExtraGlyph.timeMachineSymbol }
        else if id.hasSuffix("menuextra.vpn") { symbol = resolving("network.badge.shield.half.filled", else: "lock.shield") }
        else { symbol = "circle.dashed" }
        return NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: "circle.dashed", accessibilityDescription: nil)
    }

    /// `name` when this macOS has that symbol, else `fallback`.
    private static func resolving(_ name: String, else fallback: String) -> String {
        NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil ? name : fallback
    }

    /// An icon macOS ships for the file at `path`, read at run time like any
    /// app's icon (nothing shipped), copied before sizing so the shared
    /// image is left alone. Nil when the file is not on this Mac.
    private static func systemIcon(atPath path: String) -> NSImage? {
        guard FileManager.default.fileExists(atPath: path),
              let sized = NSWorkspace.shared.icon(forFile: path).copy() as? NSImage
        else { return nil }
        sized.size = NSSize(width: 20, height: 20)
        return sized
    }

    /// No public symbol draws Bluetooth ("bluetooth" was nil, and the panel
    /// drew a dashed app, #26): System Settings' own Bluetooth icon, read
    /// from macOS at run time like any app's icon, nothing shipped.
    private static let bluetoothIcon = systemIcon(atPath: "/System/Library/ExtensionKit/Extensions/Bluetooth.appex")
}
