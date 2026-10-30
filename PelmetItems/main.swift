// PelmetItems — a section helper (docs/HELPER-PROCESS-PLAN.md).
// A bundle id the hide assertion can exclude, hosting the NSStatusItems of
// ONE section (hidden or always-hidden, by bundle id). It knows nothing
// about sections or settings: the main app sends the full list to host
// over a message port and this diffs it; clicks and drag-outs go back the
// same way. Exits when the launching Pelmet is gone; never runs twice.

import AppKit
import OSLog
import PelmetCore

let log = Logger(subsystem: "app.fif7y.Pelmet", category: "items")

let bundleID = Bundle.main.bundleIdentifier ?? PelmetBundle.hiddenHostID
let myPID = ProcessInfo.processInfo.processIdentifier

for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
where app.processIdentifier != myPID {
    log.notice("PelmetItems: terminating a duplicate \(bundleID, privacy: .public) pid \(app.processIdentifier)")
    app.forceTerminate()
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

@MainActor
final class ItemsHost: NSObject, NSApplicationDelegate {
    private var items: [String: NSStatusItem] = [:]
    private var specs: [String: HostedItem] = [:]
    private var removalObservations: [String: NSKeyValueObservation] = [:]
    /// Titles whose isVisible WE set false (a sync removal), so the KVO
    /// does not read our own removal as a user drag-out.
    private var unhosting: Set<String> = []
    private var listener: MessagePortListener?
    private var parentWatch: DispatchSourceProcess?

    func applicationDidFinishLaunching(_ notification: Notification) {
        listener = MessagePortListener(name: bundleID) { data in
            guard let command = HelperWire.decode(HelperCommand.self, from: data), command.isValid else { return }
            Task { @MainActor in host.handle(command) }
        }
        if listener == nil {
            log.notice("PelmetItems: port \(bundleID, privacy: .public) taken — exiting")
            NSApp.terminate(nil)
            return
        }
        let parent = ProcessInfo.processInfo.environment["PELMET_PARENT_PID"].flatMap(pid_t.init) ?? getppid()
        // Exit the instant the parent does: a 2 s poll left this process
        // alive across a quit-and-relaunch (a Sparkle update), and the new
        // Pelmet's launch handed it the OLD helper, which never said ready.
        guard kill(parent, 0) == 0 else {
            log.notice("PelmetItems: parent \(parent) already gone — exiting")
            NSApp.terminate(nil)
            return
        }
        let watch = DispatchSource.makeProcessSource(identifier: parent, eventMask: .exit, queue: .main)
        watch.setEventHandler {
            log.notice("PelmetItems: parent \(parent) gone — exiting")
            NSApp.terminate(nil)
        }
        watch.resume()
        parentWatch = watch
        let sent = send(.ready(bundle: bundleID))
        log.notice("PelmetItems: ready sent=\(sent)")
        log.notice("PelmetItems: \(bundleID, privacy: .public) ready, parent \(parent)")
    }

    @discardableResult
    private func send(_ event: HelperEvent) -> Bool {
        guard let data = HelperWire.encode(event) else { return false }
        return MessagePortLink.send(data, to: PelmetBundle.mainLinkPort)
    }

    private func handle(_ command: HelperCommand) {
        switch command {
        case .quit:
            NSApp.terminate(nil)
        case .sync(let wanted):
            log.notice("PelmetItems: sync \(wanted.count) item(s), hosting \(self.items.count)")
            let wantedTitles = Set(wanted.map(\.title))
            for title in items.keys where !wantedTitles.contains(title) {
                unhost(title)
            }
            for spec in wanted {
                if let item = items[spec.title] {
                    if specs[spec.title] != spec { configure(item, spec) }
                } else {
                    let item = makeItem(spec)
                    items[spec.title] = item
                    log.notice("PelmetItems: hosting \(spec.title, privacy: .public)")
                    send(.hosted(bundle: bundleID, title: spec.title))
                }
                specs[spec.title] = spec
            }
        }
    }

    private func makeItem(_ spec: HostedItem) -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(
            withLength: spec.length.map { CGFloat($0) } ?? NSStatusItem.variableLength
        )
        item.autosaveName = spec.title
        item.button?.setAccessibilityTitle(spec.title)
        item.behavior = spec.removable ? .removalAllowed : []
        // A stale `NSStatusItem VisibleCC` from a previous drag-out would
        // keep a re-added item invisible; hosting means showing.
        item.isVisible = true
        configure(item, spec)
        if let button = item.button {
            button.target = self
            button.action = #selector(clicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        removalObservations[spec.title] = item.observe(\.isVisible, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self, let item = self.items[spec.title], !item.isVisible,
                      !self.unhosting.contains(spec.title) else { return }
                log.notice("PelmetItems: \(spec.title, privacy: .public) dragged off the bar")
                self.unhost(spec.title)
                self.send(.draggedOff(bundle: bundleID, title: spec.title))
            }
        }
        return item
    }

    private func configure(_ item: NSStatusItem, _ spec: HostedItem) {
        guard let button = item.button else { return }
        if let png = spec.imagePNG, let image = NSImage(data: png) {
            image.isTemplate = spec.imageIsTemplate
            button.image = image
            button.imageScaling = .scaleProportionallyDown
            button.title = ""
        } else {
            button.image = nil
            button.title = spec.text
        }
        button.alphaValue = CGFloat(spec.alpha)
        button.appearsDisabled = false
        if let length = spec.length { item.length = CGFloat(length) }
    }

    private func unhost(_ title: String) {
        guard let item = items.removeValue(forKey: title) else { return }
        unhosting.insert(title)
        removalObservations.removeValue(forKey: title)
        specs.removeValue(forKey: title)
        NSStatusBar.system.removeStatusItem(item)
        unhosting.remove(title)
    }

    @objc private func clicked(_ sender: NSStatusBarButton) {
        guard let title = items.first(where: { $0.value.button === sender })?.key else { return }
        let right = NSApp.currentEvent?.type == .rightMouseUp
        let p = NSEvent.mouseLocation
        send(.clicked(bundle: bundleID, title: title, rightButton: right, x: p.x, y: p.y))
    }
}

let host = ItemsHost()
app.delegate = host
app.run()
