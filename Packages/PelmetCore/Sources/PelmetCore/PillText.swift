import CoreGraphics

/// What live mode draws of a pill's text. Dimble draws the texts itself, at
/// the frames the pill's AX tree gives them, and an AX value can be longer
/// than what macOS shows in that frame: a score's "Senators 1" shows "1",
/// macOS 27.3's "5 apps" shows "5".
public enum PillText {
    /// The value, or the part of it macOS shows, when the whole is wider
    /// than its frame (`slot`): the widest word that fits, else the last
    /// word. `width` measures a string in the drawing font.
    public static func shown(_ value: String, slot: CGFloat, width: (String) -> CGFloat) -> String {
        let room = slot * 1.6
        if width(value) <= room { return value }
        let words = value.split(separator: " ").map(String.init)
        let fitting = words.filter { width($0) <= room }
        return fitting.max { width($0) < width($1) } ?? words.last ?? value
    }
}
