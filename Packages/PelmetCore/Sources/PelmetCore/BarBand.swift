// BarBand.swift
// How tall the menu bar is on a display, and which window is the bar
// itself. Pure rules, so a display nobody here owns has tests.

import CoreGraphics
import Foundation

public enum BarBand {
    /// The bar's height on a display, 0 when nothing says.
    ///
    /// - Parameters:
    ///   - safe: the screen's top safe-area inset (a notch or an Island).
    ///   - visible: the band the visible frame leaves at the top. It
    ///     collapses under a full-screen app, and off the main display it
    ///     can be missing.
    ///   - window: the Window Server's bar window on that display, when one
    ///     is drawn.
    ///
    /// The bar window is the bar. A visible band taller than it filmed a row
    /// of what lies under the bar (#81), and a safe area shorter than it
    /// (40pt under a 45pt bar on a MacBook with an Island, #156) made the
    /// bar's own window taller than the band: it read as another app's
    /// surface, every picture of that bar left it out, icons and all, and
    /// the covers went under it. Without a window, a visible band more than
    /// 2pt past the safe area is not the bar, and the safe area stands.
    ///
    /// The window only raises the band while the visible frame shows a bar.
    /// Under a full-screen app it is the height kept from before, and a
    /// band raised to it would film rows of the app under the bar.
    public static func height(safe: CGFloat, visible: CGFloat, window: CGFloat?) -> CGFloat {
        let band = visible > 0 && (safe == 0 || visible <= safe + 2) ? visible : safe
        guard band > 0, let window, window > 0 else { return band }
        return window > band && visible <= 0 ? band : window
    }

    /// Whether a window over a rect in the bar is the Window Server's bar
    /// itself: at the main-menu level, starting at or above the rect's top
    /// (`top`: the display's for a band, lower for a pill's own rect), and
    /// no taller than a bar gets. Never another app's surface over the band,
    /// whatever height the band was read at.
    public static func isBarWindow(
        owner: String?, layer: Int, barLevel: Int, y: CGFloat, top: CGFloat, height: CGFloat
    ) -> Bool {
        owner == "Window Server" && layer == barLevel && y < top + 1 && height >= 20 && height < 100
    }
}
