// ShowRules.swift
// #86, "Show when it matters": keep a hidden icon on the bar while its state
// matters. This runs the rules on Apple's own Battery and Wi-Fi, which only
// the app can watch; they come from Settings › Menu Bar and start or stop
// their watchers as they change. Pelmet's own items (media, Focus, Time
// Machine) keep theirs on their spec and the extras manager follows them.
//
// The engine shows Battery and Wi-Fi the way a press does: their section
// stays hidden, nothing else reflows. macOS doesn't draw a hidden icon, so
// each state is read from the system, never from the icon.

import AppKit
import IOKit.ps
import notify
import PelmetCore
import PelmetEngine
import SystemConfiguration

@MainActor
final class ShowRules {
    static let battery = ItemID.status(bundle: PelmetBundle.agentID, title: "com.apple.menuextra.battery")
    static let wifi = ItemID.status(bundle: PelmetBundle.agentID, title: "com.apple.menuextra.wifi")

    /// Wi-Fi drops its network for a few seconds on every wake and every
    /// roam: only a disconnection that lasts this long shows the icon.
    static let wifiGrace: Duration = .seconds(5)

    private let apply: (Set<ItemID>) -> Void
    private var rules = ShowRuleSettings()
    private var powerToken: Int32 = NOTIFY_TOKEN_INVALID
    private var percentToken: Int32 = NOTIFY_TOKEN_INVALID
    private var store: SCDynamicStore?
    private var storeSource: CFRunLoopSource?
    private var wifiInterface: String?
    private var wifiDown = false
    private var wifiGraceTask: Task<Void, Never>?
    private var sleepObservers: [NSObjectProtocol] = []
    /// Between willSleep and didWake: a grace that runs out then does
    /// nothing, didWake starts it over.
    private var asleep = false
    private var shown: Set<ItemID>?
    private var lastLine: [String: String] = [:]

    init(apply: @escaping (Set<ItemID>) -> Void) {
        self.apply = apply
    }

    // Isolated: the store's source holds an unretained pointer to self, so it
    // must leave the run loop before self goes.
    isolated deinit {
        stopBattery()
        stopWifi()
    }

    /// The rules as Settings holds them now: watchers start for a rule that
    /// came on and stop for one that went off.
    func update(_ new: ShowRuleSettings) {
        let old = rules
        guard new != old || shown == nil else { return }
        rules = new
        if new.battery != old.battery {
            stopBattery()
            if let condition = new.battery { watchBattery(condition) }
        }
        if new.wifiOn != old.wifiOn {
            stopWifi()
            if new.wifiOn { watchWifi() }
        }
        evaluate()
    }

    // MARK: Battery

    private func watchBattery(_ condition: BatteryShowCondition) {
        notify_register_dispatch(kIOPSNotifyPowerSource, &powerToken, .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.evaluate() }
        }
        // The charge changes all day: listened to only for the rule that reads
        // it. The SDK has no percent-only key; this one fires when the percent
        // or the time remaining changes.
        if condition == .below20 {
            notify_register_dispatch(kIOPSNotifyTimeRemaining, &percentToken, .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.evaluate() }
            }
        }
    }

    private func stopBattery() {
        if powerToken != NOTIFY_TOKEN_INVALID { notify_cancel(powerToken) }
        if percentToken != NOTIFY_TOKEN_INVALID { notify_cancel(percentToken) }
        powerToken = NOTIFY_TOKEN_INVALID
        percentToken = NOTIFY_TOKEN_INVALID
        lastLine.removeValue(forKey: "battery")
    }

    /// On battery power, and the internal battery's charge (nil with none).
    private func batteryReading() -> (onBattery: Bool, percent: Int?) {
        let info = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let providing = IOPSGetProvidingPowerSourceType(info).takeUnretainedValue() as String
        var percent: Int?
        let sources = IOPSCopyPowerSourcesList(info).takeRetainedValue() as [CFTypeRef]
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let capacity = description[kIOPSMaxCapacityKey] as? Int, capacity > 0
            else { continue }
            // Rounded, like the percentage Battery itself draws.
            percent = Int((Double(current) / Double(capacity) * 100).rounded())
            break
        }
        // Debug: `-pelmet.debug.onBattery YES` reads as unplugged at 10%, for a
        // Battery out on its own on a Mac that is plugged in.
        if UserDefaults.standard.bool(forKey: "pelmet.debug.onBattery") { return (true, 10) }
        return (providing == kIOPSBatteryPowerValue, percent)
    }

    // MARK: Wi-Fi

    private func watchWifi() {
        let interfaces = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] ?? []
        wifiInterface = interfaces.first {
            SCNetworkInterfaceGetInterfaceType($0) == kSCNetworkInterfaceTypeIEEE80211
        }.flatMap { SCNetworkInterfaceGetBSDName($0) as String? }
        guard let name = wifiInterface else {
            PelmetLog.log("rule: no Wi-Fi interface, the Wi-Fi rule has nothing to watch")
            return
        }
        var context = SCDynamicStoreContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        guard let store = SCDynamicStoreCreate(nil, "Pelmet.ShowRules" as CFString, { _, _, info in
            guard let info else { return }
            let rules = Unmanaged<ShowRules>.fromOpaque(info).takeUnretainedValue()
            MainActor.assumeIsolated { rules.evaluate() }
        }, &context) else { return }
        let keys = [Self.linkKey(name), Self.airportKey(name)] as CFArray
        SCDynamicStoreSetNotificationKeys(store, keys, nil)
        let source = SCDynamicStoreCreateRunLoopSource(nil, store, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        self.store = store
        storeSource = source
        // The grace sleeps on a clock that runs while the Mac does: one
        // started as the lid closed ran out the moment it woke, before
        // Wi-Fi had rejoined, and the icon flashed. A grace running at
        // wake starts over, against the link as it is then, and so does
        // one that started after willSleep, Wi-Fi powering down for it
        // (review B5). Its end does nothing while asleep: it can come
        // before didWake.
        let workspace = NSWorkspace.shared.notificationCenter
        sleepObservers = [
            workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.asleep = true }
            },
            workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.asleep = false
                    if self.wifiGraceTask != nil {
                        self.wifiGraceTask?.cancel()
                        self.wifiGraceTask = nil
                        self.wifiDown = false
                        self.note("wifi", "Wi-Fi grace ran across sleep, starts over on wake")
                    }
                    self.evaluate()
                }
            },
        ]
    }

    private func stopWifi() {
        if let storeSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), storeSource, .commonModes) }
        storeSource = nil
        store = nil
        wifiInterface = nil
        wifiDown = false
        wifiGraceTask?.cancel()
        wifiGraceTask = nil
        sleepObservers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        sleepObservers = []
        asleep = false
        lastLine.removeValue(forKey: "wifi")
    }

    private static func linkKey(_ name: String) -> String { "State:/Network/Interface/\(name)/Link" }
    private static func airportKey(_ name: String) -> String { "State:/Network/Interface/\(name)/AirPort" }

    /// On, and joined to no network. Nil when the store can't say.
    private func wifiDisconnected() -> Bool? {
        guard let store, let name = wifiInterface else { return nil }
        let airport = SCDynamicStoreCopyValue(store, Self.airportKey(name) as CFString) as? [String: Any]
        let link = SCDynamicStoreCopyValue(store, Self.linkKey(name) as CFString) as? [String: Any]
        let powered = (airport?["Power Status"] as? NSNumber)?.boolValue ?? false
        let joined = (link?["Active"] as? NSNumber)?.boolValue ?? false
        return powered && !joined
    }

    // MARK: Evaluate

    private func evaluate() {
        var items: Set<ItemID> = []
        if let condition = rules.battery {
            let reading = batteryReading()
            let met = condition.isMet(onBattery: reading.onBattery, percent: reading.percent)
            let charge = reading.percent.map { ", \($0)%" } ?? ""
            note("battery", met
                ? "\(condition.rawValue) holds\(charge), Battery shows"
                : "\(condition.rawValue) doesn't hold\(charge), Battery follows its section",
                 state: "\(condition.rawValue) \(met)")
            if met { items.insert(Self.battery) }
        }
        if rules.wifiOn, let down = wifiDisconnected() {
            if down, !wifiDown {
                // Shown only if the grace runs out still disconnected.
                wifiDown = true
                note("wifi", "Wi-Fi joined to no network, shows in \(Self.wifiGrace) unless it rejoins")
                wifiGraceTask?.cancel()
                wifiGraceTask = Task { [weak self] in
                    try? await Task.sleep(for: Self.wifiGrace)
                    guard !Task.isCancelled, let self, !self.asleep else { return }
                    self.wifiGraceTask = nil
                    self.evaluate()
                }
            } else if !down {
                wifiDown = false
                wifiGraceTask?.cancel()
                wifiGraceTask = nil
                note("wifi", "Wi-Fi joined or off, Wi-Fi follows its section")
            }
            if down, wifiGraceTask == nil {
                note("wifi", "Wi-Fi still joined to no network, Wi-Fi shows")
                items.insert(Self.wifi)
            }
        }
        guard items != shown else { return }
        shown = items
        apply(items)
    }

    /// One line per change of a rule's state, not per notification: the
    /// charge alone changing (a line every percent while charging) is not one.
    private func note(_ rule: String, _ line: String, state: String? = nil) {
        let state = state ?? line
        guard lastLine[rule] != state else { return }
        lastLine[rule] = state
        PelmetLog.log("rule: \(line)")
    }
}
