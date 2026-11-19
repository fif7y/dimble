// SettingsWindowController.swift
// Pelmet owns its settings window directly — the SwiftUI Settings-scene selector
// (`showSettingsWindow:`) is unreliable from an LSUIElement status-item
// context, and M4's designed settings wants full window control anyway.

import AppKit
import SwiftUI

final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()
    private var window: NSWindow?
    private weak var appState: AppState?

    func show(appState: AppState, tab: SettingsTab = .general) {
        self.appState = appState
        // Always land on General (or the caller's tab): opening straight
        // onto the Menu Bar tab triggers its full-reveal preview before the
        // user asked for it.
        appState.settingsTab = tab
        if let window {
            bringToFront(window)
            appState.settingsDisplay = window.screen?.directDisplayID
            appState.settingsWindowVisible = true
            return
        }
        let hosting = NSHostingController(
            rootView: SettingsView().environment(appState)
        )
        let window = NSWindow(contentViewController: hosting)
        window.title = String(localized: "Dimble Settings")
        // Sidebar shell: the sidebar runs under a transparent titlebar, so the
        // window chrome disappears and only the traffic lights remain.
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 780, height: 730))
        window.minSize = NSSize(width: 720, height: 520)
        window.center()
        // Normal level, like any app window. It used to float permanently
        // so editor drags (which activate the dragged icon's app) could not
        // sink it, but a window over every other app is the worse trade.
        // It floats only while a drag is in flight — see holdAboveDrag().
        window.collectionBehavior = [.moveToActiveSpace]
        window.delegate = self
        self.window = window
        bringToFront(window)
        appState.settingsDisplay = window.screen?.directDisplayID
        appState.settingsWindowVisible = true
    }

    /// Dragged to another display: the Panel tab follows it.
    func windowDidChangeScreen(_ notification: Notification) {
        appState?.settingsDisplay = window?.screen?.directDisplayID
    }

    /// Cooperative activation (macOS 14+) can refuse a status-item app
    /// while another app is frontmost, which leaves the window ordered in
    /// behind it. Order it regardless, then ask for activation the
    /// non-cooperative way.
    private func bringToFront(_ window: NSWindow) {
        window.orderFrontRegardless()
        window.makeKey()
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        appState?.settingsWindowVisible = false
        // Let the window go: kept alive, its SwiftUI tree kept running the
        // Behavior showcase loop and the About icon's keyframes off screen
        // (27% CPU after close, #20). A fresh window is built on next show.
        window = nil
        // Hand activation back: an agent app with no window left stays
        // active until the user clicks elsewhere, and while it is active
        // its own menubar events never reach the band monitor's global
        // monitors (the local mirror covers it too, belt and braces).
        let closing = notification.object as? NSWindow
        if !NSApp.windows.contains(where: { $0 !== closing && $0.isVisible }) {
            NSApp.deactivate()
        }
    }

    /// Re-front the window after a synthetic menubar drag — the drag's
    /// mouse-down lands outside Pelmet, so macOS deactivates us mid-edit.
    func refocus() {
        guard let window, window.isVisible else { return }
        bringToFront(window)
    }

    /// Float for the span of a synthetic menubar drag: its mouse-down lands
    /// outside Pelmet and the dragged icon's app wins activation, which
    /// would sink a normal-level window. Counted, so overlapping drags
    /// keep the window up until the last one releases.
    private var dragHolds = 0

    func holdAboveDrag() {
        dragHolds += 1
        window?.level = .floating
    }

    func releaseAfterDrag() {
        dragHolds = max(0, dragHolds - 1)
        if dragHolds == 0 { window?.level = .normal }
    }
}
