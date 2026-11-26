// HotkeyManager.swift
// One global hotkey via Carbon RegisterEventHotKey — works without Input
// Monitoring, sandboxes fine, survives Secure Input better than event taps.

import Carbon.HIToolbox
import Foundation
import PelmetCore
import PelmetEngine

final class HotkeyManager {
    enum Slot: UInt32 { case toggle = 1, settings = 2, notificationCenter = 3, alwaysHidden = 4, search = 5, alwaysHiddenOnly = 6, controlCenter = 7 }

    /// Per-item shortcuts (open that item's menu) take raw ids from here
    /// up. The owner hands them out, so a slot outlives nothing it does not
    /// know about.
    static let itemSlotBase: UInt32 = 100

    private var hotKeyRefs: [Slot: EventHotKeyRef] = [:]
    private var itemRefs: [UInt32: EventHotKeyRef] = [:]
    var onItemTrigger: ((UInt32) -> Void)?
    private var handlerRef: EventHandlerRef?
    private let onTrigger: (Slot) -> Void

    init(onTrigger: @escaping (Slot) -> Void) {
        self.onTrigger = onTrigger
    }

    // No deinit: the manager lives for the app's lifetime (owned by AppState);
    // register(_:slot:) unregisters that slot's previous hotkey on every change.

    /// False when the combo is already held elsewhere (RegisterEventHotKey
    /// refuses a duplicate) — the General row tells the user to pick another.
    @discardableResult
    func register(_ spec: HotkeySpec?, slot: Slot) -> Bool {
        unregister(slot)
        guard let spec, !spec.isOff else { return true }
        installHandlerIfNeeded()

        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x4E4F4F4B) /* PELMET */, id: slot.rawValue)
        let status = RegisterEventHotKey(
            spec.keyCode,
            spec.modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        if status != noErr {
            PelmetLog.log("hotkey: \(spec.display) (\(slot)) not registered (status \(status)) — held by another app?")
            return false
        }
        hotKeyRefs[slot] = ref
        return true
    }

    /// False when the combo is held elsewhere, as for `register`.
    @discardableResult
    func registerItem(_ spec: HotkeySpec, slot: UInt32) -> Bool {
        unregisterItem(slot: slot)
        installHandlerIfNeeded()
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x4E4F4F4B), id: slot)
        let status = RegisterEventHotKey(
            spec.keyCode, spec.modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref
        )
        if status != noErr {
            PelmetLog.log("hotkey: \(spec.display) (item slot \(slot)) not registered (status \(status)) — held by another app?")
            return false
        }
        itemRefs[slot] = ref
        return true
    }

    func unregisterItem(slot: UInt32) {
        if let ref = itemRefs.removeValue(forKey: slot) {
            UnregisterEventHotKey(ref)
        }
    }

    /// Fire when the key comes up, not down. Control Center closes on its
    /// shortcut's key-up even while it refuses to open: pressed on key-down,
    /// its panel opened ~230ms in and shut again as a finger held past that
    /// let go, 8 of 8 holds from 250ms (#179, 2026-11-25).
    private static let onRelease: Set<Slot> = [.controlCenter]

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        let selfPointer = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let userData, let event else { return noErr }
                var hotKeyID = EventHotKeyID()
                GetEventParameter(
                    event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                    nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID
                )
                let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
                let id = hotKeyID.id
                let released = GetEventKind(event) == UInt32(kEventHotKeyReleased)
                if let slot = Slot(rawValue: id) {
                    guard released == HotkeyManager.onRelease.contains(slot) else { return noErr }
                    DispatchQueue.main.async { manager.onTrigger(slot) }
                } else if id >= HotkeyManager.itemSlotBase, !released {
                    DispatchQueue.main.async { manager.onItemTrigger?(id) }
                }
                return noErr
            },
            eventTypes.count,
            &eventTypes,
            selfPointer,
            &handlerRef
        )
    }

    private func unregister(_ slot: Slot) {
        if let ref = hotKeyRefs.removeValue(forKey: slot) {
            UnregisterEventHotKey(ref)
        }
    }
}
