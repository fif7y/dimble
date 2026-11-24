// EditorItemsBuilder.swift
// Pure derivation of the layout editor's board for one section — extracted
// from AppState so the twin collapse, stand-in synthesis, and ordering rules
// are unit-testable. App lookups (running apps) are injected closures; the
// AppState shim memoizes them per call.

import Foundation
import PelmetCore
import PelmetEngine

enum EditorItemsBuilder {
    /// Items the layout editor shows for a section: third-party only (Apple
    /// items are out of scope), Pelmet's own items excluded, and CONCEALED items
    /// included — they drop out of AX observation but absolutely belong in the
    /// editor (frame nil, icon from the app bundle).
    static func build(
        section: PelmetCore.Section,
        snapshotItems: [ObservedItem],
        concealed: Set<ItemID>,
        extraItems: [ExtraItemSpec],
        separators: [SeparatorSpec],
        model: SectionModel,
        pelmetBundleID: String,
        isRunning: (String) -> Bool,
        appName: (String) -> String?,
        recentlySeen: (ItemID) -> Bool = { _ in true },
        destroyed: Set<ItemID> = [],
        drawnNow: (ItemID) -> Bool = { _ in true }
    ) -> [ObservedItem] {
        var byID: [ItemID: ObservedItem] = [:]
        // An own item hosted by a section helper is observed under the
        // helper's bundle; the board keys it as the main-app item its spec
        // names (sectionKey folds it), or the spec loops below would draw a
        // second, frameless tile beside it.
        func canonical(_ id: ItemID) -> ItemID {
            id.bundleID.map(PelmetBundle.helperIDs.contains) == true ? id.sectionKey : id
        }
        let ownSpecIDs = Set(
            separators.map { SeparatorManager.itemID(for: $0).sectionKey }
                + extraItems.map { ExtrasManager.itemID(for: $0).sectionKey }
        )
        // A separator or extra of Pelmet's with no spec is removed: the spec
        // is the item's existence, not the engine's memory of it.
        func isRemoved(_ id: ItemID) -> Bool {
            id.bundleID == pelmetBundleID && MenuBarPolicy.isPelmetExtraID(id) && !ownSpecIDs.contains(id.sectionKey)
        }
        for item in snapshotItems {
            let id = canonical(item.id)
            // The walk lists a removed separator until the next one: a new
            // one was filed in front of it (#169, 2026-11-24).
            if isRemoved(id) { continue }
            byID[id] = id == item.id ? item : ObservedItem(
                id: id, frame: item.frame, appName: item.appName,
                hostIsBundleless: item.hostIsBundleless, pid: item.pid
            )
        }
        // The engine's concealed set is "as of the last converge" — an app that
        // quits while concealed (or while a reveal keeps converge quiet) stays
        // in it, and without the running check its stand-in tile outlived the
        // app in the editor (Bitwarden quit, 2026-08-31). Same guard as the
        // stored path below; nil-bundle IDs stay (system modules filter later).
        for raw in concealed {
            let id = canonical(raw)
            guard byID[id] == nil else { continue }
            if let bundle = id.bundleID, bundle != pelmetBundleID, !isRunning(bundle) { continue }
            // Pelmet's bundle is exempt from the running check, so a
            // separator or extra removed while concealed would keep its
            // stand-in until the engine's carried set caught up.
            if isRemoved(id) { continue }
            byID[id] = ObservedItem(id: id, frame: nil, appName: id.bundleID.flatMap(appName))
        }
        // Pelmet's extras are section-manageable (visibility-based hiding); when
        // hidden they're absent from AX, so ensure they're represented. Live
        // ones arrive named after their host ("Dimble") — the spec's own name
        // (the shortcut, the app stood in for) is what the tile should say.
        for spec in extraItems {
            let id = ExtrasManager.itemID(for: spec)
            let name = spec.shortcutName ?? spec.appName
            if let live = byID[id] {
                if let name, live.appName != name {
                    byID[id] = ObservedItem(id: id, frame: live.frame, appName: name, hostIsBundleless: live.hostIsBundleless)
                }
            } else {
                byID[id] = ObservedItem(id: id, frame: nil, appName: name)
            }
        }
        // Separators too — same visibility-based hiding as extras.
        for spec in separators {
            let id = SeparatorManager.itemID(for: spec)
            if byID[id] == nil {
                byID[id] = ObservedItem(id: id, frame: nil, appName: "Separator")
            }
        }
        // Model members that are momentarily neither observable nor in the
        // engine's concealed set (mid-reveal AX latency, mid-conceal swap)
        // still belong on the board — without this the section flashed empty
        // on every tab revisit. Quit apps stay off (bundle not running), and
        // so does anything not seen recently: a host that is running but has
        // no registration at all (the input menu switched off in System
        // Settings while its agent keeps running, 2026-09-10) is not in a
        // gap, it has no icon, and its stored assignment must not draw one.
        let stored = Set(
            model.assignments.filter { $0.value == section }.map(\.key)
        ).union(model.order[section] ?? [])
        // A canonical identity already represented (live item or concealed
        // stand-in under a title-variant id) must not gain a sectionKey twin —
        // the collapse below would pick a dictionary-order winner.
        let representedKeys = Set(byID.keys.map(\.sectionKey))
        for id in stored where byID[id] == nil && !representedKeys.contains(id.sectionKey) {
            guard let bundle = id.bundleID,
                  bundle != pelmetBundleID,
                  MenuBarPolicy.isSectionManageable(id),
                  isRunning(bundle),
                  recentlySeen(id)
            else { continue }
            byID[id] = ObservedItem(id: id, frame: nil, appName: appName(bundle))
        }
        // Icons the bar destroyed although the allowlist protects them (#30,
        // see CollateralTracker). They are usually unassigned, so `stored`
        // never held them, and Pelmet never asked to conceal them, so the
        // concealed loop skipped them too — with no AX frame either they
        // belonged to no branch at all and the board simply lost them
        // (iStat Menus appeared under neither Visible nor Hidden).
        for id in destroyed where byID[id] == nil && !representedKeys.contains(id.sectionKey) {
            guard let bundle = id.bundleID,
                  bundle != pelmetBundleID,
                  isRunning(bundle)
            else { continue }
            byID[id] = ObservedItem(id: id, frame: nil, appName: appName(bundle))
        }
        // Drop stale twins the concealed set may still remember: a bundle is
        // never half-concealed, so a frame-nil entry whose bundle has a live
        // item is an old alias, not a second icon. (Pelmet's own extras are
        // exempt — they legitimately mix live and hidden items.)
        // Apple's item hosts are exempt too: their items hide one by one, so
        // a concealed Sound next to a live Wi-Fi is not an alias (the tile
        // vanished from Hidden whenever the bar was collapsed, 2026-09-20).
        let liveBundles = Set(
            snapshotItems.compactMap(\.id.bundleID)
        ).subtracting(MenuBarPolicy.identityExemptBundles(pelmetBundleID: pelmetBundleID))
        // Two frame-nil twins of one bundle (both "concealed") are one item
        // under a drifted tag plus its stale alias — the engine can't prune
        // the alias until the item is next observed live, so collapse here.
        let concealedTwinLoser = ItemIdentityResolver.concealedTwinLosers(
            concealedIDs: byID.values.filter { $0.frame == nil }.map(\.id),
            exemptBundles: MenuBarPolicy.identityExemptBundles(pelmetBundleID: pelmetBundleID),
            isAssigned: { model.assignments[$0.sectionKey] != nil }
        )
        let all = byID.values.filter { item in
            if concealedTwinLoser.contains(item.id) { return false }
            if item.frame == nil,
               let bundle = item.id.bundleID,
               liveBundles.contains(bundle) {
                return false
            }
            guard !item.id.isSystemModule,
                  model.section(of: item.id) == section
            else { return false }
            if item.id.bundleID == pelmetBundleID {
                return MenuBarPolicy.isPelmetExtraID(item.id)
            }
            // Core system icons the assertion can individually control
            // (Sound, battery, Wi-Fi…) and SystemUIServer's extras (hidden
            // as one bundle) are manageable; the rest of Apple's stay out.
            return MenuBarPolicy.isSectionManageable(item.id)
        }
        // One tile per canonical identity: title-variant twins collapse. The
        // representative is the leftmost live-framed item (placement measures
        // against it), falling back to a concealed stand-in.
        var byKey: [ItemID: ObservedItem] = [:]
        for item in all {
            let key = item.id.sectionKey
            guard let existing = byKey[key] else {
                byKey[key] = item
                continue
            }
            switch (existing.frame, item.frame) {
            case (nil, .some): byKey[key] = item
            case let (e?, i?) where i.minX < e.minX: byKey[key] = item
            default: break
            }
        }
        let explicit = model.order[section] ?? []
        // Icons behind the native « report overlapping phantom frames at
        // its left edge; sorted by x they jump to the front of the section
        // (Pure Paste / Unclutter after a Discard, 13:47 2026-09-21). They
        // sort as unframed instead: explicit order, then the stable tiebreak.
        // A frame the bar no longer draws (`AppState.drawnNow`) never makes
        // a drawn one read as trapped.
        let framed = byKey.values.filter { $0.frame != nil }
        let trapped = Set(
            PlacementGeometry.overflowTrapped(framed.map { $0.frame! }, drawn: framed.map { drawnNow($0.id) })
                .map { framed[$0].id.sectionKey }
        )
        return byKey.values.sorted { lhs, rhs in
            // The user's explicit order is authoritative — nothing outranks it.
            // (A left-pin experiment for extras once did, and it broke drag
            // ordering and Tidy alike.) Order arrays hold canonical keys.
            let li = explicit.firstIndex(of: lhs.id.sectionKey) ?? Int.max
            let ri = explicit.firstIndex(of: rhs.id.sectionKey) ?? Int.max
            if li != ri { return li < ri }
            let lx = trapped.contains(lhs.id.sectionKey) ? .greatestFiniteMagnitude : lhs.frame?.minX ?? .greatestFiniteMagnitude
            let rx = trapped.contains(rhs.id.sectionKey) ? .greatestFiniteMagnitude : rhs.frame?.minX ?? .greatestFiniteMagnitude
            if lx != rx { return lx < rx }
            // Neither ordered nor on screen: a stable tiebreak, or the board
            // reshuffles on every rebuild (dictionary order).
            return lhs.id.rawValue < rhs.id.rawValue
        }
    }
}
