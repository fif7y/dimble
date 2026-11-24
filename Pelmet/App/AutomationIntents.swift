// AutomationIntents.swift
// Dimble's Shortcuts actions (#169): read the layout, move an icon, add or
// remove a separator, show or hide the icons, open Search. They run inside the app (Shortcuts
// launches it if it isn't running) and go through `Automation`.

import AppIntents
import PelmetCore
import PelmetEngine

nonisolated enum MenuBarSectionAppEnum: String, AppEnum {
    case visible, hidden, alwaysHidden

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Section" }
    static var caseDisplayRepresentations: [Self: DisplayRepresentation] {
        [.visible: "Visible", .hidden: "Hidden", .alwaysHidden: "Always Hidden"]
    }

    var section: PelmetCore.Section {
        switch self {
        case .visible: .visible
        case .hidden: .hidden
        case .alwaysHidden: .alwaysHidden
        }
    }
}

nonisolated struct MenuBarIconEntity: AppEntity {
    /// The section key, the id Get Menu Bar Layout prints.
    let id: String
    let name: String
    let section: MenuBarSectionAppEnum

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Menu Bar Icon" }
    static var defaultQuery: MenuBarIconQuery { MenuBarIconQuery() }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: section.localizedStringResource)
    }
}

nonisolated struct MenuBarIconQuery: EntityStringQuery {
    @MainActor
    private func all() async throws -> [MenuBarIconEntity] {
        let appState = try await Automation.ready()
        return Automation.icons(appState).map { icon in
            MenuBarIconEntity(
                id: icon.key.rawValue,
                name: icon.name,
                section: MenuBarSectionAppEnum(rawValue: icon.section.rawValue) ?? .visible
            )
        }
    }

    @MainActor
    func entities(for identifiers: [String]) async throws -> [MenuBarIconEntity] {
        let icons = try await all()
        return identifiers.compactMap { id in icons.first { $0.id == id } }
    }

    /// Typed text, matched the way a link's is (`IconMatch`). Two that match
    /// both come back: Shortcuts asks which one.
    @MainActor
    func entities(matching string: String) async throws -> [MenuBarIconEntity] {
        let icons = try await all()
        let found = Set(IconMatch.matches(string, in: icons.map { .init(name: $0.name, id: $0.id) }).map(\.id))
        return icons.filter { found.contains($0.id) }
    }

    @MainActor
    func suggestedEntities() async throws -> [MenuBarIconEntity] {
        try await all()
    }
}

/// A separator, named by its neighbour ("Separator after Tailscale"): they
/// all look the same, so a list of them by name alone is no help.
nonisolated struct MenuBarSeparatorEntity: AppEntity {
    let id: String
    let name: String

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Separator" }
    static var defaultQuery: MenuBarSeparatorQuery { MenuBarSeparatorQuery() }

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

nonisolated struct MenuBarSeparatorQuery: EntityQuery {
    @MainActor
    private func all() async throws -> [MenuBarSeparatorEntity] {
        let appState = try await Automation.ready()
        return Automation.board(appState).filter { $0.key.isPelmetSeparator }.map {
            MenuBarSeparatorEntity(id: $0.key.rawValue, name: Automation.separatorName($0.key, appState))
        }
    }

    @MainActor
    func entities(for identifiers: [String]) async throws -> [MenuBarSeparatorEntity] {
        let separators = try await all()
        return identifiers.compactMap { id in separators.first { $0.id == id } }
    }

    @MainActor
    func suggestedEntities() async throws -> [MenuBarSeparatorEntity] {
        try await all()
    }
}

nonisolated struct GetMenuBarLayoutIntent: AppIntent {
    static var title: LocalizedStringResource { "Get Menu Bar Layout" }
    static var description: IntentDescription {
        IntentDescription("The icons in Visible, Hidden and Always Hidden, in order from left to right, as JSON.")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let appState = try await Automation.ready()
        PelmetLog.log("action: get layout")
        return .result(value: Automation.layout(appState).json())
    }
}

struct MoveMenuBarIconIntent: AppIntent {
    static var title: LocalizedStringResource { "Move Menu Bar Icon" }
    static var description: IntentDescription {
        IntentDescription("Moves an icon to Visible, Hidden or Always Hidden. Give it an icon to follow and it goes right after that one.")
    }

    @Parameter(title: "Icon") var icon: MenuBarIconEntity
    @Parameter(title: "Section") var section: MenuBarSectionAppEnum
    @Parameter(title: "After") var after: MenuBarIconEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Move \(\.$icon) to \(\.$section)") { \.$after }
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let appState = try await Automation.ready()
        PelmetLog.log("action: move")
        try await Automation.settled(appState)
        try Automation.move(ItemID(rawValue: icon.id), to: section.section, place: after.map { .after($0.id) }, appState: appState)
        return .result()
    }
}

struct AddSeparatorIntent: AppIntent {
    static var title: LocalizedStringResource { "Add Separator" }
    static var description: IntentDescription {
        IntentDescription("Adds a separator to a section, at the chevron end or right after an icon.")
    }

    @Parameter(title: "Section") var section: MenuBarSectionAppEnum
    @Parameter(title: "After") var after: MenuBarIconEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Add a separator to \(\.$section)") { \.$after }
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let appState = try await Automation.ready()
        PelmetLog.log("action: add separator")
        try await Automation.addSeparator(to: section.section, place: after.map { .after($0.id) }, appState: appState)
        return .result()
    }
}

struct RemoveSeparatorIntent: AppIntent {
    static var title: LocalizedStringResource { "Remove Separator" }
    static var description: IntentDescription {
        IntentDescription("Removes a separator from the menu bar.")
    }

    @Parameter(title: "Separator") var separator: MenuBarSeparatorEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Remove \(\.$separator)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let appState = try await Automation.ready()
        PelmetLog.log("action: remove separator")
        try await Automation.settled(appState)
        try Automation.removeSeparator(id: separator.id, place: nil, appState: appState)
        return .result()
    }
}

struct ShowHiddenIconsIntent: AppIntent {
    static var title: LocalizedStringResource { "Show Hidden Icons" }
    static var description: IntentDescription {
        IntentDescription("Shows the Hidden icons, and the Always Hidden ones too if you turn that on.")
    }

    @Parameter(title: "Always Hidden too", default: false) var alwaysHidden: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Show hidden icons") { \.$alwaysHidden }
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let appState = try await Automation.ready()
        PelmetLog.log("action: show\(alwaysHidden ? " all" : "")")
        appState.reveal(alwaysHidden ? [.hidden, .alwaysHidden] : [.hidden], reason: .hotkey)
        return .result()
    }
}

nonisolated struct HideIconsIntent: AppIntent {
    static var title: LocalizedStringResource { "Hide Icons" }
    static var description: IntentDescription {
        IntentDescription("Puts away the icons that are out.")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let appState = try await Automation.ready()
        PelmetLog.log("action: hide")
        appState.concealNow()
        return .result()
    }
}

struct SearchMenuBarIntent: AppIntent {
    static var title: LocalizedStringResource { "Search Menu Bar" }
    static var description: IntentDescription {
        IntentDescription("Opens Dimble's search, with this text typed in.")
    }

    @Parameter(title: "Text") var text: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Search the menu bar for \(\.$text)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let appState = try await Automation.ready()
        PelmetLog.log("action: search")
        appState.commandBar.open(source: "action", query: text.map { String($0.prefix(AutomationLink.maxQueryLength)) })
        return .result()
    }
}

// Actions only, no links: a page could open a link, and these rearrange the
// whole bar, click an icon or change a setting.

struct SetMenuBarLayoutIntent: AppIntent {
    static var title: LocalizedStringResource { "Set Menu Bar Layout" }
    static var description: IntentDescription {
        IntentDescription("Puts the icons where a layout from Get Menu Bar Layout has them. Icons it leaves out stay in their section. Gives back the icons it names that aren't in the menu bar.")
    }

    @Parameter(title: "Layout", inputOptions: String.IntentInputOptions(multiline: true)) var layout: String

    static var parameterSummary: some ParameterSummary {
        Summary("Set the menu bar layout to \(\.$layout)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[String]> {
        let appState = try await Automation.ready()
        PelmetLog.log("action: set layout")
        return .result(value: try await Automation.setLayout(layout, appState: appState))
    }
}

struct AreIconsShownIntent: AppIntent {
    static var title: LocalizedStringResource { "Are Icons Shown" }
    static var description: IntentDescription {
        IntentDescription("Whether a section's icons are out. Visible's always are.")
    }

    @Parameter(title: "Section", default: .hidden) var section: MenuBarSectionAppEnum

    static var parameterSummary: some ParameterSummary {
        Summary("Are the \(\.$section) icons shown")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Bool> {
        let appState = try await Automation.ready()
        let shown = Automation.isShown(section.section, appState)
        PelmetLog.log("action: is \(section.rawValue) shown → \(shown)")
        return .result(value: shown)
    }
}

struct OpenMenuBarIconIntent: AppIntent {
    static var title: LocalizedStringResource { "Open Menu Bar Icon" }
    static var description: IntentDescription {
        IntentDescription("Opens an icon's menu, the way a click on it does, wherever the icon is.")
    }

    @Parameter(title: "Icon") var icon: MenuBarIconEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Open \(\.$icon)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let appState = try await Automation.ready()
        PelmetLog.log("action: open icon")
        appState.openItemMenu(try Automation.barItem(icon.id, appState))
        return .result()
    }
}

struct ShowMenuBarIconIntent: AppIntent {
    static var title: LocalizedStringResource { "Show Icon in Menu Bar" }
    static var description: IntentDescription {
        IntentDescription("Brings one icon out into the menu bar on its own, the way Show in Menu Bar does in Search.")
    }

    @Parameter(title: "Icon") var icon: MenuBarIconEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Show \(\.$icon) in the menu bar")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let appState = try await Automation.ready()
        PelmetLog.log("action: show icon")
        appState.showItemInBar(try Automation.barItem(icon.id, appState))
        return .result()
    }
}

/// The settings an action may change: ones you'd switch for a while (a
/// talk, a recording) and back, named as Settings names them.
nonisolated enum DimbleSettingAppEnum: String, AppEnum {
    case revealOnHover, revealOnClick

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Setting" }
    static var caseDisplayRepresentations: [Self: DisplayRepresentation] {
        [.revealOnHover: "Reveal on hover", .revealOnClick: "Reveal on click in empty space"]
    }
}

struct ChangeDimbleSettingIntent: AppIntent {
    static var title: LocalizedStringResource { "Change Dimble Setting" }
    static var description: IntentDescription {
        IntentDescription("Turns a Dimble setting on or off.")
    }

    @Parameter(title: "Setting") var setting: DimbleSettingAppEnum
    @Parameter(title: "Turn On", default: false) var on: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Change \(\.$setting)") { \.$on }
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let appState = try await Automation.ready()
        PelmetLog.log("action: \(setting.rawValue) \(on ? "on" : "off")")
        switch setting {
        case .revealOnHover: appState.settings.revealTriggers.hoverEnabled = on
        case .revealOnClick: appState.settings.revealTriggers.clickEnabled = on
        }
        appState.settingsChanged()
        return .result()
    }
}

nonisolated struct DimbleShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SearchMenuBarIntent(),
            phrases: ["Search the menu bar with \(.applicationName)"],
            shortTitle: "Search Menu Bar",
            systemImageName: "magnifyingglass"
        )
        AppShortcut(
            intent: ShowHiddenIconsIntent(),
            phrases: ["Show hidden icons with \(.applicationName)"],
            shortTitle: "Show Hidden Icons",
            systemImageName: "eye"
        )
        AppShortcut(
            intent: GetMenuBarLayoutIntent(),
            phrases: ["Get the \(.applicationName) layout"],
            shortTitle: "Get Menu Bar Layout",
            systemImageName: "menubar.rectangle"
        )
    }
}
