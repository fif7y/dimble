import CoreGraphics

extension MenuBarGeometry {
    /// The two icons the Always Hidden boundary falls between, left then
    /// right, or nil where the bar shows no such boundary. Apart from the
    /// divider itself so the log can name the gap it drew in.
    public static func alwaysHiddenNeighbours(items: [(section: Section, frame: CGRect)]) -> (left: CGRect, right: CGRect)? {
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
        return (left, right)
    }

    /// The bar orders Always Hidden before Hidden and Visible; draw only between adjacent icons.
    public static func alwaysHiddenDivider(items: [(section: Section, frame: CGRect)]) -> CGRect? {
        guard let (left, right) = alwaysHiddenNeighbours(items: items) else { return nil }
        let height = min(left.height, right.height) * 0.5
        guard height > 0 else { return nil }
        // Between the two icons, not between their slots. A slot is as wide as
        // its host asked for and the icon sits in the middle of it, so a 38pt
        // slot holding a 14pt glyph leaves the slot's edge nowhere near the
        // icon: centring on that edge put the line hard against its left
        // neighbour. Icon centres carry the padding on both sides, and the
        // clamp keeps the line out of a slot however lopsided the pair is.
        let centre = min(max((left.midX + right.midX) / 2, left.maxX), right.minX)
        return CGRect(x: centre - 1,
                      y: (left.midY + right.midY) / 2 - height / 2, width: 2, height: height)
    }
}
