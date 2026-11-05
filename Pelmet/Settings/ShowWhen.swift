// ShowWhen.swift
// "Show when it matters" (#86) on Settings › Menu Bar: hidden icons that come
// back on the bar while their state matters. The card lists every icon that
// can, and a tile in the editor offers the same choice from its popover. Both
// read and write through `ShowWhenRule`, so they can't disagree.

import AppKit
import PelmetCore
import SwiftUI

/// What an icon waits for before it comes back.
enum ShowWhenCondition: Hashable {
    case onBattery, below20
    case wifiDrops, wifiDropsOrHotspot
    case focusOn
    case backingUp

    var label: LocalizedStringKey {
        switch self {
        case .onBattery: "On battery power"
        case .below20: "Below \(BatteryShowCondition.lowCharge)%"
        case .wifiDrops: "When it drops"
        case .wifiDropsOrHotspot: "When it drops or on a hotspot"
        case .focusOn: "While a Focus is on"
        case .backingUp: "While backing up"
        }
    }
}

/// The icons a rule can bring back: Apple's Battery and Wi-Fi, and Pelmet's
/// Focus and Time Machine. Media controls isn't one: like the camera
/// indicator it comes and goes while in use, wherever it sits (its own row).
enum ShowWhenSubject: CaseIterable, Hashable {
    case battery, wifi, focus, timeMachine

    /// The subject an editor tile stands for, if it has a rule. Apple's are
    /// read the way the rest of Pelmet reads system icons, not by one exact
    /// tag.
    init?(_ id: ItemID) {
        switch MenuBarPolicy.systemItem(for: id) {
        case .battery: self = .battery
        case .wifi: self = .wifi
        default:
            switch id.pelmetItem {
            case .focus: self = .focus
            case .timeMachine: self = .timeMachine
            default: return nil
            }
        }
    }

    /// Apple's own icons, which can be missing from the bar or sit in Visible.
    var appleItem: ItemID? {
        switch self {
        case .battery: ShowRules.battery
        case .wifi: ShowRules.wifi
        case .focus, .timeMachine: nil
        }
    }

    /// Pelmet's own item behind a row, which only has one while it is on.
    var kind: ExtraKind? {
        switch self {
        case .battery, .wifi: nil
        case .focus: .focus
        case .timeMachine: .timeMachine
        }
    }

    /// Whether the card and the editor tile offer this rule: Battery and
    /// Wi-Fi always, a Pelmet item while it is on, unless its row shows it
    /// only while active (it comes out on its own already).
    func offersRule(_ items: [ExtraItemSpec]) -> Bool {
        guard let kind else { return true }
        return items.contains { $0.kind == kind && !$0.isOnlyWhileActive }
    }

    /// The glyph search and the extras draw for the same icon.
    var symbol: String {
        switch self {
        case .battery: CommandBarCorpus.symbol(for: .battery)
        case .wifi: CommandBarCorpus.symbol(for: .wifi)
        case .focus: ExtrasManager.symbol(for: ExtraItemSpec(kind: .focus))
        case .timeMachine: ExtrasManager.symbol(for: ExtraItemSpec(kind: .timeMachine))
        }
    }

    var title: LocalizedStringKey {
        switch self {
        case .battery: "Battery"
        case .wifi: "Wi-Fi"
        case .focus: "Focus"
        case .timeMachine: "Time Machine"
        }
    }

    /// The name inside a sentence.
    var name: String {
        switch self {
        case .battery: String(localized: "Battery")
        case .wifi: "Wi-Fi"
        case .focus: String(localized: "Focus")
        case .timeMachine: String(localized: "Time Machine")
        }
    }

    var conditions: [ShowWhenCondition] {
        switch self {
        case .battery: [.onBattery, .below20]
        case .wifi: [.wifiDrops, .wifiDropsOrHotspot]
        case .focus: [.focusOn]
        case .timeMachine: [.backingUp]
        }
    }
}

/// One icon's rule, read and written in the settings.
@MainActor
struct ShowWhenRule {
    let subject: ShowWhenSubject
    let appState: AppState

    private var specIndex: Int? {
        subject.kind.flatMap { kind in appState.settings.extraItems.firstIndex { $0.kind == kind } }
    }

    /// What the person chose, whether or not it can apply right now.
    var isOn: Bool {
        switch subject {
        case .battery: appState.settings.showRules.batteryOn
        case .wifi: appState.settings.showRules.wifiOn
        case .focus, .timeMachine:
            specIndex.map { appState.settings.extraItems[$0].resolvedShowRule == .whenActive } ?? false
        }
    }

    /// The condition in force when it is on, kept while it is off. Only
    /// Battery and Wi-Fi have a choice of them.
    var condition: ShowWhenCondition {
        switch subject {
        case .battery: appState.settings.showRules.batteryCondition == .below20 ? .below20 : .onBattery
        case .wifi: appState.settings.showRules.wifiHotspot ? .wifiDropsOrHotspot : .wifiDrops
        case .focus, .timeMachine: subject.conditions[0]
        }
    }

    /// An icon in Visible has nothing to come back from, and an Apple one
    /// that isn't in the bar has nothing to bring. Pelmet's own items are in
    /// the bar whenever they are on.
    var availability: ShowRuleAvailability {
        if let id = subject.appleItem {
            return ShowRuleAvailability(
                inMenuBar: appState.isInMenuBar(id),
                section: appState.settings.sectionModel.section(of: id)
            )
        }
        guard let index = specIndex else { return .applies }
        return ShowRuleAvailability(
            inMenuBar: true,
            section: appState.settings.sectionModel.section(of: ExtrasManager.itemID(for: appState.settings.extraItems[index]))
        )
    }

    /// On and able to apply: what the card shows as on, and the tile marks.
    var isActive: Bool { isOn && availability == .applies }

    func setOn(_ on: Bool) {
        write(on: on, condition: nil)
    }

    /// Picks the condition without touching the switch.
    func setCondition(_ condition: ShowWhenCondition) {
        write(on: nil, condition: condition)
    }

    /// The tile popover's pick: this condition, and on.
    func choose(_ condition: ShowWhenCondition) {
        write(on: true, condition: condition)
    }

    /// The `.inVisible` way out: the icon moves to Hidden, where the rule
    /// can bring it back, and the rule goes on. A Focus item added to
    /// Visible greyed the switch out with no way forward but the editor
    /// (#92).
    func moveToHidden() {
        guard let id = subject.appleItem ?? specIndex.map({ ExtrasManager.itemID(for: appState.settings.extraItems[$0]) }) else { return }
        appState.moveItemNow(id, to: .hidden)
        write(on: true, condition: nil)
    }

    private func write(on: Bool?, condition: ShowWhenCondition?) {
        switch subject {
        case .battery:
            if let on { appState.settings.showRules.batteryOn = on }
            if let condition { appState.settings.showRules.batteryCondition = condition == .below20 ? .below20 : .onBattery }
        case .wifi:
            if let on { appState.settings.showRules.wifiOn = on }
            if let condition { appState.settings.showRules.wifiHotspot = condition == .wifiDropsOrHotspot }
        case .focus, .timeMachine:
            guard let on, let index = specIndex else { return }
            appState.settings.extraItems[index].showRule = on ? .whenActive : .always
        }
        appState.settingsChanged()
    }
}

// MARK: - Card

/// The last card on the tab: every icon that can come back on its own, with
/// the condition and a switch.
struct ShowWhenCard: View {
    @Environment(AppState.self) private var appState

    private var subjects: [ShowWhenSubject] {
        ShowWhenSubject.allCases.filter { $0.offersRule(appState.settings.extraItems) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CardHeader(
                symbol: "bolt.fill", title: "Show when it matters",
                caption: "Hidden icons that come back on their own"
            ) { EmptyView() }

            VStack(alignment: .leading, spacing: 12) {
                ForEach(subjects, id: \.self) { subject in
                    ShowWhenRow(rule: ShowWhenRule(subject: subject, appState: appState))
                }
            }
            .pelmetCardSurface()
        }
    }
}

private struct ShowWhenRow: View {
    let rule: ShowWhenRule
    /// Bumped when the icon's grace runs out, so the row reads it again.
    @State private var graceOver = 0

    var body: some View {
        let _ = graceOver
        let availability = rule.availability
        let applies = availability == .applies
        ItemRowShell(symbol: rule.subject.symbol, title: rule.subject.title) {
            if !applies {
                ShowWhenUnavailable(subject: rule.subject, availability: availability, moveToHidden: rule.moveToHidden)
            }
        } trailing: {
            condition
                .opacity(applies ? 1 : 0.5)
                .disabled(!applies)
            SettingSwitch(isOn: Binding(get: { rule.isActive }, set: rule.setOn))
                .disabled(!applies)
        }
        // Whether Battery or Wi-Fi is in the bar is read with a grace (an icon
        // in a gap isn't missing): the row looks again when it runs out, with
        // nothing else changing, and never otherwise (the card ticked every 4s
        // before, 2026-10-12).
        .task(id: graceEnd) {
            guard let graceEnd else { return }
            try? await Task.sleep(for: .seconds(max(0, graceEnd.timeIntervalSinceNow)))
            guard !Task.isCancelled else { return }
            graceOver += 1
        }
    }

    private var graceEnd: Date? { rule.subject.appleItem.flatMap(rule.appState.menuBarGraceEnds) }

    /// A choice of conditions is the settings' accent menu (the hover delay's
    /// recipe); a single one is just said.
    @ViewBuilder private var condition: some View {
        if rule.subject.conditions.count > 1 {
            PelmetMenuPicker(
                selection: Binding(get: { rule.condition }, set: { rule.setCondition($0) }),
                options: rule.subject.conditions.map { ($0, $0.label) },
                borderless: true, accent: true
            )
        } else {
            Text(rule.condition.label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// Why a rule can't apply and what to do about it. Nothing when it can.
struct ShowWhenUnavailable: View {
    let subject: ShowWhenSubject
    let availability: ShowRuleAvailability
    var moveToHidden: (() -> Void)?

    var body: some View {
        switch availability {
        case .applies:
            EmptyView()
        case .notInMenuBar:
            VStack(alignment: .leading, spacing: 2) {
                Text("\(subject.name) is off in System Settings › Menu Bar.")
                Button("Open Menu Bar Settings") { Self.openMenuBarSettings() }
                    .buttonStyle(.plain)
                    .foregroundStyle(PelmetAccent.accent)
            }
        case .inVisible:
            VStack(alignment: .leading, spacing: 2) {
                Text("\(subject.name) is in Visible, so it's always on the bar.")
                if let moveToHidden {
                    Button("Move to Hidden", action: moveToHidden)
                        .buttonStyle(.plain)
                        .foregroundStyle(PelmetAccent.accent)
                }
            }
        }
    }

    /// The Control Center settings extension is the one that hosts the Menu
    /// Bar pane.
    private static func openMenuBarSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.ControlCenter-Settings.extension")!)
    }
}

// MARK: - Tile popover

/// What an editor tile offers when it is clicked: when the icon shows up on
/// the bar (the same choice as the card, as a checkmark list) when it has a
/// rule, and a way to its shortcut in Settings › Search.
struct TilePopover: View {
    @Environment(AppState.self) private var appState
    let id: ItemID
    let name: String
    /// Nil for an icon with no rule: the header and the link are all it has.
    let rule: ShowWhenRule?
    let editAlias: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                TileGlyph(id: id)
                Text(name)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            if let rule {
                ruleChoices(rule)
            }
            Button(hasShortcut ? "Change shortcut…" : "Add a shortcut…", action: editAlias)
                .buttonStyle(.plain)
                .foregroundStyle(PelmetAccent.accent)
        }
        .padding(12)
        .frame(width: 240, alignment: .leading)
        // One signal per state: the checkmark marks the choice, no focus ring
        // competing with it (as in the separator options).
        .focusEffectDisabled()
    }

    private var hasShortcut: Bool { appState.settings.itemHotkeys[id.sectionKey.rawValue] != nil }

    @ViewBuilder private func ruleChoices(_ rule: ShowWhenRule) -> some View {
        let availability = rule.availability
        let applies = availability == .applies
        VStack(alignment: .leading, spacing: 2) {
            Text("Shows up on the bar")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.bottom, 2)
            choice(Text("Never"), selected: !rule.isActive) { rule.setOn(false) }
            ForEach(rule.subject.conditions, id: \.self) { condition in
                choice(Text(condition.label), selected: rule.isActive && rule.condition == condition) {
                    rule.choose(condition)
                }
            }
        }
        .disabled(!applies)
        if !applies {
            ShowWhenUnavailable(subject: rule.subject, availability: availability, moveToHidden: rule.moveToHidden)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        if rule.subject == .wifi {
            Text("Waits \(ShowRules.wifiGrace.components.seconds) seconds, so a wake or a roam doesn't flash it.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private func choice(_ label: Text, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(PelmetAccent.accent)
                    .opacity(selected ? 1 : 0)
                label
                Spacer(minLength: 0)
            }
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
