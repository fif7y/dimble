import CoreGraphics

extension MenuBarGeometry {
    /// The bar orders Always Hidden before Hidden and Visible; draw only between adjacent icons.
    public static func alwaysHiddenDivider(items: [(section: Section, frame: CGRect)]) -> CGRect? {
        let frames = items.map(\.frame)
        let trapped = PlacementGeometry.overflowTrapped(frames)
        let drawn = items.enumerated().filter { !trapped.contains($0.offset) && $0.element.frame.width > 0 }
            .map(\.element).sorted { $0.frame.midX < $1.frame.midX }
        guard let index = drawn.lastIndex(where: { $0.section == .alwaysHidden }),
              index + 1 < drawn.count else { return nil }
        let left = drawn[index].frame
        let right = drawn[index + 1].frame
        // AX button padding can overlap slightly; large gaps or different heights are not a group boundary.
        guard right.minX - left.maxX >= -4, right.minX - left.maxX <= 24,
              abs(left.midY - right.midY) < 4 else { return nil }
        let height = min(left.height, right.height) * 0.5
        guard height > 0 else { return nil }
        return CGRect(x: (left.maxX + right.minX) / 2 - 1,
                      y: (left.midY + right.midY) / 2 - height / 2, width: 2, height: height)
    }
}
