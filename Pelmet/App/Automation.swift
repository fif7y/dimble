// Automation.swift
// Dimble from outside the app (#146, #169): the dimble:// links and the
// Shortcuts actions (AutomationIntents.swift) both come through here, so a
// link and an action that do the same thing take the same path as the
// global shortcut or the editor move that does it.

import AppKit
import PelmetCore
import PelmetEngine

@MainActor
enum Automation {
    /// Set once at launch, before any link or action can arrive.
    static weak var appState: AppState?

    // MARK: - Links

    static func handle(_ url: URL) {
        guard let link = AutomationLink(url: url) else {
            PelmetLog.log("link: ignored \(url.scheme.map { String($0.prefix(20)) } ?? "?"):\(String((url.host ?? url.path).prefix(40)))")
            return
        }
        PelmetLog.log("link: \(link.name)\(NSApp.isActive ? ", Dimble brought forward" : "")")
        // A link can launch Dimble: it waits for the bar to be read, as an
        // action does, and one that changes the layout waits its turn.
        Task {
            await logFailureAsync {
                let appState = try await ready()
                switch link {
                case .search(let text): appState.commandBar.open(source: "link", query: text)
                case .show: appState.reveal([.hidden], reason: .hotkey)
                case .showAll: appState.reveal([.hidden, .alwaysHidden], reason: .hotkey)
                case .hide: appState.concealNow()
                case .toggle: appState.toggle(reason: .hotkey)
                case .move(let icon, let section, let place):
                    try await settled(appState)
                    try move(resolve(icon, appState), to: section, place: place, appState: appState)
                case .addSeparator(let section, let place):
                    try await addSeparator(to: section, place: place, appState: appState)
                case .removeSeparator(let id, let place):
                    try await settled(appState)
                    try removeSeparator(id: id, place: place, appState: appState)
                }
            }
            // Launched by the link, Dimble came forward before it was ready.
            handFocusBack()
        }
        handFocusBack()
        // The activation can land after the link does.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { handFocusBack() }
    }

    /// A link has no one to answer: what it couldn't do goes in the log.
    private static func logFailureAsync(_ work: () async throws -> Void) async {
        do { try await work() } catch { PelmetLog.log("link: not done, \(error)") }
    }

    /// A link opened the plain way (`open`, Alfred, a browser) brings Dimble
    /// to the front, and the app you were typing in lost its keys
    /// (2026-11-24). Nothing a link does needs Dimble in front: Search's
    /// panel takes keys without it, and takes them back once when the app
    /// returns (`CommandBarController.panelResignedKey`). A menu bar app in
    /// front keeps the bar on the app behind it, which is the one to return to.
    private static func handFocusBack() {
        guard NSApp.isActive, let owner = NSWorkspace.shared.menuBarOwningApplication,
              owner != .current else { return }
        PelmetLog.log("link: focus back to \(owner.bundleIdentifier ?? "pid \(owner.processIdentifier)")")
        owner.activate()
    }

    // MARK: - Actions

    /// The app as a link or an action finds it: launched a moment ago, the
    /// bar may not have been read yet. Before setup is done, nothing runs.
    static func ready() async throws -> AppState {
        for _ in 0..<100 {
            if let appState, appState.snapshot != nil {
                guard appState.settings.onboardingCompleted else { throw AutomationError.notReady }
                return appState
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw AutomationError.notReady
    }

    /// Before a change to the layout: an Apply already running is waited
    /// for (a second move right after a first), and edits of yours waiting
    /// in Settings › Menu Bar stop it, since Apply would lay down both.
    static func settled(_ appState: AppState) async throws {
        var waited = 0
        while appState.applying || changeInFlight, waited < 150 {
            try await Task.sleep(for: .milliseconds(100))
            waited += 1
        }
        guard !appState.applying, !changeInFlight else { throw AutomationError.busy }
        guard appState.settings.orderEdits.isEmpty else { throw AutomationError.editsWaiting }
    }

    /// A change that waits between its start and its Apply (a new
    /// separator being hosted): the next one waits for it in `settled`.
    private static var changeInFlight = false

    /// Settings › Menu Bar's board, section by section.
    static func layout(_ appState: AppState) -> LayoutExport {
        LayoutExport(sections: PelmetCore.Section.allCases.map { section in
            .init(section: section, items: appState.editorItems(in: section).map {
                .init(name: ItemNaming.displayName(for: $0), id: $0.id.sectionKey)
            })
        })
    }

    struct BoardItem {
        let item: ObservedItem
        let section: PelmetCore.Section
        var key: ItemID { item.id.sectionKey }
        var name: String { ItemNaming.displayName(for: item) }
    }

    /// Every tile the editor shows, left to right in each section. The
    /// chevron is never one.
    static func board(_ appState: AppState) -> [BoardItem] {
        PelmetCore.Section.allCases.flatMap { section in
            appState.editorItems(in: section).map { BoardItem(item: $0, section: section) }
        }
    }

    /// The icons a Shortcuts list offers: Search's, without the separators
    /// (they share one name; Remove Separator lists them its own way).
    static func icons(_ appState: AppState) -> [BoardItem] {
        board(appState).filter { ItemMenuActions.canAlias($0.item.id) }
    }

    /// The one icon `text` names (`IconMatch`). Two that match is a refusal:
    /// a link can't ask which one.
    static func resolve(_ text: String, _ appState: AppState) throws -> ItemID {
        let found = IconMatch.matches(text, in: board(appState).map { .init(name: $0.name, id: $0.key.rawValue) })
        switch found.count {
        case 0: throw AutomationError.noSuchIcon(text)
        case 1: return ItemID(rawValue: found[0].id)
        default: throw AutomationError.ambiguous(text)
        }
    }

    /// Where `place` puts something: the anchor's section, and the key it
    /// goes in front of (nil: the end of the section).
    private static func spot(_ place: AutomationLink.Place, moving: ItemID?, _ appState: AppState) throws -> (PelmetCore.Section, ItemID?) {
        let text = switch place { case .before(let t), .after(let t): t }
        let anchor = try resolve(text, appState)
        guard anchor != moving else { throw AutomationError.nextToItself }
        let section = appState.settings.sectionModel.section(of: anchor)
        let row = appState.editorItems(in: section).map(\.id.sectionKey).filter { $0 != moving }
        guard let index = row.firstIndex(of: anchor) else { throw AutomationError.noSuchIcon(text) }
        switch place {
        case .before: return (section, anchor)
        case .after: return (section, row.indices.contains(index + 1) ? row[index + 1] : nil)
        }
    }

    /// The same move as Search's ⌘K: to a section (Visible at its chevron
    /// end, the others at theirs), or next to an icon. A section that
    /// disagrees with the icon named is a mistake, not a choice.
    static func move(_ key: ItemID, to section: PelmetCore.Section?, place: AutomationLink.Place?, appState: AppState) throws {
        guard board(appState).contains(where: { $0.key == key }) else { throw AutomationError.noSuchIcon(key.rawValue) }
        guard !appState.isImmovable(key) else { throw AutomationError.cantMove }
        if let place {
            let (target, before) = try spot(place, moving: key, appState)
            if let section, section != target { throw AutomationError.notInSection }
            PelmetLog.log("automation: move \(key.rawValue) → \(target.rawValue) before \(before?.rawValue ?? "the end")")
            appState.moveItemNow(key, to: target, before: before, despiteDrift: true)
        } else if let section {
            guard appState.settings.sectionModel.section(of: key) != section else { return }
            PelmetLog.log("automation: move \(key.rawValue) → \(section.rawValue)")
            appState.moveItemNow(key, to: section, despiteDrift: true)
        }
    }

    /// A new separator at the chevron end of a section, or next to an icon.
    static func addSeparator(to section: PelmetCore.Section?, place: AutomationLink.Place?, appState: AppState) async throws {
        try await settled(appState)
        changeInFlight = true
        defer { changeInFlight = false }
        let target: PelmetCore.Section
        let before: ItemID?
        if let place {
            (target, before) = try spot(place, moving: nil, appState)
            if let section, section != target { throw AutomationError.notInSection }
        } else {
            target = section ?? .hidden
            before = target == .visible ? appState.editorItems(in: .visible).first?.id.sectionKey : nil
        }
        guard await appState.addSeparatorNow(in: target, before: before) != nil else { throw AutomationError.busy }
    }

    /// The separator with this id, or the one right next to an icon.
    static func removeSeparator(id: String?, place: AutomationLink.Place?, appState: AppState) throws {
        let key: ItemID
        if let id {
            key = try resolve(id, appState)
        } else if let place {
            let text = switch place { case .before(let t), .after(let t): t }
            let anchor = try resolve(text, appState)
            let row = appState.editorItems(in: appState.settings.sectionModel.section(of: anchor)).map(\.id.sectionKey)
            guard let index = row.firstIndex(of: anchor) else { throw AutomationError.noSuchIcon(text) }
            let next = if case .after = place { index + 1 } else { index - 1 }
            guard row.indices.contains(next) else { throw AutomationError.noSeparator }
            key = row[next]
        } else {
            throw AutomationError.noSeparator
        }
        guard key.isPelmetSeparator, appState.removeSeparator(key: key) else { throw AutomationError.noSeparator }
        PelmetLog.log("automation: separator \(key.rawValue) removed")
    }

    /// Set Menu Bar Layout: every icon the layout names where it says. An
    /// edit of yours waiting in the editor stops it, since the layout would
    /// mix with it and Apply would lay down both. Returns what the layout
    /// names that this bar doesn't have.
    static func setLayout(_ text: String, appState: AppState) async throws -> [String] {
        let layout: LayoutRestore.Layout
        do {
            layout = try LayoutRestore.read(text)
        } catch LayoutRestore.Failure.newerFormat {
            throw AutomationError.newerLayout
        } catch {
            throw AutomationError.notALayout
        }
        try await settled(appState)
        changeInFlight = true
        defer { changeInFlight = false }
        var board: [PelmetCore.Section: [LayoutRestore.BoardItem]] = [:]
        for item in Automation.board(appState) {
            board[item.section, default: []].append(.init(key: item.key, name: item.name))
        }
        let plan = LayoutRestore.plan(layout, board: board, movable: { !appState.isImmovable($0) })
        let missing = plan.missing.map(\.label)
        PelmetLog.log("automation: set layout, \(missing.count) not here \(missing.prefix(10).map { String($0.prefix(60)) })")
        guard await appState.setLayoutNow(plan) else { throw AutomationError.busy }
        return missing
    }

    /// Whether a section's icons are out. Visible always is.
    static func isShown(_ section: PelmetCore.Section, _ appState: AppState) -> Bool {
        section == .visible || appState.sectionsShown.contains(section)
    }

    /// The bar item a Shortcuts list picked, as the bar has it now: Search
    /// opens the real button, not its canonical key.
    static func barItem(_ id: String, _ appState: AppState) throws -> ItemID {
        guard let item = board(appState).first(where: { $0.key.rawValue == id }) else {
            throw AutomationError.noSuchIcon(id)
        }
        return item.item.id
    }

    /// What a separator is called in a Shortcuts list: by the icon on its
    /// left, else on its right, else its section.
    static func separatorName(_ key: ItemID, _ appState: AppState) -> String {
        let section = appState.settings.sectionModel.section(of: key)
        let row = appState.editorItems(in: section)
        guard let index = row.firstIndex(where: { $0.id.sectionKey == key }) else { return String(localized: "Separator") }
        if let left = row[..<index].last(where: { !$0.id.isPelmetSeparator }) {
            return String(localized: "Separator after \(ItemNaming.displayName(for: left))")
        }
        if let right = row[(index + 1)...].first(where: { !$0.id.isPelmetSeparator }) {
            return String(localized: "Separator before \(ItemNaming.displayName(for: right))")
        }
        return String(localized: "Separator")
    }
}

enum AutomationError: Error, CustomLocalizedStringResourceConvertible, CustomStringConvertible {
    case notReady, cantMove, notInSection, nextToItself, noSeparator
    case notALayout, newerLayout, editsWaiting, busy
    case noSuchIcon(String)
    case ambiguous(String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .notReady: "Dimble can't read the menu bar yet."
        case .noSuchIcon(let name): "There's no icon called \(name) in the menu bar."
        case .ambiguous(let name): "More than one icon is called \(name). Use its id from Get Menu Bar Layout."
        case .cantMove: "macOS doesn't let Dimble move that icon."
        case .notInSection: "The icon to put it next to is in another section."
        case .nextToItself: "An icon can't go next to itself."
        case .noSeparator: "There's no separator there."
        case .notALayout: "That isn't a menu bar layout. Use the text Get Menu Bar Layout gives back."
        case .newerLayout: "That layout is from a newer Dimble. Update Dimble to use it."
        case .editsWaiting: "Settings › Menu Bar has changes waiting. Apply or discard them first."
        case .busy: "Dimble is moving icons. Try again in a moment."
        }
    }

    /// For the log, in English.
    var description: String {
        switch self {
        case .notReady: "the bar isn't read yet"
        case .noSuchIcon(let name): "no icon called \"\(name)\""
        case .ambiguous(let name): "more than one icon called \"\(name)\""
        case .cantMove: "macOS doesn't let it move"
        case .notInSection: "the icon named is in another section"
        case .nextToItself: "next to itself"
        case .noSeparator: "no separator there"
        case .notALayout: "not a layout"
        case .newerLayout: "a newer layout format"
        case .editsWaiting: "the editor has edits waiting"
        case .busy: "an Apply is running"
        }
    }
}
