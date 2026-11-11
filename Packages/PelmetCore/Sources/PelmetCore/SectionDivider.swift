import CoreGraphics

extension MenuBarGeometry {
    /// 菜单栏按“始终隐藏 → 隐藏 → 可见”排列，只在真实相邻图标的边界画线。
    public static func alwaysHiddenDivider(items: [(section: Section, frame: CGRect)]) -> CGRect? {
        let frames = items.map(\.frame)
        let trapped = PlacementGeometry.overflowTrapped(frames)
        let drawn = items.enumerated().filter { !trapped.contains($0.offset) && $0.element.frame.width > 0 }
            .map(\.element).sorted { $0.frame.midX < $1.frame.midX }
        guard let index = drawn.lastIndex(where: { $0.section == .alwaysHidden }),
              index + 1 < drawn.count else { return nil }
        let left = drawn[index].frame
        let right = drawn[index + 1].frame
        // AX 按钮边缘可能重叠少量内边距；大空隙或不同高度不能当作同一组边界。
        guard right.minX - left.maxX >= -4, right.minX - left.maxX <= 24,
              abs(left.midY - right.midY) < 4 else { return nil }
        let height = min(left.height, right.height) * 0.5
        guard height > 0 else { return nil }
        return CGRect(x: (left.maxX + right.minX) / 2 - 1,
                      y: (left.midY + right.midY) / 2 - height / 2, width: 2, height: height)
    }
}
