// ChevronMenuCard.swift
// Settings › Behavior: what the right-click menu shows, edited on a drawing
// of the menu itself rather than a list that stands in for it. The stage is
// the Search and Panel demos' (`DemoBackdrop`), so the three previews are
// one recipe rather than three lookalikes.
//
// A separator has a handle but no tick: `ChevronMenu.drawnFlags` decides
// whether it survives, and a row that won't be drawn is dimmed here, so the
// preview says what the menu will do instead of what the order holds.

import PelmetCore
import SwiftUI

extension ChevronMenuEntry {
    /// The row's resting title, the same string the menu builds with. The
    /// toggle flips to "Hide Items" while the bar is open; the editor shows
    /// the resting face.
    var editorTitle: LocalizedStringKey {
        switch self {
        case .search: "Search…"
        case .settings: "Dimble Settings…"
        case .toggle: "Show Hidden Items"
        case .showAll: "Show Always Hidden Too"
        case .animation: "Animation"
        case .revealTarget: "Show hidden icons in"
        case .checkForUpdates: "Check for Updates…"
        case .editMenuBar: "Edit Menu Bar…"
        case .quit: "Quit Dimble"
        }
    }
}

struct ChevronMenuCard: View {
    @Environment(AppState.self) private var appState
    @State private var target: Int?

    private var menu: ChevronMenu { appState.settings.chevronMenu }

    var body: some View {
        SettingsCard(title: "Right-click menu") {
            SettingRow(
                title: "What the chevron's menu shows",
                caption: "Tick what appears, drag to reorder. Settings and Quit always stay."
            ) {
                if menu != ChevronMenu() {
                    Button("Reset") { write(ChevronMenu()) }
                        .buttonStyle(.bordered)
                }
            }
            stage
            Text("The same menu opens on a separator and on the empty bar.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var stage: some View {
        ZStack {
            DemoBackdrop()
            preview
                .padding(.vertical, 20)
        }
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var preview: some View {
        let flags = menu.drawnFlags
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(menu.order.enumerated()), id: \.offset) { index, slot in
                row(slot, index: index, drawn: flags[index])
                    .contentShape(Rectangle())
                    .background(alignment: .leading) {
                        if target == index {
                            RoundedRectangle(cornerRadius: 5)
                                .fill(PelmetAccent.accent.opacity(0.25))
                        }
                    }
                    .onDrag {
                        NSItemProvider(object: String(index) as NSString)
                    }
                    .dropDestination(for: String.self) { payload, _ in
                        target = nil
                        guard let from = payload.first.flatMap(Int.init) else { return false }
                        move(from: from, to: index)
                        return true
                    } isTargeted: { over in
                        target = over ? index : (target == index ? nil : target)
                    }
            }
        }
        .frame(width: 262)
        .padding(.vertical, 5)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
            .strokeBorder(.white.opacity(0.14), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.35), radius: 12, y: 6)
        .animation(.spring(duration: 0.25), value: menu)
    }

    @ViewBuilder
    private func row(_ slot: ChevronMenuSlot, index: Int, drawn: Bool) -> some View {
        switch slot {
        case .separator:
            HStack(spacing: 9) {
                // Dashed while it would collapse: the group above it is
                // empty, so the menu won't draw this one.
                Rectangle()
                    .fill(drawn ? AnyShapeStyle(.separator) : AnyShapeStyle(.clear))
                    .frame(height: 1)
                    .overlay {
                        if !drawn {
                            Line().stroke(style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                                .foregroundStyle(.tertiary)
                        }
                    }
                grip
            }
            .padding(.horizontal, 11)
            .frame(height: 11)
        case .entry(let entry):
            HStack(spacing: 9) {
                tick(entry)
                Text(entry.editorTitle)
                    .lineLimit(1)
                    // Secondary, not tertiary: an unticked row still has to
                    // be readable, and this material sits over a bright
                    // stage where tertiary all but disappears.
                    .foregroundStyle(drawn ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                Spacer(minLength: 4)
                if entry.hasSubmenu {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                grip
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private func tick(_ entry: ChevronMenuEntry) -> some View {
        if entry.isAlwaysShown {
            Image(systemName: "lock.fill")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .frame(width: 14)
                .help("Always in the menu")
        } else {
            Toggle("", isOn: Binding(
                get: { !menu.isHidden(entry) },
                set: { on in
                    var edited = menu
                    if on { edited.hidden.remove(entry) } else { edited.hidden.insert(entry) }
                    write(edited)
                }
            ))
            .toggleStyle(.checkbox)
            .labelsHidden()
            .frame(width: 14)
        }
    }

    private var grip: some View {
        Image(systemName: "line.3.horizontal")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.tertiary)
    }

    private func move(from: Int, to: Int) {
        write(menu.moving(from: from, to: to))
    }

    private func write(_ edited: ChevronMenu) {
        appState.settings.chevronMenu = edited.normalized()
        appState.settingsChanged()
    }
}

/// A plain horizontal rule, for the dashed separator above. `nonisolated`:
/// the file is main-actor by default and a Shape conformance must not be.
private struct Line: Shape {
    nonisolated func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return path
    }
}
