// PelmetStatusItem.swift
// Pelmet's own (optional) menubar icon. Left-click toggles the hidden section;
// right-click opens the menu. AppKit NSStatusItem — MenuBarExtra can't do
// right-click or imperative button control.

import AppKit
import Carbon.HIToolbox
import PelmetCore
import PelmetEngine

final class PelmetStatusItem {
    private let item: NSStatusItem
    private weak var appState: AppState?
    private var removalObservation: NSKeyValueObservation?
    private var removed = false

    init(appState: AppState) {
        self.appState = appState
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.autosaveName = "Pelmet.StatusItem"
        // AppKit restores an item's visibility from `NSStatusItem VisibleCC
        // <autosaveName>`, stored in our OWN defaults domain — so a
        // preferences blob captured while the bar was concealed (a Time
        // Machine restore, Migration Assistant, any backup of the whole
        // domain) can bring the chevron back marked invisible. Extras and
        // separators heal themselves: their next reveal runs the show path,
        // which sets isVisible. Nothing ever sets it on the chevron, so a
        // stale false was permanent, with Settings still reading ON and no
        // way for the user to see why. Whether the chevron exists at all is
        // AppState's call (showStatusItem), never a stale autosave's.
        item.isVisible = true
        // Removable: a ⌘-drag off the bar of a NON-removable item disallows
        // the whole app in MenuBarAgent on macOS 27 (2026-09-14). Dragged
        // off, the chevron becomes the icon-hidden mode the toggle offers.
        item.behavior = .removalAllowed
        removalObservation = item.observe(\.isVisible, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self, !self.item.isVisible, !self.removed,
                      let appState = self.appState, appState.settings.showStatusItem
                else { return }
                PelmetLog.log("status: chevron dragged off the bar → hide Pelmet icon")
                appState.settings.showStatusItem = false
                appState.settingsChanged()
            }
        }
        if let button = item.button {
            button.target = self
            button.action = #selector(clicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            // Stable engine identity (chevron-boundary lookups key off this).
            button.setAccessibilityTitle("Pelmet.StatusItem")
            // The one item of ours that is always drawn: the bar's ink is
            // read off it for the apps whose icons we hide.
            MenuBarInkBroadcast.shared.track(button)
        }
        warning = !appState.accessibilityGranted
        applyImage()
        showUpdateDot(SparkleController.shared.availableVersion != nil)
    }

    /// Which face the glyph is showing, so the warning colour can be
    /// re-applied without the caller re-stating it (and vice versa).
    private var revealedFace = false
    private var warning = false
    /// The face, style and warning the button's image was last drawn for.
    private var appliedImage: String?
    /// Uptime of the last left click on the chevron, to time a double (#77).
    private var lastLeftClickAt: TimeInterval?

    /// Where the chevron is drawn right now, in screen coordinates. AppKit
    /// keeps the button's window on the drawn item (popovers anchor to it),
    /// so this never lags a reflow the way a walked frame can. Nil before
    /// the item is placed or once it's off the bar. Behind Apple's « it
    /// stays on the bar, parked on the « (#81): read `windowOcclusionVisible`.
    var windowFrame: NSRect? {
        guard let frame = item.button?.window?.frame, frame.width > 0, frame.height > 0 else { return nil }
        return frame
    }

    /// The chevron's window; its occlusion is the one sign it went behind
    /// Apple's « (`ChevronTrap`, #81).
    var buttonWindow: NSWindow? { item.button?.window }

    /// Whether AppKit reads the chevron's window as visible, nil without one.
    var windowOcclusionVisible: Bool? {
        buttonWindow.map { $0.occlusionState.contains(.visible) }
    }

    /// An available update earns a 5pt accent dot at the chevron's top
    /// right — the one surface most users ever look at. It lives until the
    /// install relaunches the app.
    private var updateDot: AccentDotView?

    func showUpdateDot(_ show: Bool) {
        guard let button = item.button else { return }
        if show, updateDot == nil {
            let size: CGFloat = 5
            let dot = AccentDotView(frame: NSRect(
                x: button.bounds.width - size - 3, y: button.bounds.height - size - 3,
                width: size, height: size
            ))
            dot.autoresizingMask = [.minXMargin, .minYMargin]
            button.addSubview(dot)
            updateDot = dot
        } else if !show {
            updateDot?.removeFromSuperview()
            updateDot = nil
        }
    }

    /// Without the Accessibility grant Pelmet can't see the bar, so the
    /// chevron itself carries the warning: system orange until it's back.
    func updateAccessibilityWarning(granted: Bool) {
        guard warning == granted else { return }
        warning = !granted
        applyImage()
    }

    /// The glyph, in the current face and the current warning state.
    ///
    /// The warning colour rides the IMAGE, via a palette symbol
    /// configuration. It used to be the button's `contentTintColor`, which
    /// on macOS 27 never reaches a template symbol in the menu bar: the
    /// glyph rendered flat black instead of orange — invisible on a dark
    /// bar, so the one signal that Pelmet had lost Accessibility looked
    /// like a broken icon (2026-09-10). A palette-configured symbol carries
    /// its own colour and is no longer a template.
    private func applyImage() {
        // Never return without setting one: this is the only code path that
        // draws the icon, so bailing here leaves an empty square in the bar.
        // The style is only a preference — losing the weak appState is not a
        // reason to show nothing.
        let style = appState?.settings.statusIconStyle ?? .chevron
        // The same glyph again is a ~5ms swap for nothing on macOS 27, and
        // every settingsChanged asks (a column drag asked per step).
        let key = "\(style.rawValue) \(revealedFace) \(warning)"
        guard key != appliedImage || item.button?.image == nil else { return }
        appliedImage = key
        if style == .wideChevron {
            item.button?.image = WideChevron.image(revealed: revealedFace, warning: warning)
            return
        }
        let symbol = NSImage(
            systemSymbolName: style.symbol(revealed: revealedFace),
            accessibilityDescription: "Dimble"
        )
        // One configuration, applied once: a second withSymbolConfiguration
        // replaces the first, so the warning palette would drop the size.
        let size = style.symbolPointSize.map { NSImage.SymbolConfiguration(pointSize: $0, weight: .regular) }
        let glyph = size.flatMap { symbol?.withSymbolConfiguration($0) } ?? symbol
        guard warning else {
            item.button?.image = glyph
            return
        }
        let palette = NSImage.SymbolConfiguration(paletteColors: [.systemOrange])
        let tinted = symbol?.withSymbolConfiguration(size.map { $0.applying(palette) } ?? palette)
        tinted?.isTemplate = false
        item.button?.image = tinted ?? glyph
    }

    /// Call before releasing (deinit can't touch main-actor AppKit state under
    /// strict concurrency).
    func remove() {
        removed = true
        removalObservation = nil
        MenuBarInkBroadcast.shared.stop()
        NSStatusBar.system.removeStatusItem(item)
    }

    func updateSymbol(revealed: Bool) {
        revealedFace = revealed
        applyImage()
    }

    @objc private func clicked() {
        guard let appState else { return }
        // currentEvent is nil for synthetic AX presses (VoiceOver etc.) —
        // treat those as a plain left-click toggle instead of bailing.
        let event = NSApp.currentEvent
        // macOS 27 hands the chevron's action an event without the click's
        // modifiers (#77: three ⌥-clicks logged as plain toggles), so ⌥ is
        // read from the live keyboard state and a double is timed here
        // rather than taken from the event's clickCount.
        let option = NSEvent.modifierFlags.contains(.option) || event?.modifierFlags.contains(.option) == true
        let now = ProcessInfo.processInfo.systemUptime
        let isDouble = lastLeftClickAt.map { now - $0 <= NSEvent.doubleClickInterval } ?? false
        PelmetLog.log("statusItem clicked: type=\(event?.type.rawValue ?? 0) option=\(option) count=\(event?.clickCount ?? 0) double=\(isDouble)")
        if event?.type == .rightMouseUp {
            lastLeftClickAt = nil
            let mouse = NSEvent.mouseLocation
            if let home = item.button?.window?.screen, NSMouseInRect(mouse, home.frame, false) {
                item.menu = Self.contextMenu(appState: appState)
                item.button?.performClick(nil)
                item.menu = nil
            } else {
                // AppKit opens the item's menu on its own window's display
                // whichever copy was clicked (#26, 3 displays): on another
                // display it drops from that bar, at the pointer.
                Self.contextMenu(appState: appState).popUp(positioning: nil, at: Self.underBar(at: mouse), in: nil)
            }
            // Both return once the menu is dismissed; it fades for a beat
            // after that (see `ConcealGhostOverlay.menuClosedAt`).
            ConcealGhostOverlay.menuClosedAt = Date()
            return
        }
        // A third click starts a new sequence instead of chaining doubles.
        lastLeftClickAt = isDouble ? nil : now
        if option {
            appState.reveal([.hidden, .alwaysHidden], reason: .statusItem)
        } else if isDouble, appState.settings.revealTriggers.doubleClickForAlwaysHidden {
            // Second click of a double on the chevron (#77): the first one
            // already toggled, this widens the reveal to Always Hidden. A
            // reveal mid-transition unions, never narrows. On a revealed bar
            // the first click conceals and this reopens it wider, a brief
            // flash kept over delaying every closing click.
            appState.reveal([.hidden, .alwaysHidden], reason: .statusItem)
        } else {
            appState.toggle(reason: .statusItem)
        }
    }

    /// Under the bar of the display `point` is on, at its x (Cocoa). The
    /// bar's own window gives its height (`GlassPanel.barHeight`): off the
    /// main display the visibleFrame keeps no band for it, and a 30pt bar
    /// read as none.
    private static func underBar(at point: NSPoint) -> NSPoint {
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }) else { return point }
        return NSPoint(x: point.x, y: screen.frame.maxY - GlassPanel.barHeight(of: screen))
    }

    static func contextMenu(appState: AppState) -> NSMenu {
        let menu = NSMenu()
        let toggle = NSMenuItem(
            title: appState.sectionsRevealed ? String(localized: "Hide Items") : String(localized: "Show Hidden Items"),
            action: #selector(AppMenuTarget.toggle), keyEquivalent: ""
        )
        Self.showShortcut(appState.settings.hotkey, on: toggle)
        let showAll = NSMenuItem(
            title: String(localized: "Show Always Hidden Too"),
            action: #selector(AppMenuTarget.showAll), keyEquivalent: ""
        )
        Self.showShortcut(appState.settings.alwaysHiddenHotkey, on: showAll)
        let search = NSMenuItem(
            title: String(localized: "Search…"),
            action: #selector(AppMenuTarget.search), keyEquivalent: ""
        )
        Self.showShortcut(appState.settings.searchHotkey, on: search)
        let settings = NSMenuItem(
            title: String(localized: "Dimble Settings…"),
            // Never ⌘, here: it only fired while this menu was open and read
            // as a global shortcut that never worked (2026-09-15). The global
            // one Settings › Shortcuts sets is real, so that one is drawn.
            action: #selector(AppMenuTarget.openSettings), keyEquivalent: ""
        )
        Self.showShortcut(appState.settings.settingsHotkey, on: settings)
        let quit = NSMenuItem(
            title: String(localized: "Quit Dimble"),
            action: #selector(AppMenuTarget.quit), keyEquivalent: "q"
        )
        let target = AppMenuTarget.shared
        target.appState = appState
        // The style is a taste call people flip while watching the bar, so
        // it sits one hover away instead of two clicks into Behavior.
        let animation = NSMenuItem(title: String(localized: "Animation"), action: nil, keyEquivalent: "")
        let styles = NSMenu()
        for (style, title) in [
            (RevealAnimation.instant, String(localized: "Instant")),
            (.smooth, String(localized: "Smooth")),
            (.fade, String(localized: "Fade")),
        ] {
            let option = NSMenuItem(title: title, action: #selector(AppMenuTarget.setAnimation(_:)), keyEquivalent: "")
            option.representedObject = style.rawValue
            option.state = appState.settings.revealAnimation == style ? .on : .off
            option.target = target
            styles.addItem(option)
        }
        animation.submenu = styles
        // Where the hidden icons show from this display's bar: its own
        // choice (Settings › Displays) or the Panel tab's.
        let display = NSScreen.underPointer?.directDisplayID
        let shownIn = NSMenuItem(title: String(localized: "Show hidden icons in"), action: nil, keyEquivalent: "")
        let targets = NSMenu()
        for (option, title) in [
            (RevealTarget.menuBar, String(localized: "Menu bar")),
            (.panel, String(localized: "Panel")),
            (.row, String(localized: "Row")),
        ] {
            let item = NSMenuItem(title: title, action: #selector(AppMenuTarget.setRevealTarget(_:)), keyEquivalent: "")
            item.representedObject = option.rawValue
            item.state = appState.revealTarget(onDisplay: display) == option ? .on : .off
            item.target = target
            targets.addItem(item)
        }
        shownIn.submenu = targets
        // Text only: icons on every row read heavy (2026-10-12), and AppKit
        // adds a gear to a "Settings…" item on its own. Only the update and
        // Accessibility rows below keep theirs, they carry a state.
        settings.preferredImageVisibility = .hidden
        let checkForUpdates = NSMenuItem(
            title: String(localized: "Check for Updates…"),
            action: #selector(AppMenuTarget.checkForUpdates), keyEquivalent: ""
        )
        let editMenuBar = NSMenuItem(
            title: String(localized: "Edit Menu Bar…"),
            action: #selector(AppMenuTarget.editMenuBar), keyEquivalent: ""
        )
        editMenuBar.preferredImageVisibility = .hidden
        // Search and Settings lead by default, they're what a right-click is
        // for: a left click already shows and hides. The order and the picks
        // are the user's from here (Settings › Behavior); `drawn` has already
        // dropped the separators that would lead, trail or double up.
        let built: [ChevronMenuEntry: NSMenuItem] = [
            .search: search, .settings: settings, .toggle: toggle, .showAll: showAll,
            .animation: animation, .revealTarget: shownIn,
            .checkForUpdates: checkForUpdates, .editMenuBar: editMenuBar, .quit: quit,
        ]
        var items: [NSMenuItem] = appState.settings.chevronMenu.drawn.compactMap { slot in
            switch slot {
            case .entry(let entry): built[entry]
            case .separator: NSMenuItem.separator()
            }
        }
        // Same line in every right-click (chevron, separators, empty bar),
        // right under Settings: the About chip is the only other trace once
        // the banner is gone.
        if let version = SparkleController.shared.availableVersion {
            let update = NSMenuItem(
                title: String(localized: "Update available: \(version)"),
                action: #selector(AppMenuTarget.installUpdate), keyEquivalent: ""
            )
            update.image = NSImage(systemSymbolName: "arrow.down.circle.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(paletteColors: [.systemGreen]))
            // macOS 27 hides menu images unless the item asks.
            update.preferredImageVisibility = .visible
            // Settings is always drawn, so this normally lands under it;
            // `?? -1` only covers a future where that stops being true.
            items.insert(update, at: (items.firstIndex(of: settings) ?? -1) + 1)
        }
        if !appState.accessibilityGranted {
            // Lead with the fix: nothing else in this menu works without it.
            let grant = NSMenuItem(
                title: String(localized: "Accessibility access is off. Turn it on…"),
                action: #selector(AppMenuTarget.grantAccessibility), keyEquivalent: ""
            )
            grant.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(paletteColors: [.systemOrange]))
            grant.preferredImageVisibility = .visible
            items.insert(contentsOf: [grant, .separator()], at: 0)
        }
        for menuItem in items where !menuItem.isSeparatorItem {
            menuItem.target = target
        }
        menu.items = items
        return menu
    }

    /// Draw a global shortcut beside its menu item. It is a real one (the
    /// same combination works with this menu closed), so unlike Settings it
    /// reads true. Only a single-character key can be drawn as a key
    /// equivalent; the arrows and F-keys are left off.
    private static func showShortcut(_ spec: HotkeySpec?, on item: NSMenuItem) {
        guard let spec else { return }
        let modifierGlyphs: Set<Character> = ["⌃", "⌥", "⇧", "⌘"]
        let keys = spec.display.filter { !modifierGlyphs.contains($0) }
        guard keys.count == 1 else { return }
        var mask: NSEvent.ModifierFlags = []
        if spec.modifiers & UInt32(controlKey) != 0 { mask.insert(.control) }
        if spec.modifiers & UInt32(optionKey) != 0 { mask.insert(.option) }
        if spec.modifiers & UInt32(shiftKey) != 0 { mask.insert(.shift) }
        if spec.modifiers & UInt32(cmdKey) != 0 { mask.insert(.command) }
        item.keyEquivalent = keys.lowercased()
        item.keyEquivalentModifierMask = mask
    }
}

/// The wide chevron (#101): the one on the site and in the README's
/// animation, where SF's compact chevron is 3.5pt wide and reads squashed
/// on a 15" Air. The animation's `M7.5 2 L3 8 L7.5 14` (a 10×16 box drawn
/// at 0.9) gives the arms: 4.05pt across, 10.8pt tall, on a 1.8pt round
/// stroke that sits between the site's two weights and closer to the bar's
/// symbols. Both faces share one canvas, so a flip never moves it.
enum WideChevron {
    static func image(revealed: Bool, warning: Bool = false) -> NSImage {
        let size = NSSize(width: 8, height: 16)
        let image = NSImage(size: size, flipped: false) { _ in
            let width: CGFloat = 4.05, height: CGFloat = 10.8
            let left = (size.width - width) / 2, bottom = (size.height - height) / 2
            let tip = revealed ? left + width : left
            let ends = revealed ? left : left + width
            let path = NSBezierPath()
            path.move(to: NSPoint(x: ends, y: bottom + height))
            path.line(to: NSPoint(x: tip, y: bottom + height / 2))
            path.line(to: NSPoint(x: ends, y: bottom))
            path.lineWidth = 1.8
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            (warning ? NSColor.systemOrange : .black).setStroke()
            path.stroke()
            return true
        }
        // A template, so the bar inks it for light and dark like a symbol;
        // the warning is the palette symbol's orange, its own colour.
        image.isTemplate = !warning
        image.accessibilityDescription = "Dimble"
        return image
    }
}

/// Shared menu target so context menus built from separators and the status
/// item reuse one implementation.
final class AppMenuTarget: NSObject {
    static let shared = AppMenuTarget()
    weak var appState: AppState?

    @objc func toggle() { appState?.toggle(reason: .statusItem) }
    @objc func showAll() { appState?.reveal([.hidden, .alwaysHidden], reason: .statusItem) }
    @objc func search() { appState?.commandBar.open(source: "menu") }
    @objc func openSettings() { appState?.openSettings() }
    @objc func setAnimation(_ sender: NSMenuItem) {
        guard let appState,
              let raw = sender.representedObject as? String,
              let style = RevealAnimation(rawValue: raw) else { return }
        appState.settings.revealAnimation = style
        appState.settingsChanged()
    }
    @objc func setRevealTarget(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let option = RevealTarget(rawValue: raw) else { return }
        appState?.panelPresenter.pick(option, onDisplay: NSScreen.underPointer?.directDisplayID)
    }
    @objc func grantAccessibility() { AccessibilityAccess.request() }
    /// The About pane is the update hub (chip, notes, toggles) — land there
    /// rather than straight in Sparkle's window.
    @objc func installUpdate() { SparkleController.shared.openUpdateHub() }
    /// The menu's own check, for people who put the row there: Sparkle's
    /// own flow, which says "you're up to date" when there's nothing. The
    /// `installUpdate` row above is the one a found update inserts.
    @objc func checkForUpdates() { SparkleController.shared.checkForUpdates() }
    @objc func editMenuBar() { appState?.openSettings(tab: .menuBar) }
    @objc func quit() { NSApp.terminate(nil) }
}

/// The update dot. Its color is resolved when it draws, so it follows the
/// accent chosen in Settings and the bar's light or dark appearance.
final class AccentDotView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = frame.width / 2
        needsDisplay = true
        track()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = PelmetAccent.nsColor.cgColor
        }
    }

    /// Redraw whenever the chosen accent changes; stops once the dot is gone.
    private func track() {
        withObservationTracking {
            _ = AccentStore.shared.choice
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.needsDisplay = true
                self.track()
            }
        }
    }
}
