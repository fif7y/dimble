// SeparatorManager.swift
// User-created separator/spacer items (Spaced-style). Plain NSStatusItems with
// stable autosave names — natively ⌘-draggable, right-click opens Pelmet's menu
// (an always-available settings entry point in iconless mode).
//
// Visible-section separators live here as plain NSStatusItems. Hidden and
// always-hidden ones are hosted by the section helpers (HelperHosts), whose
// bundle the assertion excludes — so they hide and reveal natively. The
// fader/width-collapse path below only ever runs for main-hosted items
// during a section change (docs/HELPER-PROCESS-PLAN.md).

import AppKit
import PelmetCore
import PelmetEngine

@MainActor
final class SeparatorManager {
    private var items: [UUID: NSStatusItem] = [:]
    private var specsByID: [UUID: SeparatorSpec] = [:]
    private var lastVisible: [UUID: Bool] = [:]
    private var removalObservations: [UUID: NSKeyValueObservation] = [:]
    private weak var appState: AppState?
    /// Where each separator is physically hosted. Under the sets core an
    /// editor move only redraws the tile; the host follows at Apply
    /// (`rehostToModel`), because a re-host is a fresh registration that
    /// lands wherever the agent puts it and reflows the bar at once (a Dot
    /// moved between sections jumped and blinked without Apply, 2026-09-20).
    private var hostedSection: [UUID: PelmetCore.Section] = [:]

    /// A separator drawn in a section other than the one hosting it.
    var needsRehost: Bool {
        guard let model = appState?.settings.sectionModel else { return false }
        return specsByID.values.contains { hostedSection[$0.id] != model.section(of: Self.itemID(for: $0)) }
    }

    /// Apply: move every separator's host to its drawn section. Returns
    /// whether anything re-hosted (the caller waits for the registration).
    func rehostToModel() -> Bool {
        guard needsRehost, let specs = appState?.settings.separators else { return false }
        hostedSection.removeAll()
        sync(with: specs)
        return true
    }

    init(appState: AppState) {
        self.appState = appState
    }

    static func itemID(for spec: SeparatorSpec) -> ItemID {
        .status(
            bundle: PelmetBundle.mainID,
            title: spec.itemTitle
        )
    }

    var managedItemIDs: [ItemID] {
        specsByID.values.map { Self.itemID(for: $0) }
    }

    /// Attached ahead of an uncovered swap (see `preattach`).
    private var preattached: Set<UUID> = []

    func sync(with specs: [SeparatorSpec]) {
        let model = appState?.settings.sectionModel ?? SectionModel()
        var helperItems: [PelmetCore.Section: [HostedItem]] = [.hidden: [], .alwaysHidden: []]
        var mainSpecs: [SeparatorSpec] = []
        for spec in specs {
            let drawn = model.section(of: Self.itemID(for: spec))
            let section = hostedSection[spec.id] ?? drawn
            hostedSection[spec.id] = section
            if section == .visible {
                mainSpecs.append(spec)
            } else {
                helperItems[section, default: []].append(Self.hostedItem(for: spec))
            }
            specsByID[spec.id] = spec
            ItemImageCache.registerPelmetItem(
                title: spec.itemTitle,
                image: Self.glyphImage(for: spec.style)
            )
        }
        let stale = Set(specsByID.keys).subtracting(specs.map(\.id))
        for id in stale {
            specsByID.removeValue(forKey: id)
            hostedSection.removeValue(forKey: id)
        }
        for (section, hosted) in helperItems {
            appState?.helperHosts?.set(hosted, for: section, source: "separators")
        }
        syncMainHosted(mainSpecs)
    }

    /// What a helper draws for a separator.
    static func hostedItem(for spec: SeparatorSpec) -> HostedItem {
        HostedItem(
            title: spec.itemTitle,
            kind: .separator,
            text: spec.style == .space ? "" : spec.style.rawValue,
            length: spec.style == .space ? spec.width : nil,
            alpha: spec.style == .space ? 0 : spec.opacity
        )
    }

    private func syncMainHosted(_ specs: [SeparatorSpec]) {
        let wanted = Set(specs.map(\.id))
        for (id, item) in items where !wanted.contains(id) {
            removalObservations.removeValue(forKey: id)
            NSStatusBar.system.removeStatusItem(item)
            items.removeValue(forKey: id)
            lastVisible.removeValue(forKey: id)
        }
        for spec in specs {
            if let existing = items[spec.id] {
                // Width is the item's own length, not the button's — a spacer
                // dragged down the slider stays its old size otherwise.
                if spec.style == .space, existing.length != spec.width {
                    existing.length = spec.width
                }
                configure(existing.button, spec: spec)
            } else {
                items[spec.id] = makeItem(for: spec)
            }
        }
        applyCurrent()
    }

    /// The spec a helper event names, by its minted title.
    func spec(titled title: String) -> SeparatorSpec? {
        specsByID.values.first { $0.itemTitle == title }
    }

    private func makeItem(for spec: SeparatorSpec) -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(
            withLength: spec.style == .space ? spec.width : NSStatusItem.variableLength
        )
        item.autosaveName = spec.itemTitle
        item.button?.setAccessibilityTitle(spec.itemTitle)
        configure(item.button, spec: spec)
        // Removable, like launchers: on macOS 27 a ⌘-drag off the bar of a
        // NON-removable item disallows the whole app in MenuBarAgent and
        // every Pelmet item stops being hosted (2026-09-14). Removable, the
        // drag just hides this one — and we drop the spec to match.
        item.behavior = .removalAllowed
        observeRemoval(of: item, for: spec)
        return item
    }

    /// The native ⌘-drag off the bar hides the item (`isVisible` false).
    /// Pelmet's own hides flip `lastVisible` first, so a false arriving while
    /// it still reads true is the user's hand: drop the spec like the
    /// editor's Remove button does (see `ExtrasManager.observeRemoval`).
    private func observeRemoval(of item: NSStatusItem, for spec: SeparatorSpec) {
        removalObservations[spec.id] = item.observe(\.isVisible, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self, let item = self.items[spec.id], !item.isVisible,
                      self.lastVisible[spec.id] == true,
                      let appState = self.appState else { return }
                PelmetLog.log("separator: \(spec.style.displayName) dragged off the bar → remove")
                appState.settings.separators.removeAll { $0.id == spec.id }
                appState.settingsChanged()
            }
        }
    }

    /// Section visibility, extras-style: width-collapse in the same reflow as
    /// the assertion swap, then leave layout once the bar has settled.
    func apply(model: SectionModel, revealed: Set<PelmetCore.Section>) {
        for (id, item) in items {
            guard let spec = specsByID[id] else { continue }
            let section = model.section(of: Self.itemID(for: spec))
            setVisible(section == .visible || revealed.contains(section), for: id, item: item, spec: spec)
        }
    }

    private func applyCurrent() {
        guard let appState else { return }
        apply(
            model: appState.settings.sectionModel,
            revealed: appState.revealedSectionsForExtras
        )
    }

    /// Extras-style pre-attach for an uncovered reveal — see
    /// `ExtrasManager.preattach`.
    func preattach(model: SectionModel, revealing: Set<PelmetCore.Section>) -> [NSStatusItem] {
        var attached: [NSStatusItem] = []
        for (id, item) in items {
            guard let spec = specsByID[id], lastVisible[id] != true,
                  revealing.contains(model.section(of: Self.itemID(for: spec))) else { continue }
            StatusItemFader.attach(item, shownLength: Self.shownLength(for: spec))
            preattached.insert(id)
            attached.append(item)
        }
        return attached
    }

    /// A spacer comes back at its own width: this was 14 from before the
    /// width control, so every show (each launch, each reveal) put a spacer
    /// back at 14pt until the slider moved again (#155).
    private static func shownLength(for spec: SeparatorSpec) -> CGFloat {
        spec.style == .space ? spec.width : NSStatusItem.variableLength
    }

    private func setVisible(_ visible: Bool, for id: UUID, item: NSStatusItem, spec: SeparatorSpec) {
        if !visible, lastVisible[id] != true, preattached.remove(id) != nil {
            // Attached ahead of a reveal that never came: leave layout again, unseen.
            item.isVisible = false
            return
        }
        guard lastVisible[id] != visible else { return }
        lastVisible[id] = visible
        let wasPreattached = preattached.remove(id) != nil
        PelmetLog.log("separator: \(spec.style.displayName) → \(visible ? (wasPreattached ? "fade (attached ahead)" : "show") : "hide")")
        let stillCurrent: @MainActor () -> Bool = { [weak self] in
            self?.lastVisible[id] == visible && self?.preattached.contains(id) != true
        }
        let shownAlpha: CGFloat = spec.style == .space ? 0 : spec.opacity
        if visible, wasPreattached {
            StatusItemFader.fadeInAfterGlide(item, shownAlpha: shownAlpha, stillCurrent: stillCurrent)
            return
        }
        StatusItemFader.setVisible(
            visible,
            item: item,
            shownLength: Self.shownLength(for: spec),
            shownAlpha: shownAlpha,
            stillCurrent: stillCurrent
        )
    }

    private func configure(_ button: NSStatusBarButton?, spec: SeparatorSpec) {
        guard let button else { return }
        button.title = spec.style == .space ? "" : spec.style.rawValue
        button.appearsDisabled = false
        // While hidden, alpha stays down; the reveal animation restores it.
        if lastVisible[spec.id] != false {
            button.alphaValue = spec.style == .space ? 0 : spec.opacity
        }
        button.target = self
        button.action = #selector(clicked)
        button.sendAction(on: [.rightMouseUp])
    }

    /// Editor-tile glyph: the separator's actual character, template-style.
    /// The spacer is the one style with no character to show, so it draws the
    /// gap itself — a dashed slot, the same "nothing lives here" shape the
    /// editor's empty tiles use. `␣` only reads as a space if you already
    /// know the convention (Gab, 2026-09-17: asked for a spacer that was
    /// already there, wearing that symbol).
    private static func glyphImage(for style: SeparatorStyle) -> NSImage {
        let size = NSSize(width: 20, height: 20)
        guard style != .space else { return spacerSlotImage(size: size) }
        let image = NSImage(size: size, flipped: false) { rect in
            let text = style.rawValue
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 13, weight: .medium),
                .foregroundColor: NSColor.black,
            ]
            let string = NSAttributedString(string: text, attributes: attributes)
            let bounds = string.size()
            string.draw(at: NSPoint(
                x: rect.midX - bounds.width / 2,
                y: rect.midY - bounds.height / 2
            ))
            return true
        }
        image.isTemplate = true
        return image
    }

    /// A dashed slot: the shape of an empty place in the bar.
    private static func spacerSlotImage(size: NSSize) -> NSImage {
        let image = NSImage(size: size, flipped: false) { rect in
            let slot = NSRect(x: rect.midX - 6, y: rect.midY - 5, width: 12, height: 10)
            let path = NSBezierPath(roundedRect: slot, xRadius: 2.5, yRadius: 2.5)
            path.lineWidth = 1
            path.setLineDash([2, 2], count: 2, phase: 0)
            NSColor.black.setStroke()
            path.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }

    @objc private func clicked() {
        guard let appState else { return }
        let menu = PelmetStatusItem.contextMenu(appState: appState)
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }
}
