import AppKit
import PelmetCore
import PelmetEngine

/// 只绘制组边界，不注册状态栏项目，避免影响用户排序或占用图标空间。
@MainActor
final class SectionDividerOverlay {
    private var windows: [CGDirectDisplayID: NSPanel] = [:]
    private var frames: [CGDirectDisplayID: CGRect] = [:]
    private var visibilityTimer: Timer?
    private var reported: [CGDirectDisplayID: String] = [:]

    func hide() {
        if !frames.isEmpty { PelmetLog.log("divider: reveal ended or busy, hidden") }
        visibilityTimer?.invalidate()
        visibilityTimer = nil
        frames.removeAll()
        reported.removeAll()
        for window in windows.values { window.orderOut(nil) }
    }

    func update(model: SectionModel, copies: [ItemID: [CGRect]]) {
        frames.removeAll()
        for screen in NSScreen.screens {
            guard let id = screen.directDisplayID else { continue }
            let display = CGDisplayBounds(id)
            let items = copies.compactMap { key, copies -> (section: PelmetCore.Section, frame: CGRect)? in
                guard let frame = MenuBarGeometry.copy(onDisplay: display, among: copies) else { return nil }
                return (model.section(of: key), frame)
            }
            frames[id] = MenuBarGeometry.alwaysHiddenDivider(items: items)
            if frames[id] == nil {
                report(id, "no boundary (\(items.filter { $0.section == .alwaysHidden }.count) always-hidden, \(items.count) frames)")
            }
        }
        guard !frames.isEmpty else {
            visibilityTimer?.invalidate()
            visibilityTimer = nil
            for window in windows.values { window.orderOut(nil) }
            return
        }
        draw()
        // 自动隐藏菜单栏和全屏切换不一定触发图标快照；仅在分割线启用期间检查窗口可见性。
        if visibilityTimer == nil {
            visibilityTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.draw() }
            }
        }
    }

    private func draw() {
        let onScreen = ConcealGhostOverlay.onScreenWindows() ?? []
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
        for (id, window) in windows where frames[id] == nil { window.orderOut(nil) }
        for (id, frame) in frames {
            let cocoaFrame = NSRect(x: frame.minX, y: primaryTop - frame.maxY,
                                    width: frame.width, height: frame.height)
            guard let screen = NSScreen.screens.first(where: { $0.directDisplayID == id }),
                  GlassPanel.drawnBarHeight(of: screen, fresh: true, in: onScreen) != nil else {
                report(id, "menu bar not visible")
                windows[id]?.orderOut(nil)
                continue
            }
            guard !ConcealGhostOverlay.barCover(over: cocoaFrame) else {
                report(id, "bar covered")
                windows[id]?.orderOut(nil)
                continue
            }
            let window: NSPanel
            if let existing = windows[id] {
                window = existing
            } else {
                window = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                window.isOpaque = false
                window.backgroundColor = .clear
                window.hasShadow = false
                window.ignoresMouseEvents = true
                window.hidesOnDeactivate = false
                window.level = .statusBar
                window.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
                window.animationBehavior = .none
                window.sharingType = .none
                window.contentView = DividerView()
                windows[id] = window
            }
            window.setFrame(cocoaFrame, display: true)
            window.orderFrontRegardless()
            report(id, "shown at \(Int(frame.minX)),\(Int(frame.minY))")
        }
    }

    /// 仅记录状态变化，区分缺少图标坐标、覆盖层遮挡和实际绘制，避免定时器刷日志。
    private func report(_ display: CGDirectDisplayID, _ state: String) {
        guard reported[display] != state else { return }
        reported[display] = state
        PelmetLog.log("divider: display \(display) \(state)")
    }

    private final class DividerView: NSView {
        override func draw(_ dirtyRect: NSRect) {
            // 每屏壁纸明暗可能不同，细线的明暗双边在两种背景上都可辨认。
            NSColor.black.withAlphaComponent(0.35).setFill()
            NSRect(x: 0, y: 0, width: 1, height: bounds.height).fill()
            NSColor.white.withAlphaComponent(0.35).setFill()
            NSRect(x: 1, y: 0, width: 1, height: bounds.height).fill()
        }
    }
}
