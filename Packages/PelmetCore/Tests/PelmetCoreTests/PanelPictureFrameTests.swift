import CoreGraphics
import Foundation
import Testing
@testable import PelmetCore

@Suite struct PanelPictureFrameTests {
    /// The row layout's well, and what a picture may fill of it.
    private let well = PanelMetrics.row.wellSize
    private var room: CGSize { CGSize(width: well.width - 6, height: well.height - 6) }

    private func frame(pixels: CGSize, size: CGSize? = nil, displayScale: CGFloat) -> PanelPictureFrame {
        PanelPictureFrame(
            pixels: pixels, size: size ?? CGSize(width: pixels.width / displayScale, height: pixels.height / displayScale),
            well: well, room: room, displayScale: displayScale)
    }

    private func onDevicePixels(_ value: CGFloat, scale: CGFloat) -> Bool {
        abs(value * scale - (value * scale).rounded()) < 1e-9
    }

    // An odd picture in an even well sat at half a point: on a 1x display,
    // half a pixel.
    @Test func anOddPictureOnA1xDisplayLandsOnAWholePixel() {
        let placed = frame(pixels: CGSize(width: 17, height: 21), displayScale: 1)
        #expect(placed.frame == CGRect(x: 9, y: 4, width: 17, height: 21))
        #expect(placed.isOneToOne)
    }

    @Test func aPictureThatFitsIsDrawnAtItsOwnSize() {
        let placed = frame(pixels: CGSize(width: 20, height: 18), displayScale: 1)
        #expect(placed.frame.size == CGSize(width: 20, height: 18))
        #expect(placed.frame.origin == CGPoint(x: 7, y: 5))
        #expect(placed.isOneToOne)
    }

    // Retina: an even picture is centred exactly as before; an odd one moves
    // by half a pixel, a quarter of a point.
    @Test func retinaCentresAnEvenPictureExactlyAndAnOddOneToAPixel() {
        let even = frame(pixels: CGSize(width: 40, height: 36), displayScale: 2)
        #expect(even.frame == CGRect(x: 7, y: 5, width: 20, height: 18))
        #expect(even.isOneToOne)
        let odd = frame(pixels: CGSize(width: 41, height: 37), displayScale: 2)
        #expect(odd.frame.size == CGSize(width: 20.5, height: 18.5))
        #expect(odd.frame.origin == CGPoint(x: 7, y: 5))
        #expect(odd.isOneToOne)
    }

    // Too tall for the room (a 30pt bar's picture in a 28pt well): pulled in
    // to whole pixels, so no longer one to one.
    @Test func aPictureTooTallForTheRoomIsPulledInToWholePixels() {
        let placed = frame(pixels: CGSize(width: 24, height: 30), displayScale: 1)
        #expect(placed.frame.height == room.height)
        #expect(placed.frame.width == (24 * room.height / 30).rounded())
        #expect(!placed.isOneToOne)
        #expect(onDevicePixels(placed.frame.minX, scale: 1) && onDevicePixels(placed.frame.minY, scale: 1))
    }

    // A picture taken on a Retina bar, shown on a 1x display, is shrunk to
    // whole pixels and says so.
    @Test func aRetinaPictureOnA1xDisplayIsNotOneToOne() {
        let placed = frame(pixels: CGSize(width: 41, height: 37), size: CGSize(width: 20.5, height: 18.5), displayScale: 1)
        #expect(!placed.isOneToOne)
        #expect(placed.frame.size == CGSize(width: 21, height: 19))
        #expect(onDevicePixels(placed.frame.minX, scale: 1) && onDevicePixels(placed.frame.minY, scale: 1))
    }

    @Test func everyEdgeIsOnADevicePixelWhateverTheSize() {
        for scale: CGFloat in [1, 2] {
            for width in stride(from: 3, through: 60, by: 3) {
                for height in stride(from: 4, through: 48, by: 5) {
                    let px = CGSize(width: width, height: height)
                    let placed = frame(pixels: px, size: CGSize(width: px.width / scale, height: px.height / scale), displayScale: scale)
                    let rect = placed.frame
                    #expect(onDevicePixels(rect.minX, scale: scale) && onDevicePixels(rect.minY, scale: scale))
                    #expect(onDevicePixels(rect.width, scale: scale) && onDevicePixels(rect.height, scale: scale))
                    #expect(rect.minX >= 0 && rect.minY >= 0 && rect.maxX <= well.width && rect.maxY <= well.height)
                }
            }
        }
    }

    // #156: a 1x main display's picture and the 2x built-in's copy of it.
    @Test func eachDisplayDrawsTheCopyThatMatchesItsScale() {
        let copies: [CGFloat] = [1, 2]
        #expect(PanelPictureFrame.copyIndex(pixelsPerPoint: copies, displayScale: 1) == 0)
        #expect(PanelPictureFrame.copyIndex(pixelsPerPoint: copies, displayScale: 2) == 1)
        #expect(PanelPictureFrame.copyIndex(pixelsPerPoint: [2, 1], displayScale: 1) == 1)
    }

    @Test func withNoCopySharpEnoughTheSharpestIsDrawn() {
        #expect(PanelPictureFrame.copyIndex(pixelsPerPoint: [1], displayScale: 2) == 0)
        #expect(PanelPictureFrame.copyIndex(pixelsPerPoint: [1, 2], displayScale: 3) == 1)
        #expect(PanelPictureFrame.copyIndex(pixelsPerPoint: [2], displayScale: 1) == 0)
        #expect(PanelPictureFrame.copyIndex(pixelsPerPoint: [], displayScale: 2) == nil)
    }

    // #156: a 1x cut alone is not sharp on a 2x display, so the tile there
    // draws the app's icon. The 1x display's own tile keeps the picture.
    @Test func aCutBelowTheDisplaysScaleIsNotSharp() {
        #expect(PanelPictureFrame.lacksSharpCut(pixelsPerPoint: [1], displayScale: 2))
        #expect(!PanelPictureFrame.lacksSharpCut(pixelsPerPoint: [1], displayScale: 1))
    }

    @Test func aCutFromTheSharperBarIsSharpEverywhere() {
        #expect(!PanelPictureFrame.lacksSharpCut(pixelsPerPoint: [1, 2], displayScale: 2))
        #expect(!PanelPictureFrame.lacksSharpCut(pixelsPerPoint: [2], displayScale: 1))
        #expect(!PanelPictureFrame.lacksSharpCut(pixelsPerPoint: [2], displayScale: 2))
    }

    @Test func noCutIsNotSharp() {
        #expect(PanelPictureFrame.lacksSharpCut(pixelsPerPoint: [], displayScale: 1))
    }
}
