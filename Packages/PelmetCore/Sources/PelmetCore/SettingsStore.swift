// SettingsStore.swift
// All user preferences, one Codable blob in UserDefaults. Tiny data — no files,
// no CoreData. Every option here expresses a real user preference (options that
// exist to work around engine unreliability are banned by design).

import Foundation

public struct HotkeySpec: Codable, Equatable, Sendable {
    /// Carbon key code + modifier flags (stored raw for the recorder).
    public var keyCode: UInt32
    public var modifiers: UInt32
    /// Glyphs captured at record time ("⌥⌘,"), so showing the shortcut needs
    /// no keyboard-layout math. Empty on blobs written before it existed.
    public var display: String

    public init(keyCode: UInt32, modifiers: UInt32, display: String = "") {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.display = display
    }

    /// ⌥⌘, — nothing in macOS binds it, and "," is already the settings key
    /// everywhere. Carbon constants inlined so PelmetCore stays Carbon-free:
    /// kVK_ANSI_Comma = 0x2B, cmdKey | optionKey = 0x100 | 0x800.
    public static let `default` = HotkeySpec(keyCode: 0x2B, modifiers: 0x900, display: "⌥⌘,")
    /// ⇧⌥⌘, opens Settings — the toggle combo plus shift (shiftKey = 0x200).
    public static let settingsDefault = HotkeySpec(keyCode: 0x2B, modifiers: 0xB00, display: "⇧⌥⌘,")
    /// ⌃⌥⌘, shows Always Hidden too (#67) — the toggle combo plus control
    /// (controlKey = 0x1000). With the icon off it is the only way there.
    public static let alwaysHiddenDefault = HotkeySpec(keyCode: 0x2B, modifiers: 0x1900, display: "⌃⌥⌘,")
    /// ⌥⌘N opens Notification Center (#44): macOS's own shortcut is refused
    /// while a hide assertion holds, so Pelmet offers one that runs the
    /// clock relay. kVK_ANSI_N = 0x2D.
    public static let notificationCenterDefault = HotkeySpec(keyCode: 0x2D, modifiers: 0x900, display: "⌥⌘N")
    /// ⌥⌘K opens the command bar (⌥⌘Space belongs to Finder's search
    /// window). kVK_ANSI_K = 0x28.
    public static let searchDefault = HotkeySpec(keyCode: 0x28, modifiers: 0x900, display: "⌥⌘K")
    /// A shortcut the user turned off (#79: Pelmet's combos clashed with
    /// Keyboard Maestro). A value, not nil: a missing or null field still
    /// decodes to the default, and no key has this code. A build from before
    /// it (0.3.1) reads it as a real key code: a manual downgrade shows a
    /// blank shortcut "held by another app". Accepted, Sparkle never
    /// downgrades (review PKG-6).
    public static let off = HotkeySpec(keyCode: .max, modifiers: 0)
    public var isOff: Bool { keyCode == Self.off.keyCode }

    private enum CodingKeys: String, CodingKey { case keyCode, modifiers, display }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        keyCode = try c.decode(UInt32.self, forKey: .keyCode)
        modifiers = try c.decode(UInt32.self, forKey: .modifiers)
        display = (try? c.decodeIfPresent(String.self, forKey: .display)) ?? ""
        if display.isEmpty, keyCode == Self.default.keyCode, modifiers == Self.default.modifiers {
            display = Self.default.display
        }
    }
}

public enum DisplayBehavior: String, Codable, Equatable, Sendable {
    /// Never conceal while the pointer is on this display.
    case alwaysShowAll
    /// Collapse; reveal via the configured triggers.
    case collapse
}

public struct RevealTriggers: Codable, Equatable, Sendable {
    public var hoverEnabled: Bool
    public var hoverDelay: TimeInterval
    public var clickEnabled: Bool
    public var doubleClickForAlwaysHidden: Bool

    public init(
        hoverEnabled: Bool = true,
        hoverDelay: TimeInterval = 0.1,
        clickEnabled: Bool = true,
        doubleClickForAlwaysHidden: Bool = true
    ) {
        self.hoverEnabled = hoverEnabled
        self.hoverDelay = hoverDelay
        self.clickEnabled = clickEnabled
        self.doubleClickForAlwaysHidden = doubleClickForAlwaysHidden
    }
}

public enum SeparatorStyle: String, Codable, CaseIterable, Sendable {
    case pipe = "|"
    case dot = "•"
    case chevronLeft = "‹"
    case chevronRight = "›"
    case dash = "—"
    case space = " "

    public var displayName: String {
        switch self {
        case .pipe: "Pipe"
        case .dot: "Dot"
        case .chevronLeft: "Chevron ‹"
        case .chevronRight: "Chevron ›"
        case .dash: "Dash"
        case .space: "Invisible spacer"
        }
    }
}

public struct SeparatorSpec: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var style: SeparatorStyle
    /// Glyph opacity in the bar (invisible spacers ignore it).
    public var opacity: Double
    /// Points of bar the invisible spacer takes up (drawn styles size
    /// themselves to their glyph and ignore it). The gap is the only thing a
    /// spacer has to offer, so it is the one control its chooser shows.
    public var width: Double

    public static let defaultWidth: Double = 14
    public static let widthRange: ClosedRange<Double> = 4...48

    public init(
        id: UUID = UUID(),
        style: SeparatorStyle,
        opacity: Double = 0.55,
        width: Double = SeparatorSpec.defaultWidth
    ) {
        self.id = id
        self.style = style
        self.opacity = opacity
        self.width = width
    }

    /// Stable ItemID title, the separator's twin of `ExtraItemSpec.itemTitle`.
    /// It was interpolated at four sites in SeparatorManager; a title the
    /// model keys on belongs with the spec that owns it.
    public var itemTitle: String { "Pelmet.Separator.\(id.uuidString)" }

    // Resilient decode: specs saved before `opacity` or `width` existed keep
    // the old look — a spacer from before the width control is still 14pt.
    private enum CodingKeys: String, CodingKey { case id, style, opacity, width }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        style = try c.decode(SeparatorStyle.self, forKey: .style)
        opacity = try c.decodeIfPresent(Double.self, forKey: .opacity) ?? 0.55
        width = try c.decodeIfPresent(Double.self, forKey: .width) ?? Self.defaultWidth
    }
}

public enum ExtraKind: String, Codable, CaseIterable, Sendable {
    case mediaControls
    /// The camera pill's twin, and SharePlay's: with no call, a session
    /// (from Messages, or kept after hanging up) shows the SharePlay glyph
    /// and opens Apple's SharePlay controls, the ones a call keeps in the
    /// pill (2026-09-25).
    case cameraMicIndicator
    case airdrop
    case shortcut
    /// A Pelmet-drawn icon for another app: click opens it. Made for apps
    /// whose own icon Pelmet can't hide (hosted by a bundle-less helper the
    /// assertion allowlist can never match — ChatGPT Classic, 2026-09-09)
    /// and, for everything else, a plain launcher.
    /// Raw value predates the 2026-09-10 rename (was "app stand-in") — kept
    /// so pre-release settings still decode.
    case appLauncher = "appStandIn"
    /// Pelmet's own countdown. macOS's timer is a Control Center Live
    /// Activity the assertion hides, and its state sits behind a private
    /// entitlement (2026-09-15) — a timer that stays in the bar has to be
    /// Pelmet's.
    case timer
    /// Fast user switching menu — the system one is collateral-hidden too.
    case userSwitching
    /// The user's Shortcuts library as a menu. On macOS 27 menu bar
    /// shortcuts are a Control Center control, and every hide assertion
    /// takes controls off the bar whatever the allowlist names (probed
    /// 2026-09-28). The "Menu Bar" collection itself is unreadable (the
    /// Shortcuts library is TCC-protected, the CLI only knows real
    /// folders), so the menu lists the whole library, folders as submenus.
    case shortcutsMenu
    /// Time Machine status and Back Up Now. Apple's own is a SystemUIServer
    /// extra: the assertion hides that process as one bundle, so Siri and
    /// Time Machine could only ever hide together (#19). A Pelmet-drawn
    /// item is the only way each gets its own tile; adding one switches
    /// Apple's twin off in System Settings so the bar shows a single icon.
    case timeMachine
    /// Siri, same story as `timeMachine`.
    case siri
    /// The Focus indicator. Apple's is a Control Center extra the assertion
    /// hides with the Live Activities (#29), and donotdisturbd only talks to
    /// entitled clients — but it narrates every transition to the unified
    /// log with the mode's name and symbol in the clear (probed 2026-09-16),
    /// so a Pelmet-drawn twin can follow along.
    case focus
    /// Quick Note. Apple's icon is Notes' Control Center control
    /// (`QuickNoteControl`), which every hide assertion takes off the bar
    /// whatever the allowlist names (#99). A Pelmet-drawn twin posts the
    /// user's own Quick Note shortcut (symbolic hotkey 190).
    case quickNote
    /// A Live Activity is running (#106). Every hide assertion takes the
    /// pills off the bar and nothing exempts them; MenuBarAgent's log says
    /// which app started one and when it ends (`LiveActivities`), so an
    /// indicator can follow along, and a click lifts the hide for the real
    /// pill.
    case liveActivity
}

/// When an activity-driven item sits in the bar — System Settings' "Always
/// Show" / "Show When Active" for Pelmet's own items. What counts as active
/// is the kind's: a launcher's app running, audio playing, a backup running,
/// a Focus being on. Kinds with no such state (Siri, AirDrop, shortcuts,
/// fast user switching) have no rule; neither does the camera & mic
/// indicator (one that always showed would lie) nor the timer (idle and
/// hidden, it could never be started).
public enum ExtraShowRule: String, Codable, CaseIterable, Sendable {
    /// Present whether or not the thing is active. A launcher's default — a
    /// launcher you can't click when the app is closed isn't a launcher.
    case always
    /// A launcher, media controls or the camera indicator: present only
    /// while active, the way the app's own icon or Apple's Now Playing is.
    /// Focus and Time Machine: present in their section, and out on the bar
    /// on their own while active ("Show when it matters"). Raw value predates the 2026-09-16 generalisation
    /// from launchers — kept so saved settings still decode.
    case whenActive = "whileRunning"
}

public extension ExtraKind {
    /// What a spec with no saved rule does. Media comes and goes like
    /// Apple's; a launcher, Time Machine and Focus stay — the Focus item at
    /// rest is the button that opens the Focus panel, so it earns its slot
    /// (Gab, 2026-09-16), unlike Apple's own default.
    var defaultShowRule: ExtraShowRule {
        switch self {
        case .mediaControls, .cameraMicIndicator: .whenActive
        default: .always
        }
    }
}

public extension ExtraKind {
    /// The kinds whose rule is "Show when it matters" (Settings › Menu Bar):
    /// in their section like any icon, and out on the bar on their own while
    /// the thing they watch is happening. A launcher's rule is its own row's.
    var showsWhenItMatters: Bool {
        switch self {
        case .focus, .timeMachine: true
        default: false
        }
    }
}

/// How a Pelmet item draws its glyph: the SF Symbol still, or (media
/// controls only) natively drawn bars that wave while audio plays and
/// settle when it pauses. Nil on old blobs = static; other kinds ignore it.
public enum ExtraStyle: String, Codable, CaseIterable, Sendable {
    case `static`
    case animated
}

extension ExtraKind {
    /// The kinds that stand in for a collateral-hidden system extra
    /// (Now Playing, the camera pill and SharePlay, AirDrop, Focus, the
    /// Clock timer, fast user switching, the Shortcuts control, Quick Note's
    /// Notes control). Siri and Time Machine replace SystemUIServer items,
    /// which hide by the allowlist like any app.
    public static let collateralReplicas: Set<ExtraKind> = [
        .mediaControls, .cameraMicIndicator, .airdrop, .focus, .timer, .userSwitching, .shortcutsMenu, .quickNote,
    ]
}

public struct ExtraItemSpec: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var kind: ExtraKind
    /// Glyph style for the hardware-driven kinds (media, camera & mic,
    /// AirDrop); launchers and shortcuts ignore it. Nil reads as `.static`.
    public var style: ExtraStyle?
    /// Shortcuts-app shortcut name (kind == .shortcut).
    public var shortcutName: String?
    /// SF Symbol for shortcut items.
    public var symbol: String?
    /// App launchers: the app's bundle id — identity, icon, and what a click opens.
    public var bundleID: String?
    /// App launchers: display name captured at add time (the app may be quit).
    public var appName: String?
    /// The activity-driven kinds (launchers, media controls, Time Machine,
    /// Focus); nil reads as the kind's default (`ExtraKind.defaultShowRule`).
    public var showRule: ExtraShowRule?
    /// Focus and Time Machine's "While a Focus is on" / "While backing up"
    /// on their Settings row, like the Timer's: off the bar while idle,
    /// wherever they sit, and out on their own while active. `showRule` then
    /// keeps the card's Show when it matters choice for when this is off. A
    /// field of its own, not a third `ExtraShowRule`: an older build that
    /// meets an unknown rule drops every Dimble item.
    public var onlyWhileActive: Bool?

    public init(
        id: UUID = UUID(),
        kind: ExtraKind,
        shortcutName: String? = nil,
        symbol: String? = nil,
        bundleID: String? = nil,
        appName: String? = nil,
        showRule: ExtraShowRule? = nil,
        style: ExtraStyle? = nil,
        onlyWhileActive: Bool? = nil
    ) {
        self.id = id
        self.kind = kind
        self.style = style
        self.shortcutName = shortcutName
        self.symbol = symbol
        self.bundleID = bundleID
        self.appName = appName
        self.showRule = showRule
        self.onlyWhileActive = onlyWhileActive
    }

    public var resolvedShowRule: ExtraShowRule { showRule ?? kind.defaultShowRule }
    /// Off the bar while idle (Focus and Time Machine only).
    public var isOnlyWhileActive: Bool { kind.showsWhenItMatters && onlyWhileActive == true }
    /// Out on the bar on its own while active, whatever its section: the
    /// card's rule, or the row's "only while active".
    public var comesOutWhileActive: Bool {
        kind.showsWhenItMatters && (isOnlyWhileActive || resolvedShowRule == .whenActive)
    }
    public var resolvedStyle: ExtraStyle { style ?? .static }

    /// Stable ItemID title. Singleton kinds keep fixed titles (section
    /// assignments survive re-toggling); shortcut items key by UUID.
    public var itemTitle: String {
        switch kind {
        case .mediaControls: "Pelmet.MediaControls"
        case .cameraMicIndicator: "Pelmet.CameraMic"
        case .airdrop: "Pelmet.AirDrop"
        case .shortcut: "Pelmet.Shortcut.\(id.uuidString)"
        case .appLauncher: "Pelmet.App.\(id.uuidString)"
        case .timer: "Pelmet.Timer"
        case .userSwitching: "Pelmet.Users"
        case .shortcutsMenu: "Pelmet.Shortcuts"
        case .timeMachine: "Pelmet.TimeMachine"
        case .siri: "Pelmet.Siri"
        case .focus: "Pelmet.Focus"
        case .quickNote: "Pelmet.QuickNote"
        case .liveActivity: "Pelmet.LiveActivity"
        }
    }
}

/// How concealed icons come back on reveal. Conceal always fades (the agent
/// pops items off with no animation; Pelmet's ghost overlay manufactures the
/// hide motion) — this only styles the reveal side.
/// Glyph for Pelmet's own menu bar icon. Each style has a concealed and a
/// revealed face so the icon keeps pointing at what a click will do.
public enum StatusIconStyle: String, Codable, CaseIterable, Sendable, Identifiable {
    case chevron, wideChevron, arrow, eye, dots, grid, panel, dot, smallDot

    public var id: String { rawValue }

    /// SF Symbol name for the current bar state. The wide chevron is no
    /// symbol: the app draws it in the site's proportions (#101), and this
    /// is the nearest symbol for anything that only takes a name.
    public func symbol(revealed: Bool) -> String {
        switch self {
        case .chevron: revealed ? "chevron.compact.right" : "chevron.compact.left"
        case .wideChevron: revealed ? "chevron.right" : "chevron.left"
        case .arrow: revealed ? "arrow.right" : "arrow.left"
        case .eye: revealed ? "eye" : "eye.slash"
        case .dots: "ellipsis"
        case .grid: "square.grid.2x2"
        case .panel: revealed ? "rectangle.righthalf.inset.filled" : "rectangle.lefthalf.inset.filled"
        case .dot, .smallDot: revealed ? "circlebadge" : "circlebadge.fill"
        }
    }

    /// Symbol point size when the style draws smaller than the bar's
    /// default 13. The dot at 13 read too big next to the chevron (#62); the
    /// small one is half its width, 3.5pt against 6.5pt (#98).
    public var symbolPointSize: Double? {
        switch self {
        case .dot: 9
        case .smallDot: 5
        default: nil
        }
    }
}

public enum RevealAnimation: String, Codable, CaseIterable, Sendable {
    /// No animation — icons appear in place once the swap lands.
    case instant
    /// The agent's own slide-in (the OS default).
    case smooth
    /// Fade in place — a cover over the strip fades away after the swap.
    case fade
}

/// Defaults shared beyond the store itself (the engine boots with the same
/// steady-extras state a fresh store carries).
public enum SettingsDefaults {
    public static let hideSystemExtras = true
}

public struct SettingsStore: Codable, Equatable, Sendable {
    public var onboardingCompleted: Bool = false
    public var launchAtLogin: Bool = false
    public var showStatusItem: Bool = true
    public var statusIconStyle: StatusIconStyle = .chevron
    /// Off only as `.off`, set on purpose: a missing, null or unreadable
    /// value takes the default.
    public var hotkey: HotkeySpec? = .default
    public var settingsHotkey: HotkeySpec? = .settingsDefault
    public var alwaysHiddenHotkey: HotkeySpec? = .alwaysHiddenDefault
    public var searchHotkey: HotkeySpec? = .searchDefault
    /// A shortcut per menu bar item that opens its menu, keyed by the item's
    /// `sectionKey`. Set from the command bar's actions; absent = none.
    public var itemHotkeys: [String: HotkeySpec] = [:]
    /// The user's own name for an item, keyed by `sectionKey`. The command
    /// bar's search matches it above everything else the item carries.
    public var itemAliases: [String: String] = [:]

    public var revealTriggers = RevealTriggers()
    public var autoRehide: Bool = true
    public var rehideDelay: TimeInterval = 5
    public var rehideOnClickElsewhere: Bool = true

    public var revealAnimation: RevealAnimation = .smooth

    /// Where hidden icons show up on a reveal: the menu bar as ever, the
    /// panel, or the panel as a row (docs/PANEL-PLAN.md).
    public var hiddenIconsIn: RevealTarget = .menuBar
    public var panel = PanelOptions()

    /// Hold the hide-assertion even while revealed (allowlist just widens).
    /// Keeps macOS's collateral extras (Now Playing, camera pill, AirDrop…)
    /// consistently hidden instead of jumping in and out on every transition.
    public var hideSystemExtras: Bool = SettingsDefaults.hideSystemExtras

    /// A Pelmet item that stands in for one of those collateral extras is
    /// on. It exists to replace the system's, so the system's must stay
    /// out: with "Show while revealed" the camera pill came back on every
    /// hover, the replica deferred to it, and the two swapped places on
    /// every transition (#39).
    public var replacesCollateralExtras: Bool {
        extraItems.contains { ExtraKind.collateralReplicas.contains($0.kind) }
    }

    /// The Live Activities item stands in for the pills, so it's only there
    /// when live mode isn't drawing them: switched off, or without Screen
    /// Recording. With a pill turned off it is there too — it brings every
    /// pill back for a look, which is the only way back to one live mode
    /// doesn't draw.
    public func offersLiveActivityItem(screenRecording: Bool) -> Bool {
        !(screenRecording && showLiveActivities) || !hiddenLiveActivities.isEmpty
    }

    /// The extras that get a place on the bar.
    public func barExtraItems(screenRecording: Bool) -> [ExtraItemSpec] {
        offersLiveActivityItem(screenRecording: screenRecording)
            ? extraItems : extraItems.filter { $0.kind != .liveActivity }
    }

    /// What the engine holds: the user's choice, forced on while a replica
    /// is on.
    public var effectiveHideSystemExtras: Bool {
        hideSystemExtras || replacesCollateralExtras
    }

    /// Right-clicking an empty spot on the menu bar opens Pelmet's menu.
    /// Off for people running an app that draws its own surface across the
    /// bar, where the two menus compete for the same click (issue #8).
    /// Read `barRightClickMenuActive`, never this — with the icon hidden the
    /// stored value does not apply.
    public var barRightClickMenu: Bool = true

    /// Clicking the clock opens Notification Center — except that macOS
    /// refuses the click while any icon is hidden, so Pelmet lets go of the
    /// hide for an instant and replays the click (ClockClickRelay). Under a
    /// picture of the bar that instant is invisible; without Screen
    /// Recording the hidden icons flash by (#37). Off, the clock click is
    /// left to macOS (dead while icons are hidden; the two-finger swipe from
    /// the trackpad's right edge still opens Notification Center).
    public var clockClickOpensNotificationCenter: Bool = true
    /// Registered only while `clockClickOpensNotificationCenter` is on; the
    /// row lives under that toggle. Never off there (⌫ restores the default).
    public var notificationCenterHotkey: HotkeySpec? = .notificationCenterDefault

    /// Live mode: while a Live Activity runs, its pill shows next to the «
    /// and the system icons Dimble hides come back, the bar beneath held
    /// under a picture. Needs Screen Recording for that picture. Independent
    /// of the Live Activities item, which only follows what runs.
    public var showLiveActivities: Bool = true

    /// Live Activities whose pill live mode doesn't draw, by the name macOS
    /// gives it ("Now Playing", "Sports"). The real pill stays concealed
    /// under the cover, so one turned off is gone from the bar rather than
    /// ended — only the iPhone app that started it can end it. Keyed by the
    /// name, not the activity's id: the choice is about that kind of pill and
    /// outlives the activity that ran.
    public var hiddenLiveActivities: Set<String> = []

    /// A found update posts a user notification instead of Sparkle's window
    /// interrupting whatever the user is doing. Off: only the About pane
    /// shows it. (Auto-download is Sparkle's own preference.)
    public var notifyOnUpdates: Bool = true

    /// Opt into the beta channel: Sparkle also offers appcast items tagged
    /// `beta`. Off (default), only stable items are seen, and nothing ever
    /// downgrades — a beta stays until the next stable build passes it.
    public var betaUpdates: Bool = false

    /// Pelmet's own media-controls item (play/pause/next/prev via media keys).
    /// Superseded by `extraItems`; kept for migration of early builds.
    public var showMediaControls: Bool = false

    /// Pelmet-owned proxy items ("Pelmet items"): section-manageable replacements
    /// for the collateral-hidden system extras, plus user shortcut buttons.
    public var extraItems: [ExtraItemSpec] = []

    /// Battery and Wi-Fi coming back on their own (#86). Pelmet's own items
    /// keep their rule on their spec.
    public var showRules = ShowRuleSettings()

    public var sectionModel = SectionModel()
    /// Order changes drawn in the editor and not yet applied to the bar
    /// (docs/CORE-SETS.md M1). Cleared by Apply or Discard.
    public var orderEdits = OrderEdits()
    public var separators: [SeparatorSpec] = []

    /// Behavior template + per-display overrides, keyed by display UUID string.
    /// No UI writes the template yet — DisplaysPane edits only `displayOverrides`;
    /// the template is the fallback `behavior(forDisplayUUID:)` returns.
    public var displayTemplate: DisplayBehavior = .collapse
    public var displayOverrides: [String: DisplayBehavior] = [:]
    /// "Show hidden icons in" per display (#88), keyed like
    /// `displayOverrides`. A display with no entry follows `hiddenIconsIn`
    /// (Settings › Displays calls it "Same as Panel tab").
    public var displayRevealTargets: [String: RevealTarget] = [:]

    public var rehidePolicy: RehidePolicy {
        RehidePolicy(
            autoRehide: autoRehide,
            delay: rehideDelay,
            rehideOnClickElsewhere: rehideOnClickElsewhere
        )
    }

    /// Whether the bar's right-click menu actually opens. With the icon
    /// hidden it is the only way back into Settings, so it stays on whatever
    /// the stored preference says — a lockout the UI can merely discourage is
    /// one an old blob, or turning the icon off after disabling the menu,
    /// walks straight into. Turning the icon back on restores the choice.
    public var barRightClickMenuActive: Bool { barRightClickMenu || !showStatusItem }

    public func behavior(forDisplayUUID uuid: String?) -> DisplayBehavior {
        guard let uuid else { return displayTemplate }
        return displayOverrides[uuid] ?? displayTemplate
    }

    /// Each display keeps its own behavior wherever the pointer is (#88): a
    /// connected display that shows all icons holds the bar out, and the
    /// ones that hide icons are covered. macOS draws one set of icons on
    /// every bar, so this is the only way both can hold at once.
    public func anchorsReveal(connectedDisplayUUIDs uuids: [String?]) -> Bool {
        uuids.contains { behavior(forDisplayUUID: $0) == .alwaysShowAll }
    }

    /// Where a reveal decided on this display shows the hidden icons: its own
    /// choice, else the Panel tab's. On a display that shows all icons it is
    /// where a chevron click opens Always Hidden (#96).
    public func revealTarget(forDisplayUUID uuid: String?) -> RevealTarget {
        ownRevealTarget(forDisplayUUID: uuid) ?? hiddenIconsIn
    }

    /// A panel or a row shows the hidden icons somewhere: the Panel tab's
    /// choice, or a display's own.
    public var usesPanel: Bool {
        hiddenIconsIn.panelLayout != nil
            || displayRevealTargets.keys.contains { ownRevealTarget(forDisplayUUID: $0)?.panelLayout != nil }
    }

    /// The display's own "Show hidden icons in", when it has one.
    public func ownRevealTarget(forDisplayUUID uuid: String?) -> RevealTarget? {
        guard let uuid else { return nil }
        return displayRevealTargets[uuid]
    }

    // MARK: - Codable (resilient: new fields fall back to defaults instead of
    // failing the whole decode and silently resetting the user's settings)

    private enum CodingKeys: String, CodingKey {
        case onboardingCompleted, launchAtLogin, showStatusItem, hotkey, settingsHotkey, alwaysHiddenHotkey, searchHotkey
        case itemHotkeys, itemAliases
        case revealTriggers, autoRehide, rehideDelay, rehideOnClickElsewhere, revealAnimation
        case hideSystemExtras, showMediaControls, extraItems, sectionModel, separators
        case displayTemplate, displayOverrides, displayRevealTargets
        case notifyOnUpdates, barRightClickMenu, betaUpdates
        case statusIconStyle
        case clockClickOpensNotificationCenter, notificationCenterHotkey
        case showLiveActivities, hiddenLiveActivities
        case orderEdits
        case hiddenIconsIn, panel
        case showRules
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = SettingsStore()
        // Per field (`KeyedDecodingContainer.field`): one bad field resets
        // THAT field, not every preference via load()'s outer `try?`.
        onboardingCompleted = c.field(Bool.self, .onboardingCompleted, defaults.onboardingCompleted)
        launchAtLogin = c.field(Bool.self, .launchAtLogin, defaults.launchAtLogin)
        showStatusItem = c.field(Bool.self, .showStatusItem, defaults.showStatusItem)
        hotkey = c.field(HotkeySpec?.self, .hotkey, defaults.hotkey) ?? defaults.hotkey
        settingsHotkey = c.field(HotkeySpec?.self, .settingsHotkey, defaults.settingsHotkey) ?? defaults.settingsHotkey
        alwaysHiddenHotkey = c.field(HotkeySpec?.self, .alwaysHiddenHotkey, defaults.alwaysHiddenHotkey) ?? defaults.alwaysHiddenHotkey
        searchHotkey = c.field(HotkeySpec?.self, .searchHotkey, defaults.searchHotkey) ?? defaults.searchHotkey
        itemHotkeys = c.field([String: HotkeySpec].self, .itemHotkeys, defaults.itemHotkeys)
        itemAliases = c.field([String: String].self, .itemAliases, defaults.itemAliases)
        revealTriggers = c.field(RevealTriggers.self, .revealTriggers, defaults.revealTriggers)
        autoRehide = c.field(Bool.self, .autoRehide, defaults.autoRehide)
        rehideDelay = c.field(TimeInterval.self, .rehideDelay, defaults.rehideDelay)
        rehideOnClickElsewhere = c.field(Bool.self, .rehideOnClickElsewhere, defaults.rehideOnClickElsewhere)
        revealAnimation = c.field(RevealAnimation.self, .revealAnimation, defaults.revealAnimation)
        hideSystemExtras = c.field(Bool.self, .hideSystemExtras, defaults.hideSystemExtras)
        showMediaControls = c.field(Bool.self, .showMediaControls, defaults.showMediaControls)
        extraItems = c.field([ExtraItemSpec].self, .extraItems, defaults.extraItems)
        sectionModel = c.field(SectionModel.self, .sectionModel, defaults.sectionModel)
        separators = c.field([SeparatorSpec].self, .separators, defaults.separators)
        displayTemplate = c.field(DisplayBehavior.self, .displayTemplate, defaults.displayTemplate)
        displayOverrides = c.field([String: DisplayBehavior].self, .displayOverrides, defaults.displayOverrides)
        displayRevealTargets = c.eachValue(RevealTarget.init(rawValue:), .displayRevealTargets)
        notifyOnUpdates = c.field(Bool.self, .notifyOnUpdates, defaults.notifyOnUpdates)
        betaUpdates = c.field(Bool.self, .betaUpdates, defaults.betaUpdates)
        barRightClickMenu = c.field(Bool.self, .barRightClickMenu, defaults.barRightClickMenu)
        statusIconStyle = c.field(StatusIconStyle.self, .statusIconStyle, defaults.statusIconStyle)
        clockClickOpensNotificationCenter = c.field(Bool.self, .clockClickOpensNotificationCenter, defaults.clockClickOpensNotificationCenter)
        notificationCenterHotkey = c.field(HotkeySpec?.self, .notificationCenterHotkey, defaults.notificationCenterHotkey) ?? defaults.notificationCenterHotkey
        showLiveActivities = c.field(Bool.self, .showLiveActivities, defaults.showLiveActivities)
        hiddenLiveActivities = c.field(Set<String>.self, .hiddenLiveActivities, defaults.hiddenLiveActivities)
        orderEdits = c.field(OrderEdits.self, .orderEdits, defaults.orderEdits)
        hiddenIconsIn = c.field(RevealTarget.self, .hiddenIconsIn, defaults.hiddenIconsIn)
        panel = c.field(PanelOptions.self, .panel, defaults.panel)
        showRules = c.field(ShowRuleSettings.self, .showRules, defaults.showRules)
    }

    // MARK: - Persistence

    private static let defaultsKey = "app.fif7y.Pelmet.settings.v1"

    public static func load(defaults: UserDefaults = .standard) -> SettingsStore {
        guard
            let data = defaults.data(forKey: defaultsKey),
            let store = try? JSONDecoder().decode(SettingsStore.self, from: data)
        else { return SettingsStore() }
        return store
    }

    public func save(defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    public init() {}
}

extension KeyedDecodingContainer {
    /// The settings blob's forgiving decode, shared by every type nested in
    /// it. `try?` per field, not just decodeIfPresent: a present-but-invalid
    /// value (unknown enum case after a downgrade, hand-edited blob) throws
    /// out of decodeIfPresent, and one bad field must fall back to `fallback`
    /// for that field alone, not throw the whole value out.
    func field<T: Decodable>(_ type: T.Type, _ key: Key, _ fallback: T) -> T {
        ((try? decodeIfPresent(type, forKey: key)) ?? nil) ?? fallback
    }

    /// A string-keyed map read value by value: a value that isn't a string
    /// `make` knows drops that entry alone, where `field` would drop the
    /// whole map over one of them.
    func eachValue<T>(_ make: (String) -> T?, _ key: Key) -> [String: T] {
        guard let map = try? nestedContainer(keyedBy: MapKey.self, forKey: key) else { return [:] }
        var values: [String: T] = [:]
        for entry in map.allKeys {
            if let raw = try? map.decode(String.self, forKey: entry), let value = make(raw) {
                values[entry.stringValue] = value
            }
        }
        return values
    }
}

/// Any key of a string-keyed map (`eachValue`).
private struct MapKey: CodingKey {
    let stringValue: String
    init(stringValue: String) { self.stringValue = stringValue }
    var intValue: Int? { nil }
    init?(intValue: Int) { nil }
}
