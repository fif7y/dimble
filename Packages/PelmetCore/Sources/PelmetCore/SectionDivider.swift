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
    /// The line tells Always Hidden from Hidden, so it needs both out. With
    /// Always Hidden out on its own (a middle click, #149) it stood between
    /// the last icon and the chevron, dividing nothing.
    public static func showsSectionDivider(revealed: Set<Section>) -> Bool {
        revealed.isSuperset(of: [.hidden, .alwaysHidden])
    }

    /// Shorter than any icon. Half a slot was 12pt on a 24pt bar and 18.5pt
    /// on a notched display's 37pt one, taller than the icons beside it (#149).
    static let dividerHeight: CGFloat = 10

    /// The bar orders Always Hidden before Hidden and Visible; draw only between adjacent icons.
    ///
    /// `ink`: how wide each neighbour's icon is drawn, where a picture of it
    /// says. The line goes midway between the two icons' ink, not between
    /// their slots: a slot is as wide as its host asked for and the icon sits
    /// in the middle of it, so a wide glyph beside a narrow one (a folder
    /// beside the chevron) put a line on the slot edge hard against the wide
    /// one. With no measure an icon is taken to fill its slot up to 22pt,
    /// which centres two unmeasured neighbours the way their slots' middles
    /// do (measured 2026-11-17: a 23pt battery beside a 24pt glyph in a 42pt
    /// slot, 8pt and 9pt either side).
    ///
    /// A picture is not the whole truth (the capsule behind an item in use
    /// is not in it, and an icon is not always dead centre), so the line
    /// goes at most 4pt into a measured neighbour's slot, and never into one
    /// that was not measured.
    public static func alwaysHiddenDivider(
        items: [(section: Section, frame: CGRect)], ink: (left: CGFloat?, right: CGFloat?) = (nil, nil)
    ) -> CGRect? {
        guard let (left, right) = alwaysHiddenNeighbours(items: items) else { return nil }
        let height = min(dividerHeight, min(left.height, right.height) * 0.5)
        guard height > 0 else { return nil }
        func inkWidth(_ measured: CGFloat?, in slot: CGRect) -> CGFloat {
            min(measured ?? min(max(slot.width - 4, 0), 22), slot.width)
        }
        let leftEdge = left.midX + inkWidth(ink.left, in: left) / 2
        let rightEdge = right.midX - inkWidth(ink.right, in: right) / 2
        // Ink that overlaps is a bad measurement: the middle of the slot gap.
        let between = rightEdge >= leftEdge ? (leftEdge + rightEdge) / 2 : (left.maxX + right.minX) / 2
        let reach: (CGFloat?) -> CGFloat = { $0 == nil ? 0 : 4 }
        let centre = min(max(between, left.maxX - reach(ink.left)), right.minX + reach(ink.right)).rounded()
        return CGRect(x: centre - 1,
                      y: (left.midY + right.midY) / 2 - height / 2, width: 2, height: height)
    }
}
