// PanelPictureFrame.swift
// Where an item's picture draws in its tile's well so every edge lands on a
// whole device pixel (docs/PANEL-PLAN.md §2). Centred in points, an odd
// picture in an even well sat at half a pixel and a 1px stroke came out one
// edge black and the other grey on a 1x display (#81); scaled by a fraction
// it smeared the same way. Pure geometry, so the view draws what this says.

import CoreGraphics
import Foundation

public struct PanelPictureFrame: Equatable, Sendable {
    /// The picture's frame in the well, top-left origin, in points. Origin
    /// and size are both whole device pixels.
    public let frame: CGRect
    /// The picture's own pixels cover the device pixels one to one: it is
    /// drawn as it is, with nothing to interpolate.
    public let isOneToOne: Bool

    /// - Parameters:
    ///   - pixels: the picture's size in its own pixels.
    ///   - size: its size in points on the display it was taken on.
    ///   - well: the well it is centred in.
    ///   - room: what it may fill of the well; past it the picture is pulled
    ///     in, keeping its shape (the bar's own size otherwise).
    ///   - displayScale: the backing scale of the display the panel is on.
    public init(pixels: CGSize, size: CGSize, well: CGSize, room: CGSize, displayScale: CGFloat) {
        let scale = max(displayScale, 1)
        let fit = min(1, room.width / max(size.width, 1), room.height / max(size.height, 1))
        let width = max(1, (size.width * fit * scale).rounded())
        let height = max(1, (size.height * fit * scale).rounded())
        frame = CGRect(
            x: ((well.width * scale - width) / 2).rounded() / scale,
            y: ((well.height * scale - height) / 2).rounded() / scale,
            width: width / scale, height: height / scale)
        isOneToOne = width == pixels.width && height == pixels.height
    }

    /// Which of an icon's copies a panel on a display of `displayScale`
    /// draws, by each copy's pixels per point: the one that covers the
    /// display's pixels with the fewest to spare, so it is drawn as it is,
    /// else the sharpest. A 1x main display's picture drawn on a 2x
    /// built-in read blurry, and the built-in's 2x picture drawn on the 1x
    /// display read soft (#156). Nil when there is none.
    public static func copyIndex(pixelsPerPoint: [CGFloat], displayScale: CGFloat) -> Int? {
        let scale = max(displayScale, 1)
        let covering = pixelsPerPoint.indices.filter { pixelsPerPoint[$0] >= scale - 0.01 }
        if let best = covering.min(by: { pixelsPerPoint[$0] < pixelsPerPoint[$1] }) { return best }
        return pixelsPerPoint.indices.max { pixelsPerPoint[$0] < pixelsPerPoint[$1] }
    }
}
