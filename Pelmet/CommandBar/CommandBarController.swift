// CommandBarController.swift
// Search the menu bar from the keyboard (docs/COMMAND-BAR.md). A shortcut
// opens a non-activating glass panel under the bar, key at once so the first
// letter lands in the field; the app you were in stays in front. Return
// closes the panel and then hands the pick to the press relay, which opens
// the item's own menu in the real bar.
//
// The corpus is built when the panel opens (candidates fold their text once),
// so a keystroke only ranks. Everything is logged under `search:` with its
// timings, so the budgets are read from the log.
//
// Settings › Search runs a second one, embedded: the same view and keys in
// the pane instead of a panel, its picks as real as the panel's. Its close
// puts it back at rest where it is, and it logs under `search demo:`.

import AppKit
import Carbon.HIToolbox
import PelmetCore
import PelmetEngine
import SwiftUI

@MainActor
final class CommandBarController {
    private weak var appState: AppState?
    private let model = CommandBarModel()
    private var panel: KeyableGlassPanel?
    /// Settings › Search's demo: no panel, the pane's window is the host.
    let embedded: Bool
    /// Panes showing the demo. A closed Settings window's pane can say it
    /// disappeared after a new one appeared, so the last one out turns it off.
    private var hosts = 0
    private var logTag: String { embedded ? "search demo" : "search" }

    private var candidates: [SearchCandidate] = []
    private var entries: [String: CommandBarEntry] = [:]

    /// What was picked, for ranking. Its own defaults key, never the
    /// settings blob.
    private var history: SearchHistory
    private static let historyKey = "app.fif7y.Pelmet.search.v1"
    private static let restRows = 5
    private static let resultRows = 20

    private(set) var isOpen = false
    private var openedAt = Date.distantPast
    /// Bumped by every open and close: a close's completion that finds it
    /// changed belongs to an earlier close and does nothing.
    private var generation = 0
    private var placement: (screen: NSScreen, right: CGFloat)?
    private var reKeyed = false
    /// The text a dimble:// link typed in (#146). Any page can open a link,
    /// so until the person changes that text Search lists icons only: a
    /// link can't line up Quit or a setting for the next Return.
    private var linkQuery: String?
    private var keyMonitor: Any?
    private var clickMonitor: Any?
    private var moveMonitors: [Any] = []
    private var resignObserver: NSObjectProtocol?
    private var becomeKeyObserver: NSObjectProtocol?
    private var announceTask: Task<Void, Never>?

    /// What the panel shows. ⌘K moves between the first two; the last two
    /// are the actions that ask for something instead of doing it.
    private enum Mode { case results, actions, shortcut, alias }
    private var mode = Mode.results
    /// The row whose actions are showing, and the actions it offers.
    private var actionsEntry: CommandBarEntry?
    private var actionItems: [CommandBarActionItem] = []
    /// The results' query and selected row, put back when ⌘K returns.
    private var resultsQuery = ""
    private var resultsSelectedID: String?

    init(appState: AppState, embedded: Bool = false) {
        self.appState = appState
        self.embedded = embedded
        history = Self.loadHistory()
        model.hidesSelectionUnfocused = embedded
        // The demo can be up before the bar was first read (Settings opened
        // at launch): it re-reads when someone comes to type.
        if embedded { model.onFieldFocus = { [weak self] in self?.refresh() } }
    }

    // MARK: - Open / close

    func toggle(source: String) {
        isOpen ? close(reason: source) : open(source: source)
    }

    /// Build the panel ahead of the first shortcut, so that one does not pay
    /// for the first SwiftUI pass.
    func warm() {
        _ = ensurePanel()
    }

    /// `query`: typed in for the person (Settings › Search's Try links).
    func open(source: String, query: String? = nil) {
        guard !embedded, !isOpen, let appState,
              let screen = NSScreen.underPointer ?? NSScreen.main ?? NSScreen.screens.first
        else { return }
        let started = ProcessInfo.processInfo.systemUptime
        func elapsed() -> Double { (ProcessInfo.processInfo.systemUptime - started) * 1000 }
        let panel = ensurePanel()

        generation += 1
        isOpen = true
        openedAt = .now
        reKeyed = false
        // `dimble://search` alone holds the recent picks the same way.
        linkQuery = source == "link" ? (query ?? "") : nil
        clearModel()
        placement = (screen, anchorRight(on: screen, appState: appState))
        // Reopened mid-exit it fades back in from where it is.
        if !panel.isVisible { panel.alphaValue = 0 }
        panel.ignoresMouseEvents = false
        panel.acceptsMouseMovedEvents = true
        panel.place(windowFrame(), display: false)
        panel.setGlassHeight(glassHeight(listHeight: 0))
        letMouseThroughOffGlass()

        // Key and focused in this turn, before anything slower: a letter
        // typed now waits in the queue and lands in the field.
        takeKey(panel)
        panel.contentView?.layoutSubtreeIfNeeded()
        panel.invalidateShadow()
        if !focusField() {
            DispatchQueue.main.async { [weak self] in
                guard self?.focusField() == true else {
                    PelmetLog.log("search: the field was not ready to take focus")
                    return
                }
                // Focused after the hover panel's typing tap looked at the
                // key window: letters typed over the panel went to the
                // panel's search until it looked again.
                NotificationCenter.default.post(name: HoverTypingTap.focusMoved, object: nil)
            }
        }
        let keyMs = elapsed()
        installMonitors()

        loadCorpus()
        let corpusMs = elapsed() - keyMs
        showRest()
        if let query, !query.isEmpty {
            model.field?.setText(query)
            queryChanged(query)
        }
        animateIn(panel)
        PelmetLog.log(String(
            format: "search: opened (%@) — key in %.1fms, %d candidates in %.1fms, %d rest row(s), ready at %.1fms",
            source, keyMs, candidates.count, corpusMs, model.rows.count, elapsed()
        ))
    }

    /// Fade out first; whatever the caller does next (an action) does not
    /// wait for it.
    func close(reason: String) {
        linkQuery = nil
        if embedded {
            settle(reason: reason)
            return
        }
        guard isOpen, let panel else { return }
        isOpen = false
        generation += 1
        let mine = generation
        removeMonitors()
        announceTask?.cancel()
        // The panel stays up for the length of its fade: a click on it
        // must not land, and a click beneath it must.
        panel.ignoresMouseEvents = true
        PelmetLog.log(String(format: "search: closed (%@) after %.1fs", reason, Date().timeIntervalSince(openedAt)))
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = AppTiming.searchExit
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.55, 0, 0.8, 0.4)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            // AppKit calls this on the main thread but does not say so.
            Task { @MainActor in self?.finishClose(mine) }
        })
    }

    private func finishClose(_ closedAt: Int) {
        guard closedAt == generation, !isOpen, let panel else { return }
        panel.orderOut(nil)
        panel.ignoresMouseEvents = false
        panel.alphaValue = 0
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { model.entered = false }
        model.rows = []
        resetMode()
    }

    /// Back to plain results with nothing of an earlier ⌘K left in the model.
    private func resetMode() {
        mode = .results
        actionsEntry = nil
        actionItems = []
        resultsQuery = ""
        resultsSelectedID = nil
        model.chip = nil
        model.input = nil
        model.inputMessage = nil
        model.placeholder = String(localized: "Search the menu bar")
    }

    private func clearModel() {
        model.query = ""
        model.completion = nil
        model.rows = []
        model.showsNoResults = false
        model.selected = 0
        model.field?.setText("")
        resetMode()
    }

    /// Candidates as the bar and settings are now, and the history as last
    /// saved: the panel and the demo each save what they learn.
    private func loadCorpus() {
        guard let appState else { return }
        history = Self.loadHistory()
        let built = CommandBarCorpus.build(appState: appState)
        candidates = built.map(\.candidate)
        entries = Dictionary(built.map { ($0.candidate.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    // MARK: - Embedded (Settings › Search)

    /// The view the demo shows, on the same model the keys drive.
    var view: CommandBarView {
        CommandBarView(
            model: model,
            onQueryChange: { [weak self] in self?.queryChanged($0) },
            onChoose: { [weak self] index, modifiers in self?.choose(index: index, modifiers: modifiers) }
        )
    }

    /// The glass's height for what the model shows: the panel's glass, and
    /// the demo's frame.
    var contentHeight: CGFloat {
        if model.input != nil { return CommandBarLayout.panelHeight(listHeight: CommandBarLayout.inputListHeight) }
        return CommandBarLayout.panelHeight(rows: model.rows.isEmpty ? (model.showsNoResults ? 1 : 0) : model.rows.count)
    }

    /// The pane is showing: at rest, keys taken while its field has focus.
    func activate() {
        guard embedded else { return }
        hosts += 1
        generation += 1
        isOpen = true
        openedAt = .now
        clearModel()
        model.dropOffset = 0
        model.entered = true
        installMonitors()
        loadCorpus()
        showRest()
        PelmetLog.log("\(logTag): active, \(candidates.count) candidates")
    }

    func deactivate() {
        guard embedded, isOpen else { return }
        hosts = max(0, hosts - 1)
        guard hosts == 0 else { return }
        isOpen = false
        generation += 1
        removeMonitors()
        announceTask?.cancel()
        clearModel()
    }

    /// Focus the field, typing `query` in for the person when given (the
    /// pane's Try links, the search shortcut while the pane is in front).
    func focus(query: String? = nil) {
        guard embedded, isOpen else { return }
        if query != nil, mode != .results { resetMode() }
        // Focus first: a field taking focus selects all its text, and the
        // query's caret belongs at its end. Already in the demo (an alias
        // half typed included), focus stays where it is.
        let focused: Bool
        if query == nil, demoHasFocus {
            focused = true
        } else if mode == .alias, let alias = model.aliasField?.field {
            focused = hostWindow?.makeFirstResponder(alias) ?? false
        } else {
            focused = focusField()
        }
        if let query {
            model.field?.setText(query)
            queryChanged(query)
        }
        if !focused {
            DispatchQueue.main.async { [weak self] in self?.focusField() }
        }
    }

    /// The pane's window is key with the demo in it: where the search
    /// shortcut lands instead of opening the panel.
    var isInFront: Bool {
        embedded && isOpen && model.field?.window?.isKeyWindow == true
    }

    /// Settings changed under the demo (an alias or a shortcut set in the
    /// list) or its window came back: re-read, unless someone is mid-search.
    func refresh() {
        guard embedded, isOpen, mode == .results, FoldedText.normalized(model.query).isEmpty else { return }
        loadCorpus()
        showRest()
    }

    /// The demo's close: back to rest where it is. The corpus is re-read
    /// after whatever the pick runs has started.
    private func settle(reason: String) {
        guard isOpen else { return }
        announceTask?.cancel()
        PelmetLog.log(String(format: "\(logTag): back to rest (%@) after %.1fs", reason, Date().timeIntervalSince(openedAt)))
        openedAt = .now
        clearModel()
        showRest()
        DispatchQueue.main.async { [weak self] in self?.refresh() }
    }

    /// The window the keys arrive in: the panel, or the pane's.
    private var hostWindow: NSWindow? { embedded ? model.field?.window : panel }

    /// The demo's own fields have focus, not the rest of the pane.
    private var demoHasFocus: Bool {
        guard let editor = hostWindow?.firstResponder as? NSTextView,
              let owner = editor.delegate as? NSTextField
        else { return false }
        return owner === model.field?.field || owner === model.aliasField?.field
    }

    private func animateIn(_ panel: KeyableGlassPanel) {
        // Reduce Motion keeps the fade and drops the 4pt travel.
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        model.dropOffset = reduced ? 0 : 4
        let curve = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = AppTiming.searchEntrance
            context.timingFunction = curve
            panel.animator().alphaValue = 1
        }
        withAnimation(.timingCurve(0.16, 1, 0.3, 1, duration: AppTiming.searchEntrance)) {
            model.entered = true
        }
    }

    private func ensurePanel() -> KeyableGlassPanel {
        if let panel { return panel }
        let hosting = NSHostingView(rootView: CommandBarView(
            model: model,
            onQueryChange: { [weak self] in self?.queryChanged($0) },
            onChoose: { [weak self] index, modifiers in self?.choose(index: index, modifiers: modifiers) }
        ))
        // The panel's frame is ours; the content must not resize it.
        hosting.sizingOptions = []
        let panel = KeyableGlassPanel(content: hosting)
        panel.setContentSize(NSSize(width: CommandBarLayout.width, height: CommandBarLayout.panelHeight(listHeight: CommandBarLayout.tallestListHeight)))
        panel.setGlassHeight(CommandBarLayout.panelHeight(listHeight: 0))
        // Lays the SwiftUI tree out now, so the field exists before the
        // first shortcut needs it as first responder.
        panel.contentView?.layoutSubtreeIfNeeded()
        self.panel = panel
        return panel
    }

    /// Ordered front and made key without activating the app, so the app
    /// you were in stays in front.
    private func takeKey(_ panel: KeyableGlassPanel) {
        panel.orderFrontRegardless()
        panel.makeKey()
    }

    @discardableResult
    private func focusField() -> Bool {
        guard let window = hostWindow, let field = model.field?.field else { return false }
        return window.makeFirstResponder(field)
    }

    // MARK: - Placement

    /// Right-aligned under the bar: its right edge on Pelmet's chevron when
    /// it is shown, else the display's edge less a margin. The chevron's
    /// distance from the primary display's right edge carries over to other
    /// displays (their bars lay out the same way).
    private func anchorRight(on screen: NSScreen, appState: AppState) -> CGFloat {
        var right = screen.frame.maxX - GlassPanel.edgeMargin
        if appState.settings.showStatusItem, let snapshot = appState.snapshot,
           let frame = appState.pelmetChevronItem(in: snapshot)?.frame,
           let primary = NSScreen.screens.first {
            let distance = primary.frame.maxX - frame.maxX
            if distance >= 0, distance < screen.frame.width / 2 {
                right = min(right, screen.frame.maxX - distance)
            }
        }
        return right
    }

    /// The window: as tall as the panel ever gets, its top edge under the
    /// bar. It is placed once per open; what changes with the rows is the
    /// glass in it (`fitPanel`), because resizing a window waits on the
    /// window server.
    private func windowFrame() -> NSRect {
        guard let placement else { return .zero }
        let screen = placement.screen
        let margin = GlassPanel.edgeMargin
        let top = GlassPanel.topUnderBar(of: screen)
        let height = min(CommandBarLayout.panelHeight(listHeight: CommandBarLayout.tallestListHeight), top - screen.frame.minY - margin)
        let width = min(CommandBarLayout.width, screen.frame.width - 2 * margin)
        let left = max(placement.right - width, screen.frame.minX + margin)
        return NSRect(x: left.rounded(), y: (top - height).rounded(), width: width.rounded(), height: height.rounded())
    }

    private func glassHeight(listHeight: CGFloat) -> CGFloat {
        min(CommandBarLayout.panelHeight(listHeight: listHeight), panel?.frame.height ?? windowFrame().height)
    }

    /// The glass's height follows the rows; its top edge stays under the bar.
    private func fitPanel() {
        guard let panel else { return }
        let wanted = min(contentHeight, panel.frame.height)
        guard panel.glassHeight != wanted else { return }
        let started = ProcessInfo.processInfo.systemUptime
        panel.setGlassHeight(wanted)
        letMouseThroughOffGlass()
        fitMs += (ProcessInfo.processInfo.systemUptime - started) * 1000
    }

    /// The window stays tall while open and only the glass changes height
    /// (a window resize per keystroke cost 5–31ms live). A clear window still
    /// takes the click (2026-10-04: clicks under the glass did nothing), so
    /// off the glass the panel lets the mouse through: the click reaches what
    /// is under it and the click-outside close runs.
    private func letMouseThroughOffGlass() {
        guard let panel, isOpen else { return }
        panel.ignoresMouseEvents = !panel.glassScreenFrame.contains(NSEvent.mouseLocation)
    }

    /// Milliseconds `fitPanel` spent placing the panel since it was last
    /// zeroed: the part of a keystroke's time that is the window's.
    private var fitMs = 0.0

    /// Runs `body` when the main run loop next has nothing left to do, the
    /// SwiftUI update a change queued behind it included. After Core
    /// Animation's own observer (order 2,000,000).
    private static func whenIdle(_ body: @escaping @MainActor () -> Void) {
        let observer = CFRunLoopObserverCreateWithHandler(
            nil, CFRunLoopActivity.beforeWaiting.rawValue, false, 3_000_000
        ) { _, _ in
            MainActor.assumeIsolated { body() }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }

    // MARK: - Ranking

    private func showRest() {
        apply(SearchRanker.restState(candidates: candidates, history: history, now: .now, limit: Self.restRows), rest: true)
    }

    func queryChanged(_ text: String) {
        guard isOpen else { return }
        if mode == .actions {
            model.query = text
            showActions(filter: text)
            return
        }
        guard mode == .results else { return }
        let started = ProcessInfo.processInfo.systemUptime
        model.query = text
        guard !FoldedText.normalized(text).isEmpty else {
            showRest()
            return
        }
        let matches = SearchRanker.rank(
            query: text, candidates: candidates, history: history, now: .now, limit: Self.resultRows
        )
        let ranked = ProcessInfo.processInfo.systemUptime
        fitMs = 0
        apply(matches, rest: false)
        let applied = ProcessInfo.processInfo.systemUptime
        let fit = fitMs
        PelmetLog.log(String(
            format: "\(logTag): rank %d char(s) → %d row(s) in %.2fms (rank %.2f, apply %.2f, fit %.2f)",
            text.count, matches.count, (applied - started) * 1000,
            (ranked - started) * 1000, (applied - ranked) * 1000 - fit, fit
        ))
        // The row views a change makes are built after this returns, in the
        // update the run loop does next: this line is when it is done.
        let chars = text.count
        let tag = logTag
        Self.whenIdle {
            PelmetLog.log(String(
                format: "\(tag): %d char(s) drawn, idle %.2fms after the key",
                chars, (ProcessInfo.processInfo.systemUptime - started) * 1000
            ))
        }
        scheduleAnnouncement()
    }

    private func apply(_ matches: [SearchMatch], rest: Bool) {
        var matches = matches
        if let linkQuery, model.query == linkQuery {
            matches = matches.filter { entries[$0.candidate.id]?.isItem == true }
        }
        model.rows = matches.compactMap(row(for:))
        model.selected = 0
        model.showsNoResults = !rest && matches.isEmpty
        model.completion = rest ? nil : matches.first.flatMap { SearchRanker.completion(query: model.query, for: $0) }
        model.resultsVersion += 1
        fitPanel()
    }

    private func row(for match: SearchMatch) -> CommandBarRow? {
        let candidate = match.candidate
        guard let entry = entries[candidate.id] else { return nil }
        var synonym: String?
        if match.field == .keyword || match.field == .alias, let text = match.matchedText {
            synonym = "\(text) → \(candidate.title)"
        }
        var sectionTag: String?
        var label = candidate.title
        switch candidate.kind {
        case .item:
            switch candidate.section {
            case .hidden:
                sectionTag = String(localized: "Hidden")
                label = String(localized: "\(candidate.title), hidden")
            case .alwaysHidden:
                sectionTag = String(localized: "Always Hidden")
                label = String(localized: "\(candidate.title), always hidden")
            case .visible, nil:
                break
            }
        case .launcher:
            label = String(localized: "\(candidate.title), not running")
        case .setting:
            label = String(localized: "\(candidate.title), setting in \(candidate.subtitle ?? "")")
        case .command:
            break
        }
        return CommandBarRow(
            id: candidate.id, title: candidate.title, titleRanges: match.titleRanges,
            subtitle: candidate.subtitle, glyph: entry.glyph, synonymTag: synonym,
            sectionTag: sectionTag,
            trailing: candidate.kind == .item ? appState?.settings.itemHotkeys[candidate.id]?.display : nil,
            accessibilityLabel: label
        )
    }

    /// The result count, said once typing pauses; VoiceOver only.
    private func scheduleAnnouncement() {
        guard NSWorkspace.shared.isVoiceOverEnabled else { return }
        announceTask?.cancel()
        announceTask = Task { [weak self] in
            try? await Task.sleep(for: AppTiming.searchAnnounceDelay)
            guard !Task.isCancelled, let self, self.isOpen else { return }
            let count = self.model.rows.count
            self.announce(count == 0 ? String(localized: "No results")
                : count == 1 ? String(localized: "1 result")
                : String(localized: "\(count) results"))
        }
    }

    private func announce(_ text: String) {
        guard NSWorkspace.shared.isVoiceOverEnabled else { return }
        NSAccessibility.post(
            element: model.field?.field as Any,
            notification: .announcementRequested,
            userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue]
        )
    }

    // MARK: - Keys

    private func installMonitors() {
        removeMonitors()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let consumed = MainActor.assumeIsolated { self?.handleKey(event) ?? false }
            return consumed ? nil : event
        }
        // The demo has no panel to close; it re-reads the bar when its
        // window comes back (an icon moved or an app opened meanwhile).
        if embedded {
            becomeKeyObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
            ) { [weak self] note in
                let window = (note.object as? NSWindow).map(ObjectIdentifier.init)
                MainActor.assumeIsolated {
                    guard let self, let window, window == self.hostWindow.map(ObjectIdentifier.init) else { return }
                    self.refresh()
                }
            }
            return
        }
        // A click in another app or on the bar changes no key window here,
        // so the resign-key close alone would leave the panel up.
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.close(reason: "click outside") }
        }
        // Moves over other apps (and over the clear part, let through) arrive
        // global, moves over the glass local.
        moveMonitors = [
            NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
                MainActor.assumeIsolated { self?.letMouseThroughOffGlass() }
            },
            NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
                MainActor.assumeIsolated { self?.letMouseThroughOffGlass() }
                return event
            },
        ].compactMap { $0 }
        if let panel {
            resignObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification, object: panel, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.panelResignedKey() }
            }
        }
    }

    private func removeMonitors() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        moveMonitors.forEach(NSEvent.removeMonitor)
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        if let becomeKeyObserver { NotificationCenter.default.removeObserver(becomeKeyObserver) }
        keyMonitor = nil
        clickMonitor = nil
        moveMonitors = []
        resignObserver = nil
        becomeKeyObserver = nil
    }

    /// Losing key is a click elsewhere, and closes. The first moments are
    /// the exception: the right-click menu or the app that was in front
    /// handing focus over looks the same, and a panel that closed there
    /// would never have been seen. It takes key back once.
    private func panelResignedKey() {
        guard isOpen, let panel else { return }
        if !reKeyed, Date().timeIntervalSince(openedAt) < AppTiming.searchResignGuard {
            reKeyed = true
            PelmetLog.log(String(format: "search: lost key %.0fms after opening — taken back", Date().timeIntervalSince(openedAt) * 1000))
            takeKey(panel)
            focusField()
            return
        }
        close(reason: "lost focus")
    }

    /// True when the key was ours. Marked text (an input method mid-word)
    /// keeps every key.
    private func handleKey(_ event: NSEvent) -> Bool {
        guard isOpen, let window = hostWindow, event.window === window, !embedded || demoHasFocus else { return false }
        if (window.firstResponder as? NSTextView)?.hasMarkedText() == true { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .numericPad, .function])
        // Recording takes every key but ⎋: ⌘K, ↩ and the arrows are all
        // combinations someone may want.
        if mode == .shortcut { return recordShortcut(event, flags: flags) }
        switch event.keyCode {
        case 53 where flags.isEmpty: // ⎋ steps back one level, then closes
            escape()
            return true
        case 36, 76: // ↩ and the keypad's
            if mode == .alias {
                commitAlias()
            } else {
                choose(index: model.selected, modifiers: flags)
            }
            return true
        case 125 where flags.isEmpty && mode != .alias: // ↓
            move(1)
            return true
        case 126 where flags.isEmpty && mode != .alias: // ↑
            move(-1)
            return true
        case 48 where flags.isEmpty: // ⇥ keeps focus in the panel's field either way
            // The demo's lets it move on to the pane, or the field would
            // be a trap for the keyboard.
            return acceptCompletion() || !embedded
        case 124 where flags.isEmpty: // →, at the end of the text
            return model.field?.caretAtEnd == true && acceptCompletion()
        case 43 where flags == .command: // ⌘, (the demo is in Settings already)
            if !embedded {
                close(reason: "settings")
                appState?.openSettings()
            }
            return true
        case 40 where flags == .command: // ⌘K
            toggleActions()
            return true
        default:
            break
        }
        // The panel has no Edit menu to route these through.
        if flags == .command, let editor = window.firstResponder as? NSTextView, let key = event.charactersIgnoringModifiers {
            switch key {
            case "a": editor.selectAll(nil)
            case "c": editor.copy(nil)
            case "x": editor.cut(nil)
            case "v": editor.paste(nil)
            default: return false
            }
            return true
        }
        return false
    }

    private func move(_ delta: Int) {
        let count = model.rows.count
        guard count > 0 else { return }
        model.selected = (model.selected + delta + count) % count
    }

    /// Take the top row's completion into the field: its title, so the
    /// typed part takes the title's own casing too.
    private func acceptCompletion() -> Bool {
        guard mode == .results, model.completion != nil, let top = model.rows.first, let field = model.field else { return false }
        field.setText(top.title)
        queryChanged(top.title)
        return true
    }

    // MARK: - Choosing

    func choose(index: Int, modifiers: NSEvent.ModifierFlags) {
        guard isOpen, model.rows.indices.contains(index) else { return }
        switch mode {
        case .results: chooseResult(index: index, modifiers: modifiers)
        case .actions: chooseAction(index: index, modifiers: modifiers)
        case .shortcut, .alias: break
        }
    }

    private func chooseResult(index: Int, modifiers: NSEvent.ModifierFlags) {
        guard let appState, let entry = entries[model.rows[index].id] else { return }
        // ⌘ changes what a press of an item does; nothing else has a second
        // meaning, so ⌘↩ on it is not a Return.
        if modifiers.contains(.command), !entry.isItem { return }
        // Opened by a link and not touched since: icons only (`linkQuery`).
        if let linkQuery, model.query == linkQuery, !entry.isItem {
            PelmetLog.log("search: \(Self.describe(entry.action, modifiers: [])) held, the link's text is untouched")
            return
        }
        commit(entry, modifiers: modifiers, query: model.query, row: index, of: model.rows.count, appState: appState)
    }

    /// Records the pick, closes with the exit animation, then runs it.
    private func commit(
        _ entry: CommandBarEntry, modifiers: NSEvent.ModifierFlags, query: String,
        row: Int?, of count: Int?, appState: AppState
    ) {
        // The other bar may have saved (or Settings reset) since this one
        // read it.
        history = Self.loadHistory()
        history.record(id: entry.candidate.id, query: query, at: .now)
        saveHistory()
        let how = modifiers.contains(.command) ? "⌘↩" : "↩"
        let place = row.map { ", row \($0 + 1) of \(count ?? 0)" } ?? ""
        PelmetLog.log("\(logTag): chose \(entry.candidate.id) (\(entry.candidate.kind.rawValue)\(place)) with \(how) — \(Self.describe(entry.action, modifiers: modifiers))")
        close(reason: "chose")
        perform(entry.action, modifiers: modifiers, appState: appState)
    }

    private static func describe(_ action: CommandBarEntry.Action, modifiers: NSEvent.ModifierFlags) -> String {
        switch action {
        case .item:
            modifiers.contains(.command) ? "show in bar" : "open menu"
        case .launcher: "open the app"
        case .command(let command): "command \(command.key)"
        case .setting(let tab, let row): "settings tab \(tab.rawValue), row \(row)"
        }
    }

    private func perform(_ action: CommandBarEntry.Action, modifiers: NSEvent.ModifierFlags, appState: AppState) {
        switch action {
        case .item(let id):
            if modifiers.contains(.command) {
                appState.showItemInBar(id)
            } else {
                appState.openItemMenu(id)
            }
        case .launcher(let bundleID):
            Self.open(bundleID)
        case .command(let command):
            switch command {
            case .toggleHidden: appState.toggle(reason: .hotkey)
            case .showAll: appState.toggleAll(reason: .hotkey)
            case .editLayout: appState.openSettings(tab: .menuBar)
            case .animation(let style):
                appState.settings.revealAnimation = style
                appState.settingsChanged()
            case .checkForUpdates: SparkleController.shared.checkForUpdates()
            case .settings: appState.openSettings()
            case .quit: NSApp.terminate(nil)
            }
        case .setting(let tab, let row):
            appState.openSettings(tab: tab, row: row)
        }
    }

    private static func open(_ bundleID: String) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            PelmetLog.log("search: no app for \(bundleID)")
            return
        }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            if let error { PelmetLog.log("search: opening \(bundleID) failed — \(error.localizedDescription)") }
        }
    }

    // MARK: - Actions (⌘K)

    /// ⎋: out of an input back to the actions, out of the actions back to the
    /// results, out of the results closes.
    private func escape() {
        switch mode {
        case .results where embedded && FoldedText.normalized(model.query).isEmpty:
            // Nothing to clear: the demo lets go of the keys.
            hostWindow?.makeFirstResponder(nil)
        case .results: close(reason: "escape")
        case .actions: leaveActions()
        case .shortcut, .alias: endInput(selecting: actionsSelection)
        }
    }

    private func toggleActions() {
        switch mode {
        case .results: enterActions()
        case .actions, .alias: leaveActions()
        case .shortcut: break
        }
    }

    /// The selected row's actions take the results' place in the same panel.
    /// Commands and settings have none, so ⌘K there does nothing.
    private func enterActions() {
        guard let appState, model.rows.indices.contains(model.selected),
              let entry = entries[model.rows[model.selected].id]
        else { return }
        let items = CommandBarActions.list(for: entry, appState: appState, history: history)
        guard !items.isEmpty else { return }
        resultsQuery = model.query
        resultsSelectedID = entry.candidate.id
        actionsEntry = entry
        actionItems = items
        mode = .actions
        model.chip = CommandBarChip(glyph: entry.glyph, title: entry.candidate.title)
        model.placeholder = String(localized: "Filter actions")
        model.completion = nil
        model.showsNoResults = false
        model.field?.setText("")
        model.query = ""
        showActions(filter: "")
        PelmetLog.log("\(logTag): ⌘K — \(items.count) action(s) for \(entry.candidate.id)")
        announce(String(localized: "Actions for \(entry.candidate.title)"))
    }

    /// Back to the results with the query as it was, on the row ⌘K was on.
    private func leaveActions() {
        mode = .results
        actionsEntry = nil
        actionItems = []
        model.chip = nil
        model.input = nil
        model.inputMessage = nil
        model.placeholder = String(localized: "Search the menu bar")
        let query = resultsQuery
        model.field?.setText(query)
        focusField()
        queryChanged(query)
        if let id = resultsSelectedID, let index = model.rows.firstIndex(where: { $0.id == id }) {
            model.selected = index
        }
    }

    /// The action list for `filter`, keeping `selecting` selected when it is
    /// still there.
    private func showActions(filter: String, selecting: CommandBarAction? = nil) {
        let shown = CommandBarActions.filtered(actionItems, query: filter)
        model.rows = shown.map { hit in
            CommandBarRow(
                id: hit.item.action.key, title: hit.item.title, titleRanges: hit.ranges, subtitle: nil,
                glyph: .symbol(hit.item.symbol), synonymTag: nil, sectionTag: nil, trailing: hit.item.trailing,
                accessibilityLabel: hit.item.trailing.map { "\(hit.item.title), \($0)" } ?? hit.item.title
            )
        }
        model.selected = selecting.flatMap { wanted in shown.firstIndex { $0.item.action == wanted } } ?? 0
        model.showsNoResults = shown.isEmpty
        model.completion = nil
        model.resultsVersion += 1
        fitPanel()
    }

    /// What the actions list had selected, to land on it again after an input.
    private var actionsSelection: CommandBarAction? {
        guard model.rows.indices.contains(model.selected) else { return nil }
        return actionItems.first { $0.action.key == model.rows[model.selected].id }?.action
    }

    private func chooseAction(index: Int, modifiers: NSEvent.ModifierFlags) {
        guard let appState, let entry = actionsEntry else { return }
        var chosen = actionItems.first { $0.action.key == model.rows[index].id }?.action
        // The keys on the rows work from anywhere in the list.
        if modifiers.contains(.command) {
            chosen = actionItems.contains { $0.action == .showInBar } ? .showInBar : nil
        }
        guard let chosen else { return }
        PelmetLog.log("\(logTag): action \(chosen.key) on \(entry.candidate.id)")

        switch (chosen, entry.action) {
        case (.openMenu, .item), (.showInBar, .item):
            let how: NSEvent.ModifierFlags = chosen == .showInBar ? .command : []
            commit(entry, modifiers: how, query: resultsQuery, row: nil, of: nil, appState: appState)
        case (.openLauncher, .launcher):
            commit(entry, modifiers: [], query: resultsQuery, row: nil, of: nil, appState: appState)
        case (.move(let section), .item(let id)):
            close(reason: "moved")
            appState.moveItemNow(id, to: section)
        case (.setShortcut, .item):
            beginInput(.shortcut, title: model.rows[index].title)
        case (.removeShortcut, .item(let id)):
            appState.setItemHotkey(nil, for: id)
            refreshActions(selecting: .setShortcut)
        case (.setAlias, .item(let id)):
            model.aliasDraft = appState.settings.itemAliases[id.rawValue] ?? ""
            beginInput(.alias, title: model.rows[index].title)
        case (.openApp, _):
            close(reason: "open app")
            if let app = entry.app { Self.open(app.openBundleID) }
        case (.quitApp, _):
            close(reason: "quit app")
            if let app = entry.app { ItemMenuActions.quit(app.bundleID, source: logTag) }
        case (.forget, _):
            history = Self.loadHistory()
            history.forget(id: entry.candidate.id)
            saveHistory()
            close(reason: "forgot")
        default:
            break
        }
    }

    /// The same actions again after one changed what they show (a shortcut
    /// set or removed, an alias saved).
    private func refreshActions(selecting: CommandBarAction?) {
        guard let appState, let entry = actionsEntry else { return }
        actionItems = CommandBarActions.list(for: entry, appState: appState, history: history)
        model.field?.setText("")
        model.query = ""
        showActions(filter: "", selecting: selecting)
    }

    // MARK: Inputs

    private func beginInput(_ input: CommandBarInput, title: String) {
        mode = input == .shortcut ? .shortcut : .alias
        model.input = input
        // German spaces its ellipsis ("Kürzel festlegen …").
        model.inputTitle = title.replacingOccurrences(of: "…", with: "").trimmingCharacters(in: .whitespaces)
        model.inputMessage = nil
        model.inputCaption = input == .shortcut
            ? String(localized: "Press the new shortcut. ⎋ cancels.")
            : String(localized: "Press ↩ to save, ⎋ to cancel. Leave it empty to remove the alias.")
        fitPanel()
    }

    /// Back to the actions list from an input.
    private func endInput(selecting: CommandBarAction?) {
        mode = .actions
        model.input = nil
        model.inputMessage = nil
        refreshActions(selecting: selecting)
        // The alias field is gone; the filter field is the one to type in.
        focusField()
    }

    private func commitAlias() {
        guard let appState, let entry = actionsEntry, case .item(let id) = entry.action else { return }
        appState.setItemAlias(model.aliasField?.field.stringValue ?? "", for: id)
        // Only this row's candidate changes; the corpus is not rebuilt.
        let alias = appState.settings.itemAliases[id.rawValue]
        let updated = entry.with(candidate: entry.candidate.withAlias(alias))
        if let index = candidates.firstIndex(where: { $0.id == entry.candidate.id }) { candidates[index] = updated.candidate }
        entries[updated.candidate.id] = updated
        actionsEntry = updated
        endInput(selecting: .setAlias)
    }

    /// True: the recorder took the key.
    private func recordShortcut(_ event: NSEvent, flags: NSEvent.ModifierFlags) -> Bool {
        guard let appState, let entry = actionsEntry, case .item(let id) = entry.action else { return false }
        if event.keyCode == UInt16(kVK_Escape), flags.isEmpty {
            escape()
            return true
        }
        let mods = ShortcutRecorder.carbonModifiers(from: flags)
        guard !ShortcutRecorder.wouldType(keyCode: Int(event.keyCode), modifiers: mods) else {
            NSSound.beep()
            model.inputMessage = String(localized: "Hold ⌘, ⌥ or ⌃ with the key, so it doesn't type into other apps.")
            return true
        }
        let spec = HotkeySpec(
            keyCode: UInt32(event.keyCode),
            modifiers: mods,
            display: ShortcutRecorder.symbols(flags)
                + ShortcutRecorder.keyName(keyCode: Int(event.keyCode), chars: event.charactersIgnoringModifiers)
        )
        if let editing = Self.editChordMessage(for: spec) {
            NSSound.beep()
            model.inputMessage = editing
            PelmetLog.log("\(logTag): shortcut \(spec.display) for \(id.rawValue) refused, an edit shortcut")
            return true
        }
        if let refusal = appState.setItemHotkey(spec, for: id) {
            NSSound.beep()
            model.inputMessage = Self.message(for: refusal, spec: spec)
            PelmetLog.log("\(logTag): shortcut \(spec.display) for \(id.rawValue) refused — \(refusal)")
            return true
        }
        endInput(selecting: .setShortcut)
        return true
    }

    /// Why a combination was refused and what to do about it. Settings ›
    /// Search says the same.
    static func message(for refusal: AppState.ItemHotkeyRefusal, spec: HotkeySpec) -> String {
        switch refusal {
        case .pelmet(let what):
            String(localized: "\(spec.display) is already Dimble's shortcut for “\(what)”. Press a different combination.")
        case .item(let other):
            String(localized: "\(spec.display) already opens \(ItemNaming.displayName(for: other)). Press a different combination.")
        case .system:
            String(localized: "macOS already uses \(spec.display). Press a different combination.")
        case .otherApp:
            String(localized: "Another app already uses \(spec.display). Press a different combination.")
        }
    }

    /// Why an edit shortcut (⌘C, ⌘V…) can't open an icon, nil for any other
    /// combination. Settings › Search says the same.
    static func editChordMessage(for spec: HotkeySpec) -> String? {
        guard ShortcutRecorder.isEditChord(spec) else { return nil }
        return String(localized: "Every app uses \(spec.display) for editing. Press a different combination.")
    }

    // MARK: - History

    static func loadHistory() -> SearchHistory {
        guard let data = UserDefaults.standard.data(forKey: historyKey),
              let history = try? JSONDecoder().decode(SearchHistory.self, from: data)
        else { return SearchHistory() }
        return history
    }

    private func saveHistory() {
        guard let data = try? JSONEncoder().encode(history) else { return }
        UserDefaults.standard.set(data, forKey: Self.historyKey)
        appState?.searchHistoryRevision += 1
    }

    /// Picks remembered, for the Settings row that resets them. Read from
    /// what was saved: the demo learns too.
    var historyPickCount: Int { Self.loadHistory().picks.count }

    /// Settings › General › Reset Search History.
    func resetHistory() {
        history.reset()
        saveHistory()
        PelmetLog.log("search: history reset")
    }
}
