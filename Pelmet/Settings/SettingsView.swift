// SettingsView.swift
// Sidebar-shell settings: tab list on the left, one scrolling pane on the
// right. De-box throughout — panes are borderless cards on soft fills, the
// brand accent carries selection and controls. About pane included.

import PelmetCore
import PelmetEngine
import ServiceManagement
import SwiftUI

/// Accent presets for Settings › General. Purple is the brand default.
/// Read once at launch; changing it offers a relaunch.
enum AccentChoice: String, CaseIterable, Identifiable {
    case purple, blue, green, orange, pink
    static let key = "pelmet.accent"
    static var current: AccentChoice {
        UserDefaults.standard.string(forKey: key).flatMap(AccentChoice.init) ?? .purple
    }

    var id: String { rawValue }

    var label: LocalizedStringKey {
        switch self {
        case .purple: "Purple"
        case .blue: "Blue"
        case .green: "Green"
        case .orange: "Orange"
        case .pink: "Pink"
        }
    }

    /// (light, dark) as 0xRRGGBB; dark is lighter for contrast.
    private var hex: (UInt32, UInt32) {
        switch self {
        case .purple: (0x6841ED, 0x7E5FF2)
        case .blue: (0x0A6CFF, 0x4C93FF)
        case .green: (0x1F9D55, 0x3DBE76)
        case .orange: (0xD9610A, 0xFF9640)
        case .pink: (0xD6336C, 0xF06595)
        }
    }

    private static func ns(_ hex: UInt32) -> NSColor {
        NSColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }

    var nsColor: NSColor {
        let (light, dark) = hex
        return NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? Self.ns(dark) : Self.ns(light)
        }
    }
}

/// The accent — pelmet purple unless the user picked another; slightly
/// lighter in dark mode for contrast.
enum PelmetAccent {
    static let nsColor = AccentChoice.current.nsColor
    static let accent = Color(nsColor: nsColor)

    /// GitHub-star gold: bright on dark, amber on light so the label stays legible.
    static let star = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 1.0, green: 0.84, blue: 0.2, alpha: 1)    // #FFD633
            : NSColor(red: 0.72, green: 0.5, blue: 0.0, alpha: 1)    // #B88000
    })
}

enum SettingsTab: String, CaseIterable, Identifiable {
    case general = "General"
    case menuBar = "Menu Bar"
    case panel = "Panel"
    case behavior = "Behavior"
    case search = "Search"
    case displays = "Displays"
    case thanks = "Thanks"
    case about = "About"

    var id: String { rawValue }

    /// Localized label — `rawValue` stays the stable identifier.
    var title: LocalizedStringKey {
        switch self {
        case .general: "General"
        case .behavior: "Behavior"
        case .menuBar: "Menu Bar"
        case .panel: "Panel"
        case .search: "Search"
        case .displays: "Displays"
        case .thanks: "Thanks"
        case .about: "About"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .behavior: "cursorarrow.motionlines"
        case .menuBar: "menubar.rectangle"
        case .panel: "square.grid.2x2"
        case .search: "magnifyingglass"
        case .displays: "display.2"
        case .thanks: "heart"
        case .about: "shippingbox"
        }
    }
}

struct SettingsView: View {
    @Environment(AppState.self) private var appState

    // Selection lives on AppState so the window controller can reset it to
    // General on every open — the hosting view survives window close, and a
    // window reopening straight onto the Menu Bar tab fired its full-reveal
    // preview before the user asked for anything.
    private var tab: Binding<SettingsTab> {
        Binding(
            get: { appState.settingsTab },
            set: { appState.settingsTab = $0 }
        )
    }

    var body: some View {
        HStack(spacing: 0) {
            SettingsSidebar(tab: tab)
            content
        }
        .frame(minWidth: 720, minHeight: 520)
        .tint(PelmetAccent.accent)
    }

    /// The title row pins; its glass only shows once the pane has scrolled
    /// under it (the row starts as plain content).
    @State private var headerPinned = false
    @State private var gapHeight: CGFloat = 0
    /// The row the command bar just jumped to, tinted while it is set.
    @State private var highlightedRow: String?

    private var content: some View {
        scrollArea
            .environment(\.highlightedSetting, highlightedRow)
            .onChange(of: appState.settingsFocusRow, initial: true) { _, row in
                if let row { jump(to: row) }
            }
    }

    private var scrollArea: some View {
        GeometryReader { geo in
            // The content area runs under the transparent titlebar; the
            // scroll view takes that band too so the pinned row covers it.
            let safeTop = geo.safeAreaInsets.top
            ScrollView {
                // The title row is a pinned header: it carries the pane's one
                // bar-wide action (Apply on Menu Bar) and must stay in reach
                // however far the strips scroll.
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: .sectionHeaders) {
                    // A pending update greets every pane, About excepted (it
                    // holds the button itself). One line, one action. Scrolls
                    // away with the top gap — the header stays lean.
                    VStack(alignment: .leading, spacing: 0) {
                        if let version = SparkleController.shared.availableVersion,
                           appState.settingsTab != .about {
                            UpdateStrip(version: version) { appState.settingsTab = .about }
                                .padding(.bottom, 14)
                        }
                    }
                    .padding(.horizontal, 28)
                    .padding(.top, 28)
                    .frame(maxWidth: 640, alignment: .leading)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { gapHeight = $0 }
                    Section {
                        VStack(alignment: .leading, spacing: 24) {
                            switch appState.settingsTab {
                            case .general: GeneralPane()
                            case .behavior: BehaviorPane()
                            case .menuBar: MenuBarTab()
                            case .panel: PanelPane()
                            case .search: SearchPane()
                            case .displays: DisplaysPane()
                            case .thanks: ThanksPane()
                            case .about: AboutPane()
                            }
                        }
                        .padding(.horizontal, 28)
                        .padding(.top, 12)
                        .padding(.bottom, 28)
                        .frame(maxWidth: 640, alignment: .leading)
                    } header: {
                        HStack(alignment: .firstTextBaseline) {
                            Text(appState.settingsTab.title)
                                .font(.system(size: 22, weight: .semibold))
                            if appState.settingsTab == .menuBar {
                                // The hint gives way first: it truncates,
                                // its sentence is the tooltip. Squeezed, the
                                // actions wrapped letter by letter ("Re try",
                                // live test 2026-10-19).
                                OverflowHint()
                                    .padding(.leading, 8)
                                    .layoutPriority(-1)
                            }
                            Spacer(minLength: 8)
                            if appState.settingsTab == .menuBar {
                                ApplyBarButton()
                                    .fixedSize()
                            }
                        }
                        .padding(.horizontal, 28)
                        .padding(.vertical, 10)
                        // The titlebar band is part of the row, so pinned
                        // glass reaches the window's top edge and nothing
                        // peeks above it.
                        .padding(.top, safeTop)
                        .frame(maxWidth: 640, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.ultraThinMaterial.opacity(headerPinned ? 1 : 0))
                        .animation(.easeOut(duration: 0.15), value: headerPinned)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // One scroll view per tab: each pane opens at its top. With a
            // shared one, a trackpad scroll down a long pane then a click on
            // Displays drew a blank pane, and every tab stayed blank after
            // (2026-10-04) — the old offset outlived the content it fit.
            .id(appState.settingsTab)
            .ignoresSafeArea(edges: .top)
            .onScrollGeometryChange(for: Bool.self) { $0.contentOffset.y >= gapHeight - 0.5 } action: { _, pinned in
                headerPinned = pinned
            }
        }
        .background(Color(nsColor: .textBackgroundColor).opacity(0.35))
    }
}

extension SettingsView {
    /// Scroll a row the command bar named into view and tint it once. The
    /// pane under a fresh scroll view is not laid out for a beat, so the
    /// scroll waits for it.
    fileprivate func jump(to row: String) {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            guard appState.settingsFocusRow == row else { return }
            appState.settingsFocusRow = nil
            // Through AppKit: SwiftUI's scrollTo never moved the pane for a
            // row inside it (the pane is one child of a lazy stack), and the
            // row stayed out of view (2026-10-12).
            guard let view = SettingAnchorViews.table.object(forKey: row as NSString),
                  let scroll = view.enclosingScrollView else {
                PelmetLog.log("settings: jump to \(row) — no such row on screen")
                return
            }
            let clip = scroll.contentView
            let frame = view.convert(view.bounds, to: clip)
            let centred = NSRect(origin: NSPoint(x: clip.bounds.minX, y: frame.midY - clip.bounds.height / 2), size: clip.bounds.size)
            let target = clip.constrainBoundsRect(centred).origin
            PelmetLog.log("settings: jump to \(row), y \(Int(clip.bounds.minY)) → \(Int(target.y))")
            highlightedRow = row
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.35
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                clip.animator().setBoundsOrigin(target)
            }, completionHandler: nil)
            // Held while the pane slides there, then the tint fades out over a second.
            try? await Task.sleep(for: .milliseconds(650))
            if highlightedRow == row { highlightedRow = nil }
        }
    }
}

// MARK: - Jumping to a row

private struct HighlightedSettingKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

extension EnvironmentValues {
    fileprivate var highlightedSetting: String? {
        get { self[HighlightedSettingKey.self] }
        set { self[HighlightedSettingKey.self] = newValue }
    }
}

extension View {
    /// Marks a row the command bar can jump to (`SettingsIndex` ids): found
    /// by id for the scroll, and tinted softly while it is the one jumped to.
    func settingAnchor(_ id: String) -> some View {
        modifier(SettingAnchor(id: id))
    }
}

private struct SettingAnchor: ViewModifier {
    let id: String
    @Environment(\.highlightedSetting) private var highlighted

    func body(content: Content) -> some View {
        let lit = highlighted == id
        content
            .background {
                // Fill, never an outline; reaches a little past the row.
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(PelmetAccent.accent.opacity(lit ? 0.16 : 0))
                    .padding(-6)
                    .animation(lit ? .easeOut(duration: 0.15) : .easeOut(duration: 1.0), value: lit)
                    .allowsHitTesting(false)
            }
            .background(SettingAnchorMarker(id: id).allowsHitTesting(false))
    }
}

/// Each anchored row's AppKit view: what a jump scrolls to.
@MainActor
private enum SettingAnchorViews {
    static let table = NSMapTable<NSString, NSView>.strongToWeakObjects()
}

private struct SettingAnchorMarker: NSViewRepresentable {
    let id: String

    final class Marker: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    func makeNSView(context: Context) -> Marker {
        let view = Marker()
        SettingAnchorViews.table.setObject(view, forKey: id as NSString)
        return view
    }

    func updateNSView(_ view: Marker, context: Context) {
        SettingAnchorViews.table.setObject(view, forKey: id as NSString)
    }
}

/// Pending-update strip atop the non-About panes: green low-alpha fill
/// (de-box), text left, the one action right — a trail to About.
private struct UpdateStrip: View {
    let version: String
    let action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 15))
                .foregroundStyle(.green)
            Text("Dimble \(version) is available.")
                .font(.callout)
            Spacer(minLength: 8)
            // Same tinted chip as Apply and "Granted": tint on a low-alpha
            // fill, no white-on-green.
            TintChipButton(text: "Update", symbol: "arrow.down.circle.fill", tint: .green, action: action)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Sidebar

private struct SettingsSidebar: View {
    @Environment(AppState.self) private var appState
    @Binding var tab: SettingsTab
    /// The Panel and Search tabs' "New" chips go once the tab has been opened.
    @AppStorage("pelmet.seen.panelTab") private var panelTabSeen = false
    @AppStorage("pelmet.seen.searchTab") private var searchTabSeen = false

    private func isNew(_ item: SettingsTab) -> Bool {
        (item == .panel && !panelTabSeen) || (item == .search && !searchTabSeen)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(SettingsTab.allCases) { item in
                // Everything above is the app's settings; Thanks and About
                // are the rest. One quiet hairline marks the split.
                if item == .thanks {
                    Rectangle()
                        .fill(.primary.opacity(0.08))
                        .frame(height: 1)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                }
                SidebarRow(
                    item: item,
                    selected: tab == item,
                    // The Accessibility row lives in General; the dot says
                    // "something here needs you" from any tab.
                    attention: item == .general && !appState.accessibilityGranted,
                    // An available update puts a green chip on the About row
                    // — a trail for someone who just opened Settings.
                    badge: item == .about && SparkleController.shared.availableVersion != nil
                        ? "Update" : isNew(item) ? "New" : nil,
                    badgeTint: item == .about ? .green : PelmetAccent.accent
                ) { tab = item }
            }
            Spacer()
        }
        .padding(10)
        // Clear the traffic lights — the sidebar runs under the titlebar.
        .padding(.top, 42)
        .frame(width: 196, alignment: .leading)
        .frame(maxHeight: .infinity)
        .background(.quaternary.opacity(0.35))
        .onChange(of: tab, initial: true) { _, now in
            if now == .panel { panelTabSeen = true }
            if now == .search { searchTabSeen = true }
        }
    }
}

private struct SidebarRow: View {
    let item: SettingsTab
    let selected: Bool
    var attention = false
    var badge: LocalizedStringKey? = nil
    var badgeTint: Color = .green
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: item.symbol)
                    .font(.system(size: 13))
                    .frame(width: 18, height: 17)
                // The badge sits beside the title when both fit at their
                // natural width (en "About · Update"), otherwise underneath
                // (ru "О программе" + "Обновить") — never a truncated title.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        title.fixedSize()
                        Spacer(minLength: 4)
                        attentionDot
                        badgeChip
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 8) {
                            title
                            Spacer(minLength: 4)
                            attentionDot
                        }
                        badgeChip
                    }
                }
            }
            .foregroundStyle(selected ? PelmetAccent.accent : .primary)
            .padding(.horizontal, 9)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(selected
                        ? PelmetAccent.accent.opacity(0.16)
                        : .primary.opacity(hovered ? 0.06 : 0))
            )
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onHover { hovered = $0 }
    }

    /// Size the row for the semibold weight so selecting never reflows —
    /// the regular label sits over a hidden bold twin.
    private var title: some View {
        Text(item.title)
            .font(.system(size: 13, weight: .semibold))
            .hidden()
            .overlay(alignment: .leading) {
                Text(item.title)
                    .font(.system(size: 13, weight: selected ? .semibold : .regular))
            }
            .lineLimit(1)
            .truncationMode(.tail)
    }

    @ViewBuilder private var attentionDot: some View {
        if attention {
            Circle().fill(.orange).frame(width: 7, height: 7)
        }
    }

    @ViewBuilder private var badgeChip: some View {
        if let badge {
            Text(badge)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(badgeTint)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(badgeTint.opacity(0.13), in: Capsule())
        }
    }
}

// MARK: - Segments

/// De-boxed button group: soft-fill track, the selected chip carried by the
/// brand accent — every option visible at once, no menu to open.
/// Outbound help links. The FAQ is one page with named anchors.
enum PelmetLinks {
    static let faqAppLaunchers = URL(string: "https://github.com/fif7y/dimble/blob/main/docs/FAQ.md#app-launchers")!
}

struct PelmetSegments<T: Hashable>: View {
    @Binding var selection: T
    let options: [(T, LocalizedStringKey)]
    /// Row-sized: sits inside a card, so it needs a stronger fill to
    /// separate from the card's own and smaller type to match row captions.
    var compact = false

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.0) { value, label in
                PelmetSegmentButton(label: label, selected: selection == value, compact: compact) {
                    selection = value
                }
            }
        }
        .padding(compact ? 2 : 3)
        .background(
            RoundedRectangle(cornerRadius: compact ? 8 : 9)
                .fill(.quaternary.opacity(compact ? 0.6 : 0.35))
        )
        .animation(.spring(duration: 0.22), value: selection)
    }
}

private struct PelmetSegmentButton: View {
    let label: LocalizedStringKey
    let selected: Bool
    var compact = false
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: compact ? 11 : 12, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? PelmetAccent.accent : .secondary)
                .padding(.horizontal, compact ? 9 : 10)
                .padding(.vertical, compact ? 3 : 4)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(selected
                            ? PelmetAccent.accent.opacity(0.16)
                            : .primary.opacity(hovered ? 0.06 : 0))
                )
                .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onHover { hovered = $0 }
    }
}

// MARK: - Card + rows

/// The card's own surface — soft fill, no outline (de-box). Used by the
/// Menu Bar tab's item cards, which set their own row rhythm and each had
/// the inset, radius and fill typed out by hand. `SettingsCard` keeps its
/// inline chain: it needs `.frame(maxWidth:)` BETWEEN the inset and the
/// fill, and modifier order is geometry here, not style.
extension View {
    func pelmetCardSurface(cornerRadius: CGFloat = 12) -> some View {
        self
            .padding(14)
            .background(RoundedRectangle(cornerRadius: cornerRadius).fill(.quaternary.opacity(0.35)))
    }
}

/// Borderless grouping card: soft fill, no outline (de-box).
struct SettingsCard<Content: View>: View {
    var title: LocalizedStringKey? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title)
                    .font(.headline)
            }
            VStack(alignment: .leading, spacing: 14) {
                content
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(.quaternary.opacity(0.35)))
        }
    }
}

/// Title + optional caption on the left, any control on the right.
/// A menu that sizes to the SELECTED value, not to its widest option.
/// SwiftUI's `.pickerStyle(.menu)` reserves room for the longest entry, so
/// one long translation inflated the closed control and squeezed the row's
/// own label into a ragged column (French "Afficher lorsque la barre est
/// déployée" made the closed "Toujours masqués" ~280pt wide).
struct PelmetMenuPicker<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(Value, LocalizedStringKey)]
    /// Row-sized: a caption-weight label with no button chrome, for a menu
    /// that sits inside a card row rather than beside a setting.
    var borderless = false
    /// Borderless only: the label in the brand accent, for a value that
    /// belongs to the switch beside it (the hover delay, a show rule's
    /// condition).
    var accent = false

    private var currentLabel: LocalizedStringKey {
        options.first { $0.0 == selection }?.1 ?? ""
    }

    var body: some View {
        Menu {
            // Toggles carry the native checkmark; a Label's symbol is
            // dropped by macOS menus. Any pick writes, the checked one too:
            // unchecking it wrote nothing, so a value shown as its nearest
            // option could never be set to that option.
            ForEach(options, id: \.0) { value, label in
                Toggle(label, isOn: Binding(
                    get: { selection == value },
                    set: { _ in selection = value }
                ))
            }
        } label: {
            Text(currentLabel)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .modifier(MenuPickerChrome(borderless: borderless, accent: accent))
    }
}

/// The two chromes are different view types, so the branch lives in a
/// modifier SwiftUI can resolve statically. Nothing outside the borderless
/// branch touches the bordered picker's appearance.
private struct MenuPickerChrome: ViewModifier {
    let borderless: Bool
    let accent: Bool

    func body(content: Content) -> some View {
        if borderless {
            content
                .menuStyle(.borderlessButton)
                .font(.caption)
                .foregroundStyle(accent ? AnyShapeStyle(PelmetAccent.accent) : AnyShapeStyle(.secondary))
        } else {
            content
                .menuStyle(.button)
                .buttonStyle(.bordered)
                .fixedSize()
        }
    }
}

struct SettingRow<Control: View>: View {
    let title: Text
    var caption: LocalizedStringKey? = nil
    let control: Control
    /// An orange dot before the title: "this needs you" (the sidebar's dot,
    /// carried down to the row it points at).
    private var attention = false
    /// A control of the row's own under its title, where the caption goes.
    private var detail: AnyView?

    /// Literal titles localize through the string catalog.
    init(title: LocalizedStringKey, caption: LocalizedStringKey? = nil, @ViewBuilder control: () -> Control) {
        self.title = Text(title)
        self.caption = caption
        self.control = control()
    }

    /// Runtime titles (display names, user data) are shown as-is.
    init(verbatim title: String, caption: LocalizedStringKey? = nil, @ViewBuilder control: () -> Control) {
        self.title = Text(verbatim: title)
        self.caption = caption
        self.control = control()
    }

    func attention(_ on: Bool) -> Self {
        var row = self
        row.attention = on
        return row
    }

    func detail<Detail: View>(@ViewBuilder _ content: () -> Detail) -> Self {
        var row = self
        row.detail = AnyView(content())
        return row
    }

    private var label: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                if attention {
                    Circle().fill(.orange).frame(width: 7, height: 7)
                }
                title
            }
            if let caption {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            detail
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    var body: some View {
        // A long title beside a fixed-width control (a menu Picker sizes to
        // its widest option) squeezed the text into a ragged column —
        // French "Lecture en cours, commandes de caméra, AirDrop,
        // Concentration" wrapped to four lines beside its own caption.
        // Side by side while both fit, control below when they don't.
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 12) {
                label
                Spacer(minLength: 16)
                control
            }
            VStack(alignment: .leading, spacing: 8) {
                label
                HStack { Spacer(minLength: 0); control }
            }
        }
    }
}

/// The row switch, small and unlabeled. One recipe for the toggle rows and
/// for rows that put another control beside it.
struct SettingSwitch: View {
    @Binding var isOn: Bool

    var body: some View {
        Toggle("", isOn: $isOn)
            .toggleStyle(.switch)
            .controlSize(.small)
            .labelsHidden()
    }
}

struct SettingToggleRow: View {
    let title: LocalizedStringKey
    var caption: LocalizedStringKey? = nil
    @Binding var isOn: Bool

    var body: some View {
        SettingRow(title: title, caption: caption) {
            SettingSwitch(isOn: $isOn)
        }
    }
}

/// Eight glyphs for the menu bar icon, drawn at bar size. Picking one repaints
/// the live status item through settingsChanged().
struct StatusIconPicker: View {
    @Binding var selection: StatusIconStyle

    var body: some View {
        HStack(spacing: 2) {
            ForEach(StatusIconStyle.allCases) { style in
                StatusIconTile(
                    symbol: style.symbol(revealed: false),
                    size: style.symbolPointSize ?? 13,
                    name: style.name,
                    selected: selection == style
                ) {
                    selection = style
                }
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 9).fill(.quaternary.opacity(0.35)))
        .animation(.spring(duration: 0.22), value: selection)
    }
}

extension StatusIconStyle {
    /// What the tile's tooltip calls the glyph.
    fileprivate var name: LocalizedStringKey {
        switch self {
        case .chevron: "Chevron"
        case .arrow: "Arrow"
        case .eye: "Eye"
        case .dots: "Dots"
        case .grid: "Grid"
        case .panel: "Panel"
        case .dot: "Dot"
        case .smallDot: "Small Dot"
        }
    }
}

private struct StatusIconTile: View {
    let symbol: String
    let size: Double
    let name: LocalizedStringKey
    let selected: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(selected ? PelmetAccent.accent : .secondary)
                .frame(width: 30, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(selected
                            ? PelmetAccent.accent.opacity(0.16)
                            : .primary.opacity(hovered ? 0.06 : 0))
                )
                .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onHover { hovered = $0 }
        .help(name)
    }
}

/// A quiet explanatory box inside a card — for the "what happens if" line
/// that is too long to sit as a row caption.
struct SettingNote: View {
    let text: LocalizedStringKey
    init(_ text: LocalizedStringKey) { self.text = text }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.5)))
    }
}

// MARK: - General

private struct GeneralPane: View {
    @Environment(AppState.self) private var appState
    @State private var language = AppLanguage.current
    @State private var accent = AccentChoice.current

    private func offerAccentRelaunch() {
        let alert = NSAlert()
        alert.messageText = String(localized: "Relaunch Dimble to change its accent color?")
        alert.informativeText = String(localized: "The new color applies the next time Dimble opens. Your menu bar layout is kept.")
        alert.addButton(withTitle: String(localized: "Relaunch Now"))
        alert.addButton(withTitle: String(localized: "Later"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        AppLanguage.relaunchReopeningSettings(tab: .general)
    }

    var body: some View {
        SettingsCard {
            SettingToggleRow(
                title: "Launch at login",
                isOn: binding(\.launchAtLogin) { enabled in
                    try? enabled
                        ? SMAppService.mainApp.register()
                        : SMAppService.mainApp.unregister()
                }
            )
            .settingAnchor("launchAtLogin")
            SettingToggleRow(
                title: "Show Dimble icon in the menu bar",
                isOn: binding(\.showStatusItem, onSet: { enabled in
                    if !enabled { showIconlessHint() }
                })
            )
            .settingAnchor("showStatusItem")
            if appState.settings.showStatusItem {
                SettingRow(title: "Icon") {
                    StatusIconPicker(selection: binding(\.statusIconStyle))
                }
            }
            SettingToggleRow(
                // Named, not spelled out: a sentence long enough to say the
                // whole thing pushed the switch onto its own line in
                // Portuguese. Short title, caption short enough to leave the
                // switch on the right, same shape as the other rows.
                title: "Right-click menu",
                caption: appState.settings.showStatusItem
                    ? "Dimble's menu from any empty spot on the bar."
                    : "Stays on while the Dimble icon is hidden. It's your way back here.",
                isOn: Binding(
                    get: { appState.settings.barRightClickMenuActive },
                    set: { enabled in
                        appState.settings.barRightClickMenu = enabled
                        appState.settingsChanged()
                    }
                )
            )
            .settingAnchor("rightClickMenu")
            .disabled(!appState.settings.showStatusItem)
            // "Without it" is advice for a state you are not in while the
            // icon is there — it belongs to the card only once it applies.
            if !appState.settings.showStatusItem {
                if let settingsShortcut {
                    SettingNote("Without it: press \(settingsShortcut), reopen Dimble from Spotlight, or right-click a separator or empty menu bar spot.")
                } else {
                    SettingNote("Without it: reopen Dimble from Spotlight, or right-click a separator or empty menu bar spot.")
                }
            }
        }

        SettingsCard(title: "Shortcuts") {
            shortcutRow("Show hidden icons", binding(\.hotkey), fallback: .default,
                        conflict: appState.hotkeyConflict)
                .settingAnchor("hotkey")
            shortcutRow("Show Always Hidden too", binding(\.alwaysHiddenHotkey), fallback: .alwaysHiddenDefault,
                        conflict: appState.alwaysHiddenHotkeyConflict)
            // The same setting Search's own recorder edits.
            shortcutRow("Search the menu bar", binding(\.searchHotkey), fallback: .searchDefault,
                        conflict: appState.searchHotkeyConflict)
            // Registered only while the clock click is on (Behavior).
            if appState.settings.clockClickOpensNotificationCenter {
                shortcutRow("Open Notification Center", binding(\.notificationCenterHotkey),
                            fallback: .notificationCenterDefault,
                            conflict: appState.notificationCenterHotkeyConflict)
            }
            shortcutRow("Open Settings", binding(\.settingsHotkey), fallback: .settingsDefault,
                        conflict: appState.settingsHotkeyConflict)
                .settingAnchor("settingsHotkey")
        }

        SettingsCard(title: "Language") {
            SettingRow(title: "Display language", caption: "Relaunches Dimble to apply.") {
                PelmetMenuPicker(selection: $language, options: languageOptions)
                    .onChange(of: language) { _, newValue in
                        guard newValue != AppLanguage.current else { return }
                        AppLanguage.set(newValue)
                        AppLanguage.offerRelaunch()
                    }
            }
            .settingAnchor("language")
        }

        SettingsCard(title: "Appearance") {
            SettingRow(title: "Accent color", caption: "Relaunches Dimble to apply.") {
                HStack(spacing: 8) {
                    ForEach(AccentChoice.allCases) { choice in
                        Button {
                            guard choice != accent else { return }
                            accent = choice
                            UserDefaults.standard.set(choice.rawValue, forKey: AccentChoice.key)
                            offerAccentRelaunch()
                        } label: {
                            Circle()
                                .fill(Color(nsColor: choice.nsColor))
                                .frame(width: 18, height: 18)
                                .padding(3)
                                .overlay(Circle().strokeBorder(
                                    Color(nsColor: choice.nsColor), lineWidth: accent == choice ? 1.5 : 0))
                        }
                        .buttonStyle(.plain)
                        .help(Text(choice.label))
                        .accessibilityLabel(Text(choice.label))
                    }
                }
            }
            .settingAnchor("accentColor")
        }

        SettingsCard(title: "Permissions") {
            permissions
        }
        .task {
            // The grant lands in System Settings, outside our window —
            // poll while the tab is up so the rows flip without a relaunch.
            while !Task.isCancelled {
                appState.refreshScreenRecording()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// A language name is shown in itself and never translated: the
    /// endonyms are not catalog keys, so they render as they are.
    private var languageOptions: [(AppLanguage, LocalizedStringKey)] {
        [(.system, LocalizedStringKey("System language"))]
            + AppLanguage.allCases.filter { $0 != .system }.map { ($0, LocalizedStringKey($0.endonym)) }
    }

    /// One shortcut row: the recorder on the right. A caption only when the
    /// shortcut can't fire (another app or macOS holds it).
    private func shortcutRow(
        _ title: LocalizedStringKey,
        _ shortcut: Binding<HotkeySpec?>,
        fallback: HotkeySpec,
        conflict: Bool
    ) -> some View {
        SettingRow(title: title, caption: hotkeyWarning(shortcut.wrappedValue, conflict: conflict)) {
            ShortcutRecorder(shortcut: shortcut, fallback: fallback)
        }
    }

    // MARK: Permissions

    /// Both on: one quiet line. Otherwise each missing grant asks for itself
    /// at the top and the granted one folds into a quiet line underneath.
    @ViewBuilder private var permissions: some View {
        let accessibility = appState.accessibilityGranted
        let recording = appState.screenRecordingGranted
        if accessibility && recording {
            // One line answers to both ids (the command bar jumps by either).
            VStack(alignment: .leading, spacing: 0) {
                grantedLine("Accessibility and Screen Recording are on.")
                    .settingAnchor("accessibility")
            }
            .settingAnchor("screenRecording")
        } else {
            if !accessibility {
                // The one that stops Pelmet working: the dot and the accent
                // button. Screen Recording only polishes the motion.
                SettingRow(
                    title: "Accessibility",
                    caption: "Dimble can't see or move your icons until it's on."
                ) {
                    AccentChipButton(text: "Grant access", symbol: "hand.raised.fill") {
                        AccessibilityAccess.request()
                    }
                }
                .attention(true)
                .settingAnchor("accessibility")
            }
            if !recording {
                SettingRow(
                    title: "Screen Recording",
                    caption: "Off. Turn it on for smoother show and hide animations."
                ) {
                    Button("Grant access") { ScreenRecordingAccess.request() }
                        .buttonStyle(.bordered)
                }
                .settingAnchor("screenRecording")
            }
            if accessibility {
                grantedLine("Accessibility is on.")
                    .settingAnchor("accessibility")
            }
            if recording {
                grantedLine("Screen Recording is on.")
                    .settingAnchor("screenRecording")
            }
        }
    }

    private func grantedLine(_ text: LocalizedStringKey) -> some View {
        Label {
            Text(text).foregroundStyle(.secondary)
        } icon: {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        }
        .font(.callout)
    }

    private func binding<T>(
        _ keyPath: WritableKeyPath<SettingsStore, T>,
        onSet: ((T) -> Void)? = nil
    ) -> Binding<T> {
        Binding(
            get: { appState.settings[keyPath: keyPath] },
            set: { newValue in
                appState.settings[keyPath: keyPath] = newValue
                onSet?(newValue)
                appState.settingsChanged()
            }
        )
    }

    /// Nil when the user turned the Settings shortcut off (#79).
    private var settingsShortcut: String? {
        let spec = appState.settings.settingsHotkey ?? .settingsDefault
        return spec.isOff ? nil : spec.display
    }

    /// One-time orientation when the user goes iconless.
    func showIconlessHint() {
        let alert = NSAlert()
        alert.messageText = String(localized: "Dimble stays a click away")
        if let settingsShortcut {
            alert.informativeText = String(localized: "You can always open Dimble Settings by:\n\n•  Pressing \(settingsShortcut)\n•  Opening Dimble again from Spotlight or Finder\n•  Right-clicking any Dimble separator in the menu bar\n•  Right-clicking an empty spot in the menu bar")
        } else {
            alert.informativeText = String(localized: "You can always open Dimble Settings by:\n\n•  Opening Dimble again from Spotlight or Finder\n•  Right-clicking any Dimble separator in the menu bar\n•  Right-clicking an empty spot in the menu bar")
        }
        alert.alertStyle = .informational
        alert.runModal()
    }
}

// MARK: - Behavior

/// How the bar behaves day to day: what reveals it, when it closes, and the
/// two macOS quirks Pelmet works around. App-level settings stay in General.
private struct BehaviorPane: View {
    @Environment(AppState.self) private var appState

    private static let hoverDelayOptions: [(TimeInterval, LocalizedStringKey)] = [
        (0.1, "After 0.1s"), (0.2, "After 0.2s"), (0.3, "After 0.3s"),
        (0.4, "After 0.4s"), (0.5, "After 0.5s"),
    ]

    var body: some View {
        SettingsCard(title: "Animation") {
            AnimationShowcase(selection: binding(\.revealAnimation))
        }
        .settingAnchor("animation")

        SettingsCard(title: "Icon spacing") {
            IconSpacingRow()
        }
        .settingAnchor("iconSpacing")

        SettingsCard(title: "Reveal") {
            SettingRow(
                title: "Reveal on hover",
                caption: "Rest the pointer on the right half of the menu bar."
            ) {
                HStack(spacing: 10) {
                    // The delay belongs to the switch: it shows only while
                    // hovering reveals anything.
                    if appState.settings.revealTriggers.hoverEnabled {
                        PelmetMenuPicker(selection: hoverDelay, options: Self.hoverDelayOptions,
                                         borderless: true, accent: true)
                    }
                    SettingSwitch(isOn: binding(\.revealTriggers.hoverEnabled))
                }
            }
            .settingAnchor("hoverReveal")
            SettingToggleRow(title: "Reveal on click in empty space", isOn: binding(\.revealTriggers.clickEnabled))
                .settingAnchor("clickReveal")
            SettingToggleRow(
                title: "Double-click shows Always Hidden too",
                caption: appState.settings.revealTriggers.clickEnabled
                    ? "On the chevron, and in empty space."
                    : "On the chevron.",
                isOn: binding(\.revealTriggers.doubleClickForAlwaysHidden)
            )
            .padding(.leading, 20)
            .settingAnchor("doubleClickReveal")
        }

        SettingsCard(title: "Hide again") {
            SettingRow(title: "When the pointer leaves the bar") {
                PelmetMenuPicker(selection: rehideChoice, options: RehideChoice.options)
            }
            .settingAnchor("autoRehide")
            SettingToggleRow(title: "When you click elsewhere", isOn: binding(\.rehideOnClickElsewhere))
                .settingAnchor("rehideElsewhere")
        }

        SettingsCard(title: "Notification Center") {
            SettingToggleRow(
                title: "Clicking the clock opens Notification Center",
                caption: appState.screenRecordingGranted
                    ? "Works with icons hidden. Dimble handles the click."
                    : "Works with icons hidden. Without Screen Recording, they flash by.",
                isOn: binding(\.clockClickOpensNotificationCenter)
            )
            .settingAnchor("clockClick")
        }
    }

    /// The stored delay as the nearest of the five the picker offers (an
    /// older store can hold any step of 0.1).
    private var hoverDelay: Binding<TimeInterval> {
        Binding(
            get: { nearest(appState.settings.revealTriggers.hoverDelay, in: Self.hoverDelayOptions.map(\.0)) },
            set: { newValue in
                appState.settings.revealTriggers.hoverDelay = newValue
                appState.settingsChanged()
            }
        )
    }

    private var rehideChoice: Binding<RehideChoice> {
        Binding(
            get: {
                guard appState.settings.autoRehide else { return .never }
                return .after(RehideChoice.snapped(appState.settings.rehideDelay))
            },
            set: { choice in
                switch choice {
                case .never:
                    appState.settings.autoRehide = false
                case .after(let seconds):
                    appState.settings.autoRehide = true
                    appState.settings.rehideDelay = seconds
                }
                appState.settingsChanged()
            }
        )
    }

    private func binding<T>(
        _ keyPath: WritableKeyPath<SettingsStore, T>,
        onSet: ((T) -> Void)? = nil
    ) -> Binding<T> {
        Binding(
            get: { appState.settings[keyPath: keyPath] },
            set: { newValue in
                appState.settings[keyPath: keyPath] = newValue
                onSet?(newValue)
                appState.settingsChanged()
            }
        )
    }
}

/// "Hide again" as one pick: how long after the pointer leaves, or never.
/// Never is the old Automatically rehide switched off, the rest are the
/// delay. A store saved with another 0.5 step is snapped onto these at
/// launch (AppState), so the checked delay is the one the bar waits.
enum RehideChoice: Hashable {
    case after(TimeInterval)
    case never

    static let delays: [TimeInterval] = [0, 0.5, 1, 2, 3, 5]

    /// The delay the menu offers closest to `delay`.
    static func snapped(_ delay: TimeInterval) -> TimeInterval {
        nearest(delay, in: delays)
    }

    static let options: [(RehideChoice, LocalizedStringKey)] = [
        (.after(0), "Right away"), (.after(0.5), "After half a second"),
        (.after(1), "After 1 second"), (.after(2), "After 2 seconds"),
        (.after(3), "After 3 seconds"), (.after(5), "After 5 seconds"), (.never, "Never"),
    ]
}

/// The option closest to a stored value. A tie goes to the longer one: a bar
/// that stays a beat too long beats one that vanishes under the pointer.
private func nearest(_ value: TimeInterval, in options: [TimeInterval]) -> TimeInterval {
    options.sorted(by: >).min { abs($0 - value) < abs($1 - value) } ?? value
}

// MARK: - Icon spacing

/// One slider for macOS's own gap between menu bar icons. The draft lives
/// here; the store holds what was applied, so the Apply chip lights only
/// when they differ (the same grammar as the editor's Apply). Applying
/// relaunches Pelmet and restarts the system icons, so it never fires on
/// a slider notch.
private struct IconSpacingRow: View {
    @Environment(AppState.self) private var appState
    /// The slider runs on the stop index: the stops are not evenly spaced
    /// (1, then fours), and SwiftUI's Slider only steps evenly.
    @State private var draft: Double = Double(IconSpacing.index(of: IconSpacing.macOSDefault))
    @State private var staleApps: [String] = []

    private var spacing: Int { IconSpacing.steps[min(max(Int(draft.rounded()), 0), IconSpacing.steps.count - 1)] }
    private var applied: Int { IconSpacingApplier.current() }
    private var pending: Bool { spacing != applied }
    private var atDefault: Bool { spacing == IconSpacing.macOSDefault }

    private var label: LocalizedStringKey {
        switch spacing {
        case ...1: "Tightest"
        case 4: "Tighter"
        case 8: "Tight"
        case 12: "Snug"
        case 16: "Default"
        case 20: "Roomy"
        case 24: "Wide"
        default: "Widest"
        }
    }

    var body: some View {
        // The reading sits under the title, not beside the slider: a word
        // plus a number in nine languages never fits a fixed lane next to
        // the knob (it slid under it twice, 2026-09-22).
        SettingRow(title: "Space between icons", caption: "\(Text(label)) · \(spacing) pt") {
            Slider(value: $draft, in: 0...Double(IconSpacing.steps.count - 1), step: 1)
            .frame(width: 200)
        }
        if !staleApps.isEmpty {
            SettingNote("Still on the old spacing until relaunched: \(ListFormatter.localizedString(byJoining: staleApps))")
        }
        HStack(spacing: 10) {
            SettingNote("macOS's own spacing, so it stays after Dimble. Other apps catch up when they next open.")
            Spacer(minLength: 0)
            if !atDefault || applied != IconSpacing.macOSDefault {
                // The shortcut recorder's ↺: tertiary, only while there is
                // something to undo.
                Button {
                    draft = Double(IconSpacing.index(of: IconSpacing.macOSDefault))
                } label: {
                    Image(systemName: "arrow.counterclockwise.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .disabled(atDefault)
                .help("Reset to default")
            }
            TintChipButton(
                text: Text("Apply"),
                icon: Image(systemName: "wand.and.stars"),
                tint: pending ? .green : .secondary
            ) {
                IconSpacingApplier.apply(spacing, appState: appState)
            }
            .disabled(!pending)
            .animation(.easeOut(duration: 0.2), value: pending)
            .help("Relaunches Dimble and the system icons with the new spacing")
        }
        .onAppear {
            draft = Double(IconSpacing.index(of: applied))
            staleApps = IconSpacingApplier.staleAppNames()
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didLaunchApplicationNotification)) { _ in
            staleApps = IconSpacingApplier.staleAppNames()
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didTerminateApplicationNotification)) { _ in
            staleApps = IconSpacingApplier.staleAppNames()
        }
    }
}

// MARK: - Displays

private struct DisplaysPane: View {
    var body: some View {
        SettingsCard {
            Text("Every screen has its own menu bar, so each can hide or show.")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(NSScreen.screens, id: \.self) { screen in
                DisplayRow(screen: screen)
            }
        }
    }
}

private struct DisplayRow: View {
    @Environment(AppState.self) private var appState
    let screen: NSScreen

    private var uuid: String? { screen.displayUUIDString }

    private var hasNotch: Bool {
        screen.safeAreaInsets.top > 0
    }

    private var behavior: DisplayBehavior { appState.settings.behavior(forDisplayUUID: uuid) }

    /// The display's own "Show hidden icons in"; nil follows the Panel tab.
    private var revealIn: Binding<RevealTarget?> {
        Binding(
            get: { uuid.flatMap { appState.settings.displayRevealTargets[$0] } },
            set: { target in
                guard let uuid else { return }
                appState.panelPresenter.setTarget(target, forDisplayUUID: uuid)
            })
    }

    var body: some View {
        SettingRow(
            verbatim: screen.localizedName,
            caption: behavior == .alwaysShowAll ? "Shows every icon, hidden ones too." : nil
        ) {
            HStack(spacing: 8) {
                if hasNotch {
                    Text("Notch")
                        .font(.caption2)
                        .fixedSize()
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                }
                PelmetMenuPicker(selection: Binding(
                    get: { behavior },
                    set: { behavior in
                        if let uuid {
                            appState.settings.displayOverrides[uuid] = behavior
                            appState.settingsChanged()
                            appState.displayBehaviorEdited()
                        }
                    }
                ), options: [
                    (DisplayBehavior.collapse, LocalizedStringKey("Hides icons")),
                    (DisplayBehavior.alwaysShowAll, LocalizedStringKey("Shows all icons")),
                ])
            }
        }
        .detail {
            // The display's own "Show hidden icons in" (#88). One that shows
            // all icons keeps it: its chevron click opens Always Hidden (#96).
            if uuid != nil {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("Show hidden icons in")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    PelmetMenuPicker(selection: revealIn, options: [
                        (nil, "Same as Panel tab"), (.menuBar, "Menu bar"), (.panel, "Panel"), (.row, "Row"),
                    ], borderless: true, accent: true)
                    .fixedSize()
                }
            }
        }
    }
}

// MARK: - Thanks

/// The ask, made once and quietly. One solid CTA (sponsor); stars, follows
/// and sharing are tinted chips. Every link is a public URL — nothing here
/// needs a key, and the star count comes from the unauthenticated API.
private struct ThanksPane: View {
    @State private var stars = GitHubStars.cached

    private static let sponsor = URL(string: "https://github.com/sponsors/fif7y")!
    private static let repo = URL(string: "https://github.com/fif7y/dimble")!
    private static let x = URL(string: "https://x.com/FIF7Y")!
    private static let instagram = URL(string: "https://www.instagram.com/madebyfif7y/")!
    private static let website = URL(string: "https://dimble.fif7y.com")!

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Dimble is free. It stays that way.")
                .font(.title3.weight(.semibold))
            Text("One person builds it on evenings and weekends. No account, no tracking, no upsell.\nIf it earned a spot in your bar, here's how to help.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        VStack(alignment: .leading, spacing: 8) {
            AccentChipButton(text: "Sponsor on GitHub", symbol: "heart.fill") { open(Self.sponsor) }
            Text("From a coffee a month. Keeps the releases coming.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        SettingsCard {
            Text("A star helps more people find Dimble.")
            HStack(spacing: 10) {
                TintChipButton(text: "Star on GitHub", symbol: "star.fill", tint: PelmetAccent.star) { open(Self.repo) }
                if let stars {
                    Text("\(stars) stars")
                        .font(.callout)
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                }
            }
        }

        SettingsCard {
            Text("Follow along for releases and what's next.")
            HStack(spacing: 10) {
                TintChipButton(verbatim: "@FIF7Y", icon: XGlyph()) { open(Self.x) }
                TintChipButton(verbatim: "@madebyfif7y", icon: InstagramGlyph()) { open(Self.instagram) }
                ShareLink(item: Self.website) {
                    ChipLabel(text: Text("Tell a friend"), icon: Image(systemName: "square.and.arrow.up"))
                }
                .buttonStyle(.plain)
            }
        }

        Text("Enjoy the extra room up there.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.top, 12)
            .task {
                if let count = await GitHubStars.fetch() { stars = count }
            }
    }

    private func open(_ url: URL) { NSWorkspace.shared.open(url) }
}

/// Star count from the public repos endpoint: no token, one fetch per pane
/// visit, last value cached so the number is there on the next open.
enum GitHubStars {
    private static let key = "thanks.githubStars"

    static var cached: Int? { UserDefaults.standard.object(forKey: key) as? Int }

    static func fetch() async -> Int? {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/fif7y/dimble")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let count = json["stargazers_count"] as? Int
        else { return nil }
        UserDefaults.standard.set(count, forKey: key)
        return count
    }
}

/// The X mark: one heavy diagonal, one light one across it.
struct XGlyph: View {
    var body: some View {
        Canvas { context, size in
            let w = size.width, h = size.height
            var light = Path()
            light.move(to: CGPoint(x: w * 0.92, y: h * 0.08))
            light.addLine(to: CGPoint(x: w * 0.08, y: h * 0.92))
            context.stroke(light, with: .foreground, style: StrokeStyle(lineWidth: w * 0.11, lineCap: .round))
            var heavy = Path()
            heavy.move(to: CGPoint(x: w * 0.08, y: h * 0.08))
            heavy.addLine(to: CGPoint(x: w * 0.92, y: h * 0.92))
            context.stroke(heavy, with: .foreground, style: StrokeStyle(lineWidth: w * 0.2, lineCap: .round))
        }
    }
}

/// The Instagram camera: rounded frame, lens, flash dot.
struct InstagramGlyph: View {
    var body: some View {
        Canvas { context, size in
            let w = size.width, h = size.height
            let stroke = w * 0.11
            let frame = CGRect(x: w * 0.08, y: h * 0.08, width: w * 0.84, height: h * 0.84)
            context.stroke(Path(roundedRect: frame, cornerRadius: w * 0.26), with: .foreground, lineWidth: stroke)
            let lens = CGRect(x: w * 0.3, y: h * 0.3, width: w * 0.4, height: h * 0.4)
            context.stroke(Path(ellipseIn: lens), with: .foreground, lineWidth: stroke)
            let dot = CGRect(x: w * 0.66, y: h * 0.2, width: w * 0.14, height: h * 0.14)
            context.fill(Path(ellipseIn: dot), with: .foreground)
        }
    }
}

// MARK: - About

private struct AboutPane: View {
    @Environment(AppState.self) private var appState
    @State private var notesShown = false
    /// The banner asked for this version's notes: the link shows them until
    /// the popover closes, even with an update waiting.
    @State private var showsInstalledNotes = false

    private var version: String {
        let info = Bundle.main
        let short = info.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = info.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return String(localized: "Version \(short) (\(build))")
    }

    private var copyright: String {
        Bundle.main.object(forInfoDictionaryKey: "NSHumanReadableCopyright") as? String
            ?? "© 2026 Gabriel Faucon"
    }

    var body: some View {
        VStack(spacing: 6) {
            AnimatedAppIcon(size: 96)
                .shadow(color: .black.opacity(0.2), radius: 8, y: 4)
            Text("Dimble")
                .font(.system(size: 30, weight: .semibold))
            Text(version)
                .font(.callout)
                .foregroundStyle(.secondary)
            // The rename stays quiet: a caption under the version, not a banner.
            Text("formerly Pelmet")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(copyright)
                .font(.caption)
                .foregroundStyle(.tertiary)

            VStack(spacing: 10) {
                if SparkleController.shared.isConfigured {
                    updateRow
                }
                notesLink
                Button("Replay the intro") {
                    OnboardingController.shared.present(appState: appState)
                }
            }
            .padding(.top, 18)

            HStack(spacing: 18) {
                Link("Website", destination: URL(string: "https://dimble.fif7y.com")!)
                Link("GitHub", destination: URL(string: "https://github.com/fif7y/dimble")!)
                Link("Report an issue", destination: URL(string: "https://github.com/fif7y/dimble/issues")!)
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.top, 22)

            if SparkleController.shared.isConfigured {
                updatesCard
                    .padding(.top, 28)
            }
        }
        .frame(maxWidth: .infinity)
        // 60 scrolled the pane by a row once the beta toggle joined the
        // Updates card (Gab, 2026-09-21): the default window shows it whole.
        .padding(.top, 20)
        .onAppear {
            SparkleController.shared.probe()
            takeNotesRequest()
        }
        .onChange(of: SparkleController.shared.notesRequested) { takeNotesRequest() }
        .onChange(of: notesShown) { _, shown in
            if !shown { showsInstalledNotes = false }
        }
    }

    /// The "is installed" banner asks for its version's notes to open with
    /// the pane. Only this build's are bundled: a banner left from an older
    /// one opens the pane alone.
    private func takeNotesRequest() {
        guard let requested = SparkleController.shared.notesRequested else { return }
        SparkleController.shared.notesRequested = nil
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        guard requested == short, SparkleController.installedNotes != nil else {
            PelmetLog.log("settings: notes for \(requested) asked for, this is \(short), none shown")
            return
        }
        showsInstalledNotes = true
        notesShown = true
    }

    /// "What's new" under the update chip: the waiting update's notes
    /// before the click that installs it, otherwise this version's own
    /// (and always while the "is installed" banner's request is up).
    /// A quiet link, the notes live in a popover (one recipe with
    /// Sparkle's update window: same HTML, same stylesheet).
    @ViewBuilder private var notesLink: some View {
        let sparkle = SparkleController.shared
        if !showsInstalledNotes, let version = sparkle.availableVersion {
            if let html = sparkle.pendingNotes {
                notesButton("What's new", title: String(localized: "What's new in \(version)"), html: html)
            }
        } else if let html = SparkleController.installedNotes {
            let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
            notesButton("What's new in this version", title: String(localized: "What's new in \(short)"), html: html)
        }
    }

    private func notesButton(_ label: LocalizedStringKey, title: String, html: String) -> some View {
        Button(label) { notesShown.toggle() }
            .buttonStyle(.plain)
            .font(.callout.weight(.medium))
            .foregroundStyle(PelmetAccent.accent)
            .pointerStyle(.link)
            .popover(isPresented: $notesShown, arrowEdge: .bottom) {
                ReleaseNotesView(title: title, html: html)
            }
    }

    /// Two preferences, both quiet by design: scheduled checks never open a
    /// window (see SparkleController); these decide what a found update
    /// does instead.
    @ViewBuilder private var updatesCard: some View {
        @Bindable var appState = appState
        SettingsCard(title: "Updates") {
            SettingToggleRow(
                title: "Download updates automatically",
                caption: "Installs on the next quit.",
                isOn: Binding(
                    get: { SparkleController.shared.automaticallyDownloadsUpdates },
                    set: { SparkleController.shared.automaticallyDownloadsUpdates = $0 }
                )
            )
            SettingToggleRow(
                title: "Notify me when an update is available",
                isOn: Binding(
                    get: { appState.settings.notifyOnUpdates },
                    set: { appState.settings.notifyOnUpdates = $0; appState.settingsChanged() }
                )
            )
            SettingToggleRow(
                title: "Get beta releases",
                caption: "Smaller updates, more often. Stable releases roll them up every week or two.",
                isOn: Binding(
                    get: { appState.settings.betaUpdates },
                    set: {
                        appState.settings.betaUpdates = $0
                        appState.settingsChanged()
                        SparkleController.shared.recheck()
                    }
                )
            )
            if let checked = SparkleController.shared.lastUpdateCheckDate {
                Text("Last checked \(checked, format: .relative(presentation: .named))")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    /// Inline update state — no "you're up to date" alert; the pane just
    /// shows it. One capsule chip per state (de-box: tinted fill, no
    /// borders); only "update available" is a true CTA and gets the solid
    /// accent fill.
    @ViewBuilder private var updateRow: some View {
        switch SparkleController.shared.status {
        case .available(let version):
            AccentChipButton(text: "Update to \(version)", symbol: "arrow.down.circle.fill") {
                SparkleController.shared.checkForUpdates()
            }
        case .checking:
            HStack(spacing: 7) {
                ProgressView()
                    .controlSize(.small)
                Text("Checking for updates…")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
        case .upToDate:
            StatusChip(text: "You're on the latest version", symbol: "checkmark.seal.fill", tint: .green)
        case .unknown:
            TintChipButton(text: "Check for updates", symbol: "arrow.triangle.2.circlepath") {
                SparkleController.shared.probe()
            }
        }
    }
}

// MARK: - Chips

/// De-boxed state chip: tinted fill, no border. Shared by About's update
/// state and General's permission row so the two read as one family.
struct StatusChip: View {
    let text: LocalizedStringKey
    let symbol: String
    let tint: Color

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.callout.weight(.medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(tint.opacity(0.13), in: Capsule())
    }
}

/// The one true CTA treatment: solid brand accent, white label.
struct AccentChipButton: View {
    let text: LocalizedStringKey
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(text, systemImage: symbol)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(PelmetAccent.accent, in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// The tinted sibling of AccentChipButton: accent text on a soft accent fill.
/// One recipe (ChipLabel) so About's update chip and the Thanks chips cannot
/// drift apart.
struct TintChipButton<Icon: View>: View {
    let text: Text
    let icon: Icon
    var tint: Color = PelmetAccent.accent
    let action: () -> Void

    init(text: LocalizedStringKey, symbol: String, tint: Color = PelmetAccent.accent, action: @escaping () -> Void) where Icon == Image {
        self.text = Text(text)
        self.icon = Image(systemName: symbol)
        self.tint = tint
        self.action = action
    }

    /// A prebuilt label (the Apply button switches its text and tint).
    init(text: Text, icon: Icon, tint: Color = PelmetAccent.accent, action: @escaping () -> Void) {
        self.text = text
        self.icon = icon
        self.tint = tint
        self.action = action
    }

    /// Handles and other runtime strings, shown as-is with a custom glyph.
    init(verbatim text: String, icon: Icon, action: @escaping () -> Void) {
        self.text = Text(verbatim: text)
        self.icon = icon
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            ChipLabel(text: text, icon: icon, tint: tint)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
    }
}

struct ChipLabel<Icon: View>: View {
    let text: Text
    let icon: Icon
    var tint: Color = PelmetAccent.accent

    var body: some View {
        HStack(spacing: 6) {
            icon
                .frame(width: 13, height: 13)
            text
        }
        .font(.callout.weight(.medium))
        .foregroundStyle(tint)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(tint.opacity(0.13), in: Capsule())
        .contentShape(Capsule())
    }
}

// MARK: - Animation showcase

/// Three picture cards in Panel's recipe, one per style: a sketch of the bar
/// with the name under it, the pick on the accent ring and fill. A card plays
/// its own reveal once while the pointer is on it, never with Reduce Motion.
struct AnimationShowcase: View {
    @Binding var selection: RevealAnimation

    private static let styles: [(RevealAnimation, LocalizedStringKey)] = [
        (.instant, "Instant"), (.smooth, "Smooth"), (.fade, "Fade"),
    ]

    var body: some View {
        HStack(spacing: 10) {
            ForEach(Self.styles, id: \.0) { style, title in
                AnimationStyleCard(style: style, title: title, selected: selection == style) {
                    selection = style
                }
            }
        }
        .animation(.spring(duration: 0.22), value: selection)
    }
}

private struct AnimationStyleCard: View {
    let style: RevealAnimation
    let title: LocalizedStringKey
    let selected: Bool
    let select: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false
    /// The sketch rests revealed. A hover takes it back to the concealed bar
    /// and plays the style's reveal.
    @State private var revealed = true
    @State private var playing: Task<Void, Never>?

    var body: some View {
        Button(action: select) {
            VStack(spacing: 7) {
                MockBar(style: style, revealed: revealed, ink: selected ? PelmetAccent.accent : .secondary)
                Text(title)
                    .font(.system(size: 12, weight: selected ? .semibold : .medium))
                    .foregroundStyle(selected ? PelmetAccent.accent : .primary)
            }
            .padding(6)
            .padding(.bottom, 2)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(selected ? PelmetAccent.accent.opacity(0.14) : Color.primary.opacity(hovered ? 0.08 : 0.04))
                    .shadow(color: .black.opacity(selected ? 0.2 : 0), radius: 4, y: 1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(PelmetAccent.accent, lineWidth: 1.5)
                    .opacity(selected ? 1 : 0)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onHover { inside in
            hovered = inside
            if inside { play() }
        }
        .onDisappear { playing?.cancel() }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func play() {
        playing?.cancel()
        guard !reduceMotion else { return }
        playing = Task {
            // Back to the concealed bar without a trace, a beat to read it,
            // then this style's own reveal.
            withAnimation(nil) { revealed = false }
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            withAnimation(MockBar.animation(style, revealed: true)) { revealed = true }
        }
    }
}

/// A menu bar in miniature, sketched like the Panel cards': a strip with three
/// hidden icons left of the chevron and three shown ones right of it. The
/// hidden group moves the way the real style does, with the same durations
/// (AppTiming). The caller animates `revealed`, so a snap stays a snap.
struct MockBar: View {
    let style: RevealAnimation
    let revealed: Bool
    let ink: Color

    private static let icon: CGFloat = 8
    private static let gap: CGFloat = 4
    private static let edge: CGFloat = 8
    private static let hiddenWidth = 3 * icon + 2 * gap

    private func icons(_ color: Color) -> some View {
        HStack(spacing: Self.gap) {
            ForEach(0..<3, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 2).fill(color).frame(width: Self.icon, height: Self.icon)
            }
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            // Hidden group, clipped at the chevron so a slide emerges from
            // behind it exactly like the real strip.
            icons(ink)
                .offset(x: hiddenOffset)
                .opacity(revealed ? 1 : 0)
                .frame(width: Self.hiddenWidth, alignment: .trailing)
                .clipped()
            Image(systemName: revealed ? "chevron.right" : "chevron.left")
                .font(.system(size: 7, weight: .heavy))
                .foregroundStyle(ink)
                .contentTransition(.symbolEffect(.replace))
            icons(Color.primary.opacity(0.35))
        }
        .padding(.horizontal, Self.edge)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .frame(height: 22)
        .background(Color.primary.opacity(0.08))
        .frame(maxWidth: .infinity, alignment: .top)
        .frame(height: 40, alignment: .top)
        .background(Color.primary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var hiddenOffset: CGFloat {
        guard case .smooth = style, !revealed else { return 0 }
        return Self.hiddenWidth  // parked behind the chevron
    }

    /// The style's motion, revealing or concealing, at the real durations.
    static func animation(_ style: RevealAnimation, revealed: Bool) -> Animation? {
        switch style {
        case .instant:
            nil
        case .smooth:
            revealed
                ? .timingCurve(0.16, 1, 0.3, 1, duration: AppTiming.smoothRevealDuration)
                : .timingCurve(0.55, 0, 0.8, 0.4, duration: AppTiming.smoothExitDuration)
        case .fade:
            .timingCurve(0.42, 0, 0.58, 1, duration: revealed ? AppTiming.fadeRevealDuration : AppTiming.fadeExitDuration)
        }
    }
}

/// A shortcut row’s caption: the plain one, or why the shortcut will
/// not fire. macOS's own shortcuts register fine and never run (#55).
func hotkeyCaption(_ spec: HotkeySpec?, conflict: Bool, otherwise: LocalizedStringKey) -> LocalizedStringKey {
    hotkeyWarning(spec, conflict: conflict) ?? otherwise
}

/// Why a shortcut will not fire, or nil when nothing is in its way. The
/// General › Shortcuts rows carry no caption except this one.
func hotkeyWarning(_ spec: HotkeySpec?, conflict: Bool) -> LocalizedStringKey? {
    if conflict { return "Held by another app — record a different one." }
    if let spec, SystemShortcuts.owns(spec) {
        return "macOS uses this shortcut. Turn it off in System Settings › Keyboard › Keyboard Shortcuts, or record another."
    }
    return nil
}
