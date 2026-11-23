// ItemStandIn.swift
// What a tile draws for an item before a picture of it lands, the editor's
// chain (`TileGlyph`): SystemUIServer's pinned pair hands over a blank
// rounded square, so Apple's own mark stands in for it (#19); every other
// item gets its icon.

import AppKit
import PelmetCore

enum ItemStandIn {
    /// Nil when there is no icon to show.
    static func image(for id: ItemID) -> NSImage? {
        if id.bundleID == PelmetBundle.systemUIServerID {
            // Keyed on the enumerator's un-localized title ("Siri, TimeMachine").
            var rawTitle = ""
            if case .status(_, let title) = id.parsed { rawTitle = title }
            return ExtraGlyph.pinnedAppleExtra(rawTitle: rawTitle)
        }
        return ItemImageCache.icon(for: id)
    }

    /// Whether the stand-in is the item's own mark (Apple's symbol for a
    /// system item, the glyph of one of Pelmet's own) and not its app's
    /// icon, which every item of that app would share.
    static func isTheItemsOwnMark(_ id: ItemID) -> Bool {
        guard let bundle = id.bundleID else { return false }
        return PelmetBundle.ownIDs.contains(bundle)
            || [PelmetBundle.agentID, PelmetBundle.textInputAgentID, PelmetBundle.systemUIServerID].contains(bundle)
    }
}
