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
        Automation.appState = appState
    }

    /// dimble:// links (#146, #169), see Automation.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard !relaunching else { return }
        urls.forEach(Automation.handle)
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
        PelmetLog.log("stop: asked to quit \(Self.quitAsker())")
        // The instance that just renamed the bundle never started AppState,
        // so beginTermination would never reply and it would stay running
        // beside the relaunched one.
        guard !relaunching else { return .terminateNow }
        appState.beginTermination()
        return .terminateLater
    }

    /// Who asked for this quit (fif7y/dimble#130: clean quits nobody at the
    /// Mac asked for). A quit from another process arrives as an Apple
    /// Event carrying the sender's pid, and loginwindow adds why (log out,
    /// restart, shut down). No event means the quit came from inside: our
    /// own Quit, or Sparkle installing an update.
    private static func quitAsker() -> String {
        guard let event = NSAppleEventManager.shared().currentAppleEvent else {
            return "from inside (no Apple Event)"
        }
        var parts: [String] = []
        if let pid = event.attributeDescriptor(forKeyword: AEKeyword(keySenderPIDAttr))?.int32Value {
            // A helper tool or a script has no bundle id: name its binary.
            var path = [UInt8](repeating: 0, count: 4096)
            let length = Int(proc_pidpath(pid, &path, UInt32(path.count)))
            let binary = length > 0 ? String(decoding: path[..<length], as: UTF8.self) : "unknown"
            let name = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? binary
            parts.append("by \(name) (pid \(pid))")
        } else {
            parts.append("by an Apple Event with no sender pid")
        }
        if let why = event.attributeDescriptor(forKeyword: AEKeyword(kAEQuitReason))?.enumCodeValue, why != 0 {
            parts.append("reason \(NSFileTypeForHFSTypeCode(why) ?? String(why))")
        }
        return parts.joined(separator: ", ")
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
