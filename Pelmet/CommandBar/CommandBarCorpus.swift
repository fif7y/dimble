// CommandBarCorpus.swift
// Everything the command bar can offer, built once when it opens (candidates
// fold their text in init, so the per-keystroke work is only ranking): the
// bar's items and the launchers of apps that are not running, Pelmet's
// commands, and the setting rows. Each candidate carries what Return does
// with it and the glyph its row draws.

import AppKit
import PelmetCore
import PelmetEngine

enum CommandBarCommand: Equatable {
    case toggleHidden, showAll, editLayout
    case animation(RevealAnimation)
    case checkForUpdates, settings, quit

    /// Stable key for history and logs.
    var key: String {
        switch self {
        case .toggleHidden: "toggle"
        case .showAll: "showAll"
        case .editLayout: "editLayout"
        case .animation(let style): "animation.\(style.rawValue)"
        case .checkForUpdates: "checkForUpdates"
        case .settings: "settings"
        case .quit: "quit"
        }
    }
}

struct CommandBarEntry {
    enum Action {
        case item(ItemID)
        case launcher(bundleID: String)
        case command(CommandBarCommand)
        /// `row` is the `SettingsIndex` id Settings scrolls to.
        case setting(SettingsTab, row: String)
    }

    let candidate: SearchCandidate
    let action: Action
    let glyph: CommandBarRow.Glyph
    /// The third-party app behind an item, for its Open / Quit actions. Nil
    /// for Apple's own icons and Pelmet's.
    var app: ItemMenuActions.ItemApp?
    /// The bar item an item row was built from, in full: two icons of one
    /// app share the section key the candidate and the action carry.
    var itemID: ItemID?

    func with(candidate: SearchCandidate) -> CommandBarEntry {
        CommandBarEntry(candidate: candidate, action: action, glyph: glyph, app: app, itemID: itemID)
    }

    var isItem: Bool {
        if case .item = action { return true }
        return false
    }
}

@MainActor
enum CommandBarCorpus {
    // Items first, then what only stands in for one. Equal matches keep this
    // order, and a command must match clearly better to pass an item.
    static let launcherWeight = 0.9
    static let commandWeight = 0.8
    static let settingWeight = 0.7

    static func build(appState: AppState) -> [CommandBarEntry] {
        let items = itemEntries(appState)
        return items + launcherEntries(appState, representedBy: items) + commandEntries(appState) + settingEntries()
    }

    /// What the panel reads of it: the items and the launchers, to rank its
    /// tiles and name them. The panel draws its own pictures and has no use
    /// for commands or settings, so the glyphs (an icon looked up per app)
    /// and those rows are left out.
    static func buildForPanel(appState: AppState) -> [CommandBarEntry] {
        let items = itemEntries(appState, drawsGlyphs: false)
        return items + launcherEntries(appState, representedBy: items, drawsGlyphs: false)
    }

    /// The glyph of an entry built without them, which nothing draws.
    private static let noGlyph = CommandBarRow.Glyph.symbol("app.dashed")

    // MARK: - Items

    /// Hidden first, then Always Hidden, then visible: with no history the
    /// rest state shows the first of them, and a tie keeps this order. The
    /// editor's board is the source (live items, the concealed ones that
    /// left the AX tree, own extras), so a name is never one the editor
    /// doesn't use.
    private static func itemEntries(_ appState: AppState, drawsGlyphs: Bool = true) -> [CommandBarEntry] {
        var out: [CommandBarEntry] = []
        for section in [PelmetCore.Section.hidden, .alwaysHidden, .visible] {
            for item in appState.editorItems(in: section) {
                if !ItemMenuActions.canAlias(item.id) { continue }
                let key = item.id.sectionKey
                let title = ItemNaming.displayName(for: item)
                let app = ItemNaming.usableAppName(item.appName, bundle: item.id.bundleID)
                let subtitle = app.flatMap { $0.caseInsensitiveCompare(title) == .orderedSame ? nil : $0 }
                let candidate = SearchCandidate(
                    id: key.rawValue,
                    kind: .item,
                    title: title,
                    subtitle: subtitle,
                    keywords: Synonyms.keywords(title: title, bundleID: synonymBundle(of: item.id)),
                    alias: appState.settings.itemAliases[key.rawValue],
                    section: section
                )
                var entry = CommandBarEntry(candidate: candidate, action: .item(key), glyph: drawsGlyphs ? glyph(for: item) : noGlyph)
                entry.app = ItemMenuActions.app(for: item)
                entry.itemID = item.id
                out.append(entry)
            }
        }
        return out
    }

    /// Apple's items carry their identity in the title segment
    /// (`com.apple.menuextra.wifi`), which is what the synonym table reads.
    private static func synonymBundle(of id: ItemID) -> String? {
        if case .status(_, let title) = id.parsed, title.hasPrefix("com.apple.") { return title }
        return id.bundleID
    }

    private static func glyph(for item: ObservedItem) -> CommandBarRow.Glyph {
        if let system = MenuBarPolicy.systemItem(for: item.id) {
            return .symbol(symbol(for: system))
        }
        if let image = ItemImageCache.icon(for: item.id) {
            return .image(image)
        }
        if let bundle = item.id.bundleID, let icon = appIcon(bundle) {
            return .image(icon)
        }
        return .symbol(pick("questionmark.app.dashed", "app.dashed"))
    }

    /// The glyph a system icon gets wherever Pelmet draws one by symbol (search
    /// rows, Show when it matters).
    static func symbol(for system: SystemItem) -> String {
        switch system {
        case .battery: "battery.75percent"
        case .bluetooth: pick("bluetooth", "antenna.radiowaves.left.and.right")
        case .clock: "clock"
        case .displays: "display"
        case .keyboard: "keyboard"
        case .volume: "speaker.wave.2"
        case .wifi: "wifi"
        case .screenMirroring: "rectangle.on.rectangle"
        case .primaryBentoBox: pick("switch.2", "slider.horizontal.3")
        }
    }

    // MARK: - Launchers

    /// Apps that were once in a section and have no icon in the bar now
    /// because they are not running: opening one brings the icon back.
    private static func launcherEntries(
        _ appState: AppState, representedBy items: [CommandBarEntry], drawsGlyphs: Bool = true
    ) -> [CommandBarEntry] {
        let represented = Set(items.compactMap { entry -> String? in
            if case .item(let id) = entry.action { return id.bundleID }
            return nil
        })
        var seen = Set<String>()
        var out: [CommandBarEntry] = []
        for key in appState.settings.sectionModel.assignments.keys {
            guard let bundle = key.bundleID, !represented.contains(bundle), seen.insert(bundle).inserted,
                  bundle != PelmetBundle.mainID, bundle != PelmetBundle.fallbackID,
                  !PelmetBundle.helperIDs.contains(bundle),
                  !MenuBarPolicy.isUnmanagedAppleBundle(bundle),
                  NSRunningApplication.runningApplications(withBundleIdentifier: bundle).isEmpty,
                  let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle)
            else { continue }
            let name = FileManager.default.displayName(atPath: url.path)
            let candidate = SearchCandidate(
                id: "launcher:\(bundle)",
                kind: .launcher,
                title: name,
                subtitle: String(localized: "Not running"),
                weight: launcherWeight
            )
            out.append(CommandBarEntry(
                candidate: candidate,
                action: .launcher(bundleID: bundle),
                glyph: drawsGlyphs ? .image(NSWorkspace.shared.icon(forFile: url.path)) : noGlyph
            ))
        }
        return out.sorted { $0.candidate.title.localizedCaseInsensitiveCompare($1.candidate.title) == .orderedAscending }
    }

    private static func appIcon(_ bundle: String) -> NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    // MARK: - Commands

    private static func commandEntries(_ appState: AppState) -> [CommandBarEntry] {
        func command(_ command: CommandBarCommand, _ title: String, _ symbol: String, _ keywords: [String]) -> CommandBarEntry {
            CommandBarEntry(
                candidate: SearchCandidate(
                    id: "command:\(command.key)", kind: .command, title: title,
                    keywords: keywords, weight: commandWeight
                ),
                action: .command(command),
                glyph: .symbol(symbol)
            )
        }
        let animation = String(localized: "Animation")
        func animationCommand(_ style: RevealAnimation, _ name: String) -> CommandBarEntry {
            command(.animation(style), "\(animation) ▸ \(name)", pick("wand.and.stars", "sparkles"),
                    ["reveal", "transition", "style", "speed"])
        }
        let revealed = appState.sectionsRevealed
        return [
            command(.toggleHidden,
                    revealed ? String(localized: "Hide Items") : String(localized: "Show Hidden Items"),
                    revealed ? "eye.slash" : "eye",
                    revealed ? ["conceal", "collapse", "rehide"] : ["reveal", "expand", "icons"]),
            command(.showAll, String(localized: "Show Always Hidden Too"), pick("eyes", "eye"),
                    ["reveal", "everything", "show all", "icons"]),
            command(.editLayout, String(localized: "Edit Layout"), "slider.horizontal.3",
                    ["arrange", "order", "editor", "menu bar", "move"]),
            animationCommand(.instant, String(localized: "Instant")),
            animationCommand(.smooth, String(localized: "Smooth")),
            animationCommand(.fade, String(localized: "Fade")),
            command(.checkForUpdates, String(localized: "Check for Updates"), "arrow.triangle.2.circlepath",
                    ["update", "upgrade", "new version"]),
            command(.settings, String(localized: "Dimble Settings"), "gearshape",
                    ["preferences", "prefs", "options"]),
            command(.quit, String(localized: "Quit Dimble"), "power", ["exit", "close"]),
        ]
    }

    // MARK: - Settings

    private static func settingEntries() -> [CommandBarEntry] {
        SettingsIndex.entries().map { entry in
            CommandBarEntry(
                candidate: SearchCandidate(
                    id: "setting:\(entry.id)", kind: .setting, title: entry.title,
                    subtitle: SettingsIndex.tabName(entry.tab), keywords: entry.keywords,
                    weight: settingWeight
                ),
                action: .setting(entry.tab, row: entry.id),
                glyph: .symbol("gearshape")
            )
        }
    }

    // MARK: - Symbols

    /// The first SF Symbol the system has: a glyph one release lacks must not
    /// leave a hole in the row.
    static func pick(_ names: String...) -> String {
        names.first { NSImage(systemSymbolName: $0, accessibilityDescription: nil) != nil } ?? names[names.count - 1]
    }
}
