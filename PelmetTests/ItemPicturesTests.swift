import AppKit
import CoreGraphics
import Testing
@testable import Pelmet

/// A white glyph on a mid blue bar, the column `picture(from:raw:background:)`
/// gets from a pass. A window under the bar that gained focus after the empty
/// bar was taken shades the bar's bottom rows a few levels (#127).
@MainActor
struct ItemPicturesTests {
    private static let bar = (r: 88, g: 122, b: 168)
    private static let width = 60, height = 57

    /// `shade` scales the bar in the rows it names; the glyph is a 20×16 white block.
    private func picture(shade: (Int) -> Double) -> ItemPictures.Picture? {
        let raw = image { x, y in
            if (20..<40).contains(x), (20..<36).contains(y) { return (255, 255, 255) }
            let s = shade(y)
            return (Int(Double(Self.bar.r) * s), Int(Double(Self.bar.g) * s), Int(Double(Self.bar.b) * s))
        }
        let background = image { _, _ in (Self.bar.r, Self.bar.g, Self.bar.b) }
        let snap = ConcealGhostOverlay.BarSnapshot(
            image: raw, windowFrame: NSRect(x: 0, y: 0, width: 30, height: 29), takenAt: Date())
        return ItemPictures.picture(from: snap, raw: raw, background: background)
    }

    private func image(_ pixel: (Int, Int) -> (Int, Int, Int)) -> CGImage {
        let w = Self.width, h = Self.height
        let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let px = ctx.data!.bindMemory(to: UInt8.self, capacity: w * h * 4)
        // The context's memory runs top row first, as `ItemPictures.rgba` reads it.
        for y in 0..<h {
            for x in 0..<w {
                let i = (y * w + x) * 4
                let (r, g, b) = pixel(x, y)
                px[i] = UInt8(r); px[i + 1] = UInt8(g); px[i + 2] = UInt8(b); px[i + 3] = 255
            }
        }
        return ctx.makeImage()!
    }

    @Test func faintShadeUnderTheGlyphKeepsItsMask() throws {
        let picture = try #require(picture { (48..<57).contains($0) ? 0.94 : 1 })
        #expect(picture.isMonochrome)
        // The glyph's 8pt and a pixel of padding a side, none of the shaded rows.
        #expect(picture.size.height == 9)
    }

    @Test func aClearlyDarkBandStillRefusesTheMask() throws {
        let picture = try #require(picture { (50..<57).contains($0) ? 0.5 : 1 })
        #expect(!picture.isMonochrome)
    }

    /// Screen Mirroring in use, the colours sampled from #125: a capsule wider
    /// than the frame, cut by it, and a ring drawn in `ink` with a one-pixel
    /// rim at `rim` coverage. The rows above and below the capsule are the bar.
    private func onCapsule(ink: (Int, Int, Int), capsule: (Int, Int, Int) = (109, 124, 255), rim: Double = 0.6) -> ItemPictures.Picture? {
        let bar = (79, 113, 153)
        func mix(_ coverage: Double) -> (Int, Int, Int) {
            func one(_ under: Int, _ over: Int) -> Int { Int(Double(under) + Double(over - under) * coverage) }
            return (one(capsule.0, ink.0), one(capsule.1, ink.1), one(capsule.2, ink.2))
        }
        let raw = image { x, y in
            guard (4..<53).contains(y) else { return bar }
            // How far outside the ring's outer box, and how deep inside it.
            let outside = max(14 - x, x - 45, 16 - y, y - 40)
            let depth = min(x - 14, 45 - x, y - 16, 40 - y)
            if outside == 1 { return mix(rim) }
            if (0..<3).contains(depth) { return mix(1) }
            if depth == 3 { return mix(rim) }
            return capsule
        }
        let background = image { _, _ in bar }
        let snap = ConcealGhostOverlay.BarSnapshot(
            image: raw, windowFrame: NSRect(x: 0, y: 0, width: 30, height: 29), takenAt: Date())
        return ItemPictures.picture(from: snap, raw: raw, background: background)
    }

    @Test func aWhiteGlyphOnASaturatedCapsuleKeepsItsMask() throws {
        let picture = try #require(onCapsule(ink: (255, 255, 255)))
        #expect(picture.isMonochrome)
        // The ring and its rim, a pixel of padding a side; none of the capsule.
        #expect(picture.size.width == 18)
        #expect(picture.size.height == 14.5)
        #expect(picture.isHighlighted)
    }

    /// The bar with a quarter of white over it, as Velja's and Herd's are:
    /// less colour than the bar behind it.
    @Test func aSeeThroughCapsuleIsNoHighlight() throws {
        let picture = try #require(onCapsule(ink: (255, 255, 255), capsule: (123, 148, 178)))
        #expect(picture.isMonochrome)
        #expect(!picture.isHighlighted)
    }

    @Test func aGlyphOnTheBarIsNoHighlight() throws {
        let picture = try #require(picture { _ in 1 })
        #expect(picture.isMonochrome)
        #expect(!picture.isHighlighted)
    }

    @Test func aColouredGlyphOnASaturatedCapsuleStaysColoured() throws {
        let picture = try #require(onCapsule(ink: (255, 200, 40)))
        #expect(!picture.isMonochrome)
        #expect(!picture.isHighlighted)
    }
}
