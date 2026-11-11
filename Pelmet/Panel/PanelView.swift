// PanelView.swift
// The panel's tiles (docs/PANEL-PLAN.md §2): what `PanelModel` says, laid out
// by `PanelGrid`, dressed as the design mock (pelmet-site
// marketing/panel-mock). Sections stack top down; a tile is a soft well with
// the icon as the bar draws it. Everything it shows is handed in, so the
// presenter owns the state and the Settings preview can draw the same view.

import AppKit
import Observation
import PelmetCore
import SwiftUI

/// What one tile draws.
struct PanelTileArt {
    enum Image {
        /// Cut from the bar (ItemPictures); one-colour glyphs are tinted.
        case picture(CGImage, size: CGSize, monochrome: Bool, highlighted: Bool)
        /// The stand-in until a picture lands: the app's icon or a symbol.
        case icon(NSImage)
    }

    let image: Image
    let name: String
    /// A launcher: the app isn't running, a click opens it.
    var dimmed = false
}

/// One stacked block of the panel.
struct PanelBlock: Identifiable {
    let kind: PanelSection.Kind
    let grid: PanelGrid
    /// Icons you can click, for the header and the fold.
    let count: Int
    let showsHeader: Bool
    /// Always Hidden only: its fold is drawn, and the grid when open.
    let foldable: Bool
    let isFolded: Bool
    /// The row layout merges the sections into one grid: which tiles belong to
    /// which, for a drop's target. Empty in the panel layout.
    var groups: [PanelGroup] = []

    var id: PanelSection.Kind { kind }
}

/// The tiles one section brought into the row.
struct PanelGroup {
    let kind: PanelSection.Kind
    let tiles: [PanelTile]
}

/// A part of the panel the drag needs to find on screen (laid out by SwiftUI,
/// reported in the hosting view's space, `PanelHost.space`).
enum PanelFrameKey: Hashable {
    /// A section, header included (Didn't fit and Hidden).
    case section(PanelSection.Kind)
    /// A section's tiles.
    case grid(PanelSection.Kind)
    /// The Always Hidden fold as a count chip or a handle (the tile is a cell
    /// of a grid, placed by an offset a frame does not see).
    case fold
}

/// A tile drag, from the tile's own gesture: where the pointer is in the
/// tile, and where the well's centre is. The presenter reads the screen.
enum PanelTileDrag {
    case moved(pointer: CGPoint, wellCenter: CGPoint)
    case ended
}

/// What the drag shows: the tile in the air, and the section it would land
/// in. Its own object, so a target change redraws the highlight and nothing
/// else (a refresh rebuilds the whole panel).
@Observable
final class PanelDragState {
    var tile: PanelTile?
    /// The drop as it would go: `.none` for no target and for the tile's own
    /// section. The bar is Visible, and draws nothing in the panel.
    var target: PanelDropZones.Hit = .none
}

struct PanelContent {
    var blocks: [PanelBlock] = []
    var layout: PanelGrid.Layout = .panel
    var art: [PanelTile: PanelTileArt] = [:]
    /// The widest grid: headers, the search field and the fold span it.
    var width: CGFloat = 44
    /// What the keyboard typed: the search row shows while it isn't empty.
    var query = ""
    /// The tile Return opens and the arrows move.
    var selected: PanelTile?
    /// While the left edge is dragged: "4 per row", "Auto".
    var columnsTip: String?
    /// Always Hidden has icons this panel can show, drawn or not: the row
    /// draws no fold, its right-click menu opens it.
    var hasAlwaysHidden = false
    /// Always Hidden's tiles are on screen: unfolded in the panel, part of
    /// the row.
    var showsAlwaysHidden = false
    /// The Animation setting, which Always Hidden's fold follows (Reduce
    /// Motion turns Smooth into Fade).
    var motion: RevealAnimation = .instant
    /// What opens Always Hidden. The tile is a cell of the grid above it
    /// (`PanelTile.fold`); the count and the handle are the section's own.
    var fold: PanelOptions.AlwaysHiddenFold = .tile
    /// Taller than its display: the tiles scroll in this height, under the
    /// search row, which stays.
    var scrollHeight: CGFloat?
    /// A new one starts the scroll at the top: the presenter's count of opens.
    var scrollID = 0
    /// The tiles whose right-click menu offers "Move to…": the ones a drag
    /// picks up.
    var draggable: Set<PanelTile> = []
    /// A tile drag makes room as it goes (and a moment after it ends): tiles
    /// that change place ease there instead of jumping.
    var animatesTiles = false
    /// Nothing is hidden, or nothing matches: the panel says so instead of
    /// showing nothing.
    var isEmpty: Bool { blocks.allSatisfy { $0.count == 0 } }
}

/// A right-click menu row, built by the presenter.
enum PanelMenuRow {
    case action(String, () -> Void)
    case check(String, Bool, enabled: Bool = true, () -> Void)
    case header(String)
    case divider
}

struct PanelView: View {
    let content: PanelContent
    let onPress: (PanelTile) -> Void
    let onFold: () -> Void
    var tileMenu: (PanelTile) -> [PanelMenuRow] = { _ in [] }
    var panelMenu: () -> [PanelMenuRow] = { [] }
    /// The left edge sets the columns: dragged (the pointer's x in the
    /// window, true when let go), and double-clicked for Auto.
    var onColumnsDrag: (_ x: CGFloat, _ ended: Bool) -> Void = { _, _ in }
    var onColumnsReset: () -> Void = {}
    /// The column grip, half past the left edge. The open panel draws its
    /// own outside the glass, which clips this view (`PanelEdgeGrip`).
    var drawsGrip = true
    /// A tile dragged out: nil where nothing can be (the Settings preview).
    var onTileDrag: ((PanelTile, PanelTileDrag) -> Void)?
    var drag = PanelDragState()
    /// Where the sections, grids and fold land, for the drag to find.
    var onFrame: (PanelFrameKey, CGRect) -> Void = { _, _ in }

    @State private var hovering = false

    @Environment(\.colorScheme) private var scheme

    private var padding: CGFloat {
        PanelMetrics.standard(layout: content.layout, showsNames: false).padding
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 0) {
            if !content.query.isEmpty {
                searchRow
                    .padding([.top, .horizontal], padding)
            }
            // The padding scrolls with the tiles: they run to the glass's
            // edge, not to a line inside it.
            scrolling(tiles.padding(content.query.isEmpty ? .all : [.horizontal, .bottom], padding))
        }
        .fixedSize()
        .overlay(alignment: .leading) {
            if content.layout == .panel, !content.isEmpty {
                ZStack(alignment: .leading) {
                    if drawsGrip {
                        ColumnGrip(ink: ink, panelHovered: hovering, onDrag: onColumnsDrag, onReset: onColumnsReset)
                            .offset(x: -ColumnGrip.reach / 2)
                    }
                    if let tip = content.columnsTip {
                        ColumnTip(text: tip, ink: ink)
                            .padding(.leading, 16)
                    }
                }
            }
        }
        .contentShape(Rectangle())
        // Only the grip drawn here reads it: on the open panel (whose grip
        // is the window's own) a hover redrew every tile for nothing.
        .onHover { if drawsGrip { hovering = $0 } }
        .contextMenu { PanelMenuItems(rows: panelMenu) }
    }

    @ViewBuilder
    private var tiles: some View {
        if content.isEmpty {
            if content.query.isEmpty { empty } else { noMatch }
        } else if content.layout == .row {
            HStack(spacing: 0) {
                ForEach(content.blocks) { block in
                    grid(block)
                }
            }
        } else {
            VStack(alignment: .trailing, spacing: 0) {
                ForEach(Array(content.blocks.enumerated()), id: \.element.id) { index, block in
                    section(block, first: index == 0)
                }
            }
        }
    }

    /// The tiles scroll when the panel is capped; the arrow keys bring the
    /// selected tile into view, as a list does, with no animation. Always in
    /// the scroll view, so a fold that crosses the cap keeps its tiles and
    /// their motion. No scroll bar: a legacy one would cover the column by
    /// the chevron, and the row cut at the glass's edge says there is more.
    private func scrolling(_ tiles: some View) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) { tiles }
                .frame(height: content.scrollHeight)
                .scrollDisabled(content.scrollHeight == nil)
                // It takes its new height at once: clipped there, a fold's
                // tiles vanished in a frame instead of leaving with their
                // motion. Uncapped, the glass's edge is the clip.
                .scrollClipDisabled(content.scrollHeight == nil)
                .scrollIndicators(.never)
                .id(content.scrollID)
                .onChange(of: content.selected, initial: true) { _, selected in
                    if selected != nil, content.scrollHeight != nil { proxy.scrollTo(Self.selectionMark) }
                }
        }
    }

    /// Where the selected tile is, with the panel's padding above and below
    /// so it never lands flush with the glass's edge.
    private static let selectionMark = "panel.selection"

    @ViewBuilder
    private func section(_ block: PanelBlock, first: Bool) -> some View {
        if block.foldable {
            // A search shows the matches, no fold.
            let fold: PanelOptions.AlwaysHiddenFold? = content.query.isEmpty ? content.fold : nil
            let hasOtherIcons = content.blocks.contains { other in
                other.kind != .alwaysHidden && !other.isFolded && other.grid.rows.joined().contains {
                    $0.tile != .fold && $0.tile != .rowBreak
                }
            }
            VStack(alignment: .trailing, spacing: 0) {
                // Both stay where they are: the tiles come out under them.
                if fold == .count {
                    countFold(block)
                        .padding(.top, first ? 0 : 6)
                }
                if fold == .handle {
                    handleFold(block)
                }
                foldedTiles(block, gap: fold == .count ? 6 : first && fold == nil ? 0 : 10)
                    // 利用原有组间留白画线，避免展开后改变面板尺寸和拖拽坐标。
                    .overlay(alignment: .top) {
                        if hasOtherIcons, !block.isFolded {
                            Rectangle().fill(ink.tertiary)
                                .frame(height: 1)
                                .offset(y: 2)
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                        }
                    }
                    // The open grid lit as a drop target. Outside the fold's
                    // mask, which cuts at the grid's width.
                    .background(alignment: .bottomTrailing) {
                        if !block.isFolded, drag.target.section == .alwaysHidden {
                            dropWell
                                .frame(width: block.grid.contentSize.width + 2 * Self.dropReach,
                                       height: block.grid.contentSize.height + 2 * Self.dropReach)
                                .offset(x: Self.dropReach, y: Self.dropReach)
                        }
                    }
            }
            // The bar's own motion for the style: Smooth slides the tiles
            // out from under the icons above, Fade fades them in place.
            .animation(MockBar.animation(content.motion, revealed: !block.isFolded), value: block.isFolded)
        } else {
            VStack(alignment: .trailing, spacing: 0) {
                if block.showsHeader {
                    header(block)
                }
                grid(block)
            }
            .background {
                if drag.target.section == .hidden, block.kind == .hidden {
                    dropWell.padding(-Self.dropReach)
                }
            }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(PanelHost.space)) } action: {
                onFrame(.section(block.kind), $0)
            }
            // The mock's gap under Didn't fit; Hidden runs into the fold,
            // which brings its own.
            .padding(.bottom, block.kind == .didntFit ? 10 : 0)
        }
    }

    @ViewBuilder
    private func foldedTiles(_ block: PanelBlock, gap: CGFloat) -> some View {
        VStack(spacing: 0) {
            if !block.isFolded {
                grid(block)
                    .padding(.top, gap)
                    // Smooth slides them out from under the icons above, and
                    // closes like a drawer: they fade in place while the
                    // glass's edge comes up over them. Slid back up, they
                    // passed behind the icons above (Gab, 2026-10-09).
                    .transition(content.motion == .smooth
                        ? .asymmetric(insertion: .move(edge: .top), removal: .opacity) : .opacity)
            }
        }
        // As wide folded as open: the slide's clip grows down only, never in
        // from the trailing edge.
        .frame(width: content.width, alignment: .trailing)
        // Cut at the top edge alone, where the slide comes out; below, the
        // glass's own edge is the only one.
        .mask(alignment: .top) { Rectangle().frame(height: 10_000) }
    }

    private func header(_ block: PanelBlock) -> some View {
        HStack(spacing: 6) {
            Text(title(of: block.kind))
                .foregroundStyle(ink.secondary)
            if block.kind == .didntFit {
                Text(block.count, format: .number)
                    .foregroundStyle(ink.tertiary)
                    .fontWeight(.regular)
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 12, weight: .medium))
        .padding(.horizontal, 4)
        .padding(.bottom, 6)
        // At least the grid's width; a long name in a narrow panel widens it.
        .frame(minWidth: content.width)
        .help(block.kind == .didntFit ? String(localized: "macOS had no room for these in the menu bar") : "")
    }

    /// The count fold: how many are behind it, a chevron that turns.
    private func countFold(_ block: PanelBlock) -> some View {
        Button(action: onFold) {
            HStack(spacing: 3) {
                Text(block.count, format: .number)
                    .monospacedDigit()
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .rotationEffect(.degrees(block.isFolded ? 0 : 180))
                    // Turns in every style, a disclosure's own cue.
                    .animation(.easeOut(duration: 0.2), value: block.isFolded)
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(ink.secondary)
            .padding(.horizontal, 8)
            .frame(height: 20)
            .contentShape(Capsule())
        }
        .buttonStyle(FoldFillStyle(ink: ink, shape: Capsule(), resting: drag.target == .fold ? ink.wellHover : ink.well))
        .focusEffectDisabled()
        .help(title(of: .alwaysHidden))
        .accessibilityLabel(title(of: .alwaysHidden))
        .accessibilityValue(Text(block.count, format: .number))
        .frame(width: content.width)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(PanelHost.space)) } action: { onFrame(.fold, $0) }
    }

    /// The handle fold: a grabber on the bottom edge while folded. It stays
    /// put when the tiles come out under it; at the bottom it moved, and the
    /// pointer that opened it was left on a tile (Gab, 2026-10-09).
    private func handleFold(_ block: PanelBlock) -> some View {
        Button(action: onFold) {
            HandleGrip(ink: ink, width: content.width, lit: drag.target == .fold)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .help(title(of: .alwaysHidden))
        .accessibilityLabel(title(of: .alwaysHidden))
        .accessibilityValue(Text(block.count, format: .number))
        .padding(.top, 4)
        // Half into the panel's padding while folded: a grabber sits on the
        // edge.
        .padding(.bottom, -5)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(PanelHost.space)) } action: { onFrame(.fold, $0) }
    }

    /// The tile fold: how many are behind it, a chevron once they are out.
    private func foldTile(at placement: PanelGrid.Placement, in grid: PanelGrid) -> some View {
        let always = content.blocks.first { $0.kind == .alwaysHidden }
        let count = always?.count ?? 0
        return Button(action: onFold) {
            FoldTileLabel(count: count, open: always.map { !$0.isFolded } ?? false,
                          title: title(of: .alwaysHidden), grid: grid, ink: ink)
        }
        .buttonStyle(PanelTileStyle(grid: grid, ink: ink, selected: content.selected == .fold || drag.target == .fold))
        .focusEffectDisabled()
        .help(title(of: .alwaysHidden))
        .accessibilityLabel(title(of: .alwaysHidden))
        .accessibilityValue(Text(count, format: .number))
        .accessibilityAddTraits(content.selected == .fold ? .isSelected : [])
        .offset(x: placement.frame.minX, y: placement.frame.minY)
    }

    /// The mock's search field, drawn: the panel's own key monitor types
    /// into it.
    private var searchRow: some View {
        let row = content.layout == .row
        return HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(ink.tertiary)
            HStack(spacing: 0) {
                Text(content.query)
                    .foregroundStyle(ink.primary)
                    .lineLimit(1)
                    .truncationMode(.head)
                Caret()
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 13))
        .padding(.horizontal, 10)
        .frame(width: content.width, height: row ? 28 : 30)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(ink.well))
        .padding(.bottom, row ? 5 : 10)
    }

    private var noMatch: some View {
        Text("No results")
            .font(.system(size: 12))
            .foregroundStyle(ink.secondary)
            .padding(EdgeInsets(top: 6, leading: 6, bottom: 4, trailing: 6))
            .frame(width: content.width, alignment: .leading)
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Nothing hidden")
                .font(.system(size: 12))
                .foregroundStyle(ink.secondary)
            Text("⌘-drag an icon left of ‹ to hide it.")
                .font(.system(size: 11))
                .foregroundStyle(ink.tertiary)
        }
        .padding(EdgeInsets(top: 6, leading: 6, bottom: 4, trailing: 6))
        .frame(minWidth: 150, alignment: .leading)
    }

    /// How far a lit section reaches past its tiles; the panel's padding is
    /// the room for it.
    private static let dropReach: CGFloat = 5

    /// A section lit as a drop target: the tile hover's fill, soft.
    private var dropWell: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(ink.wellHover)
            .allowsHitTesting(false)
            .transition(.opacity)
    }

    private func grid(_ block: PanelBlock) -> some View {
        let grid = block.grid
        return ZStack(alignment: .topLeading) {
            // The row has no sections to light: the group under the pointer.
            if grid.layout == .row, let lit = drag.target.section {
                ForEach(Array(litRects(of: block, section: lit).enumerated()), id: \.offset) { _, rect in
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(ink.wellHover)
                        .frame(width: rect.width, height: rect.height)
                        .offset(x: rect.minX, y: rect.minY)
                        .allowsHitTesting(false)
                }
            }
            ForEach(Array(grid.rows.joined()), id: \.tile) { placement in
                if placement.tile == .fold {
                    foldTile(at: placement, in: grid)
                } else if let art = content.art[placement.tile] {
                    Button { onPress(placement.tile) } label: {
                        PanelTileLabel(art: art, grid: grid, ink: ink, tileWidth: placement.frame.width)
                    }
                    .buttonStyle(PanelTileStyle(grid: grid, ink: ink, selected: content.selected == placement.tile,
                                                tileWidth: placement.frame.width))
                    // The arrow keys have their own selection; the system's
                    // blue ring is not it.
                    .focusEffectDisabled()
                    .help(art.dimmed ? "\(art.name)\n\(String(localized: "Not running"))" : art.name)
                    .contextMenu { PanelMenuItems(rows: { tileMenu(placement.tile) }) }
                    // A tile that can't be dragged keeps every other gesture
                    // (`.subviews`: `.none` took the button's press too).
                    // A click that never travels 4pt stays the button's.
                    .simultaneousGesture(tileDrag(placement.tile, grid: grid),
                                         including: onTileDrag != nil && content.draggable.contains(placement.tile) ? .all : .subviews)
                    // The tile in the air leaves its place dimmed.
                    .opacity(drag.tile == placement.tile ? 0.35 : 1)
                    .animation(.easeOut(duration: 0.15), value: drag.tile == placement.tile)
                    // Names even with names off; a launcher says it isn't running.
                    .accessibilityLabel(art.name)
                    .accessibilityValue(art.dimmed ? String(localized: "Not running") : "")
                    .accessibilityAddTraits(content.selected == placement.tile ? .isSelected : [])
                    .offset(x: placement.frame.minX, y: placement.frame.minY)
                }
            }
            ForEach(Array(grid.dividers.enumerated()), id: \.offset) { _, divider in
                Capsule()
                    .fill(ink.tertiary)
                    .frame(width: 1, height: divider.height * 0.5)
                    .frame(width: divider.width, height: divider.height)
                    .offset(x: divider.minX, y: divider.minY)
            }
            if content.scrollHeight != nil, let selected = content.selected, let frame = grid.frame(of: selected) {
                // Laid out where the tile is drawn (padding moves it, an
                // offset would not), for the scroll view to find.
                let mark = frame.insetBy(dx: 0, dy: -padding)
                Color.clear
                    .frame(width: mark.width, height: mark.height)
                    .id(Self.selectionMark)
                    .padding(.leading, mark.minX)
                    .padding(.top, mark.minY)
                    .allowsHitTesting(false)
            }
        }
        // Keyed on the order, not the frames: a wider panel or a new column
        // count reflows at once, only a tile that changed place eases.
        .transaction(value: grid.rows.joined().map(\.tile)) { transaction in
            if content.animatesTiles { transaction.animation = Self.makeRoom }
        }
        .frame(width: grid.contentSize.width, height: grid.contentSize.height, alignment: .topLeading)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(PanelHost.space)) } action: { onFrame(.grid(block.kind), $0) }
    }

    /// The tiles making room for the one in the air.
    static let makeRoom = Animation.easeOut(duration: 0.18)

    /// The row's group of `section`, a rounded strip behind its tiles per
    /// line.
    private func litRects(of block: PanelBlock, section: PelmetCore.Section) -> [CGRect] {
        let kind: PanelSection.Kind = section == .alwaysHidden ? .alwaysHidden : .hidden
        guard section != .visible, let group = block.groups.first(where: { $0.kind == kind }) else { return [] }
        let wanted = Set(group.tiles)
        return block.grid.rows.compactMap { line in
            let frames = line.filter { wanted.contains($0.tile) }.map(\.frame)
            guard let first = frames.first else { return nil }
            return frames.dropFirst().reduce(first) { $0.union($1) }.insetBy(dx: -3, dy: -2)
        }
    }

    /// The gesture that picks a tile up. The pointer is read on screen by the
    /// presenter; the tile only says where in itself it was grabbed.
    private func tileDrag(_ tile: PanelTile, grid: PanelGrid) -> some Gesture {
        // The row's tiles differ in width (#102).
        let center = CGPoint(x: grid.tileWidth(of: tile) / 2, y: grid.metrics.wellSize.height / 2)
        return DragGesture(minimumDistance: 4, coordinateSpace: .local)
            .onChanged { onTileDrag?(tile, .moved(pointer: $0.location, wellCenter: center)) }
            .onEnded { _ in onTileDrag?(tile, .ended) }
    }

    private func title(of kind: PanelSection.Kind) -> String {
        switch kind {
        case .didntFit: String(localized: "Didn’t fit")
        case .hidden: String(localized: "Hidden")
        case .alwaysHidden: String(localized: "Always Hidden")
        }
    }

    private var ink: PanelInk { PanelInk(scheme: scheme) }
}

/// A right-click menu's rows, asked for when the menu is drawn, not on every
/// draw of the panel: a tile's rows look up its app, and every tile has a
/// menu.
private struct PanelMenuItems: View {
    let rows: () -> [PanelMenuRow]

    var body: some View {
        ForEach(Array(rows().enumerated()), id: \.offset) { _, row in
            switch row {
            case .action(let title, let run):
                Button(title, action: run)
            case .check(let title, let on, let enabled, let run):
                Toggle(title, isOn: Binding(get: { on }, set: { _ in run() }))
                    .disabled(!enabled)
            case .header(let title):
                Text(title)
            case .divider:
                Divider()
            }
        }
    }
}

/// The mock's colours: white on dark glass, black on light, at a few
/// strengths.
struct PanelInk {
    let scheme: ColorScheme

    private var base: Color { scheme == .dark ? .white : .black }
    var primary: Color { base.opacity(scheme == .dark ? 0.92 : 0.86) }
    var secondary: Color { base.opacity(scheme == .dark ? 0.64 : 0.6) }
    var tertiary: Color { base.opacity(scheme == .dark ? 0.40 : 0.36) }
    var well: Color { base.opacity(scheme == .dark ? 0.075 : 0.05) }
    var wellHover: Color { base.opacity(scheme == .dark ? 0.13 : 0.085) }
    var wellPress: Color { base.opacity(scheme == .dark ? 0.2 : 0.13) }
}

struct PanelTileLabel: View {
    let art: PanelTileArt
    let grid: PanelGrid
    let ink: PanelInk
    /// The well and what is on it, no name: the tile in the air.
    var glyphOnly = false
    /// The tile's own width, which the row's tiles differ in (#102); nil is
    /// the metrics'.
    var tileWidth: CGFloat?
    /// Backing pixels per point of the display the panel is on (1 on a
    /// non-Retina screen).
    @Environment(\.displayScale) private var displayScale

    private var well: CGSize { grid.wellSize(tileWidth: tileWidth) }

    var body: some View {
        let metrics = grid.metrics
        let well = well
        VStack(spacing: metrics.labelGap) {
            glyph
                .frame(width: well.width, height: well.height)
            if grid.showsNames, !glyphOnly {
                Text(art.name)
                    .font(.system(size: 11))
                    .foregroundStyle(ink.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: metrics.tileSize.width, height: metrics.labelHeight)
            }
        }
        .frame(width: glyphOnly ? well.width : tileWidth ?? metrics.tileSize.width,
               height: glyphOnly ? well.height : metrics.tileSize.height, alignment: .top)
        .contentShape(Rectangle())
    }

    private var glyph: some View {
        image.opacity(art.dimmed ? 0.35 : 1)
    }

    @ViewBuilder
    private var image: some View {
        // The picture's room grows with the row's tile, so a wide picture
        // draws as it is (#102).
        let room = CGSize(width: well.width - PanelMetrics.pictureMargin, height: well.height - PanelMetrics.pictureMargin)
        switch art.image {
        case .picture(let image, let size, let monochrome, let highlighted):
            // The bar's own size, pulled in only when it can't fit (a wide
            // text item in a 44pt well), on whole device pixels: centred in
            // points, an odd picture in an even well sat at half a pixel and
            // a 1px stroke came out black on one edge and grey on the other
            // on a 1x display (#81). Drawn as it is when its pixels already
            // fit, interpolated only when it has to be scaled.
            let placed = PanelPictureFrame(
                pixels: CGSize(width: image.width, height: image.height), size: size,
                well: well, room: room, displayScale: displayScale)
            let picture = Image(decorative: image, scale: CGFloat(image.width) / max(size.width, 1))
                .renderingMode(monochrome ? .template : .original)
                .resizable()
                .interpolation(placed.isOneToOne ? .none : .high)
            Group {
                if monochrome {
                    picture.foregroundStyle(highlighted ? PelmetAccent.accent : ink.primary)
                } else {
                    picture
                }
            }
            .frame(width: placed.frame.width, height: placed.frame.height)
            .offset(x: placed.frame.minX, y: placed.frame.minY)
            .frame(width: well.width, height: well.height, alignment: .topLeading)
        case .icon(let icon):
            let side = min(icon.isTemplate ? 16 : 20, room.height)
            Image(nsImage: icon)
                .renderingMode(icon.isTemplate ? .template : .original)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .foregroundStyle(ink.primary)
                .frame(width: side, height: side)
        }
    }
}

private struct PanelTileStyle: ButtonStyle {
    let grid: PanelGrid
    let ink: PanelInk
    let selected: Bool
    /// The tile's own width, which the row's tiles differ in (#102); nil is
    /// the metrics'.
    var tileWidth: CGFloat?

    func makeBody(configuration: Configuration) -> some View {
        Well(configuration: configuration, grid: grid, ink: ink, selected: selected, tileWidth: tileWidth)
    }

    /// A view of its own so the hover can be state.
    private struct Well: View {
        let configuration: Configuration
        let grid: PanelGrid
        let ink: PanelInk
        let selected: Bool
        let tileWidth: CGFloat?
        @State private var hovering = false

        var body: some View {
            let well = grid.wellSize(tileWidth: tileWidth)
            let row = grid.layout == .row
            configuration.label
                .background(alignment: .top) {
                    RoundedRectangle(cornerRadius: row ? 8 : 13, style: .continuous)
                        .fill(configuration.isPressed ? ink.wellPress : hovering || selected ? ink.wellHover : row ? .clear : ink.well)
                        .frame(width: well.width, height: well.height)
                        .scaleEffect(configuration.isPressed ? 0.94 : 1)
                        // On the well alone: on the whole tile, a hover that
                        // changed with a re-layout slid the tile (2026-10-09).
                        .animation(.easeOut(duration: 0.12), value: hovering)
                        .animation(.easeOut(duration: 0.14), value: configuration.isPressed)
                }
                .onHover { hovering = $0 }
        }
    }
}

/// The count: a fill that comes up on hover and press.
private struct FoldFillStyle<S: Shape>: ButtonStyle {
    let ink: PanelInk
    let shape: S
    let resting: Color

    func makeBody(configuration: Configuration) -> some View {
        Fill(configuration: configuration, ink: ink, shape: shape, resting: resting)
    }

    private struct Fill: View {
        let configuration: Configuration
        let ink: PanelInk
        let shape: S
        let resting: Color
        @State private var hovering = false

        var body: some View {
            configuration.label
                .background(
                    shape
                        .fill(configuration.isPressed ? ink.wellPress : hovering ? ink.wellHover : resting)
                        // The fill only: on the control, the hover the click
                        // changed animated the fold's re-layout as a slide.
                        .animation(.easeOut(duration: 0.12), value: hovering))
                .onHover { hovering = $0 }
        }
    }
}

/// The handle's grabber: it brightens and widens under the pointer, never a
/// band across the panel for a 28pt mark.
private struct HandleGrip: View {
    let ink: PanelInk
    let width: CGFloat
    /// A tile is dragged over it: as under the pointer.
    var lit = false
    @State private var hovering = false

    var body: some View {
        let on = hovering || lit
        Capsule()
            .fill(on ? ink.secondary : ink.tertiary)
            .frame(width: on ? 36 : 28, height: 4)
            .animation(.easeOut(duration: 0.12), value: on)
            .frame(width: width, height: 14)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}

/// The tile fold's face: "+10" folded, a chevron to close it once open.
/// With names on it is named like any tile.
private struct FoldTileLabel: View {
    let count: Int
    let open: Bool
    let title: String
    let grid: PanelGrid
    let ink: PanelInk

    var body: some View {
        let metrics = grid.metrics
        VStack(spacing: metrics.labelGap) {
            ZStack {
                if open {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 12, weight: .semibold))
                        .transition(.opacity)
                } else {
                    Text(verbatim: "+\(count)")
                        .font(.system(size: 13, weight: .medium))
                        .monospacedDigit()
                        .transition(.opacity)
                }
            }
            .foregroundStyle(ink.secondary)
            .animation(.easeOut(duration: 0.15), value: open)
            .frame(width: metrics.wellSize.width, height: metrics.wellSize.height)
            if grid.showsNames {
                // A size under the names: "Always Hidden" is 77pt at 11,
                // and the tile is 68 (Gab, 2026-10-10).
                Text(title)
                    .font(.system(size: 9.5))
                    .foregroundStyle(ink.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: metrics.tileSize.width, height: metrics.labelHeight)
            }
        }
        .frame(width: metrics.tileSize.width, height: metrics.tileSize.height, alignment: .top)
        .contentShape(Rectangle())
    }
}

/// The search row's insertion point, blinking as the mock's does.
private struct Caret: View {
    @State private var on = true

    var body: some View {
        Rectangle()
            .fill(PelmetAccent.accent)
            .frame(width: 1.5, height: 15)
            .opacity(on ? 1 : 0)
            .task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(500))
                    on.toggle()
                }
            }
    }
}

/// The panel's left edge: drag it for more or fewer columns, double-click
/// it for Auto. A grabber on the edge, half in and half out, with room
/// around it to land on (Gab, 2026-10-09: a 12pt strip inside the glass was
/// often impossible to catch).
struct ColumnGrip: View {
    /// The grip's width, centred on the edge.
    static let reach: CGFloat = 20

    let ink: PanelInk
    let panelHovered: Bool
    let onDrag: (_ x: CGFloat, _ ended: Bool) -> Void
    let onReset: () -> Void
    @State private var hovering = false
    @State private var dragging = false

    var body: some View {
        Color.clear
            .frame(width: Self.reach)
            .contentShape(Rectangle())
            .overlay {
                Capsule()
                    .fill(hovering || dragging ? ink.secondary : ink.tertiary)
                    .frame(width: 4, height: 26)
                    .opacity(hovering || dragging ? 1 : panelHovered ? 0.55 : 0)
                    .animation(.easeOut(duration: 0.15), value: hovering || dragging || panelHovered)
            }
            .onHover { hovering = $0 }
            .pointerStyle(.columnResize)
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        dragging = true
                        onDrag(value.location.x, false)
                    }
                    .onEnded { value in
                        dragging = false
                        onDrag(value.location.x, true)
                    })
            .simultaneousGesture(TapGesture(count: 2).onEnded(onReset))
    }
}

/// "4 per row" while the edge is dragged.
private struct ColumnTip: View {
    let text: String
    let ink: PanelInk

    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(ink.primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .allowsHitTesting(false)
    }
}

/// The open panel's grip, in a view of its own laid over the glass's edge
/// (`GlassPanel.edgeAccessory`).
struct PanelEdgeGrip: View {
    var shows = false
    var panelHovered = false
    var onDrag: (_ x: CGFloat, _ ended: Bool) -> Void = { _, _ in }
    var onReset: () -> Void = {}

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if shows {
            ColumnGrip(ink: PanelInk(scheme: scheme), panelHovered: panelHovered, onDrag: onDrag, onReset: onReset)
                .frame(maxHeight: .infinity)
        }
    }
}
