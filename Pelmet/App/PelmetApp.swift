// PelmetApp.swift
// Agent app (LSUIElement): no dock icon; lives in the menubar. Settings and
// onboarding windows activate the app transiently.

import PelmetEngine
import SwiftUI

@main
struct PelmetApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // Placeholder scene: the App protocol needs one, but Pelmet presents its
        // real windows (settings, onboarding) through its own controllers.
        Settings { EmptyView() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let appState: AppState
    private let relaunching: Bool

    // Order matters: bundle relocation before any TCC-relevant work, then
    // defaults migration before AppState's property initializers call
    // SettingsStore.load().
    override init() {
        relaunching = BundleRelocation.relocateIfNeeded()
        NookMigration.runIfNeeded()
        appState = AppState()
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !relaunching else { return }
        BundleRelocation.reregisterLoginItemIfRelocated()
        appState.start()
        if let tab = AppLanguage.takeReopenSettingsTab() {
            appState.openSettings(tab: tab)
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // The instance that just renamed the bundle never started AppState,
        // so beginTermination would never reply and it would stay running
        // beside the relaunched one.
        guard !relaunching else { return .terminateNow }
        appState.beginTermination()
        return .terminateLater
    }

    /// The one line saying Dimble went down on purpose. Without it, a log
    /// that stops mid-session looks the same whether the app quit, crashed
    /// or was killed (fif7y/dimble#130). A SIGKILL still leaves nothing,
    /// which is the point: no line means it didn't quit.
    func applicationWillTerminate(_ notification: Notification) {
        PelmetLog.logBlocking("stop: quitting")
    }

    /// Relaunching Pelmet (Finder/Spotlight) while it runs opens Settings —
    /// one of the iconless-mode entry points. A click on one of Pelmet's
    /// banners reopens the app too, racing the banner's own handler: an
    /// open Settings keeps the tab it was just sent to (About), or the
    /// banner landed on General.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        PelmetLog.log("reopen: settings visible=\(appState.settingsWindowVisible) tab=\(appState.settingsTab)")
        appState.openSettings(tab: appState.settingsWindowVisible ? appState.settingsTab : .general)
        return true
    }
}
