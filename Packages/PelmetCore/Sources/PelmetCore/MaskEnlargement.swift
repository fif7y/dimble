// MaskEnlargement.swift
// A one-colour picture cut from a 1x bar, enlarged for a 2x display (#156).
// Scaled smoothly it read blurry; doubled pixel for pixel, blocky. Pulling
// its clean edges tight came out 2.3x closer to the real 2x icons than
// smooth scaling (9 icons shrunk to 1x and enlarged back, 2026-11-22).
// Pure arithmetic on alpha, so the app draws what this says.

import Foundation

public enum MaskEnlargement {
    /// How steeply a clean edge goes from clear to solid, about half cover.
    static let steepness = 3.0
    /// The source's 3×3 spread below which a pixel stays smooth, and the one
    /// above which it is pulled fully tight. A battery's digits and a 1px
    /// line are faint at 1x: pulled tight they closed up or faded.
    static let cleanEdge = 0.7...0.95

    /// - Parameters:
    ///   - smooth: the mask drawn at twice its size, smoothly, one alpha
    ///     byte per pixel, `2 * width` by `2 * height`, rows top first.
    ///   - source: the mask itself, `width` by `height`.
    /// - Returns: `smooth` with each pixel pulled tight as far as the
    ///   source around it is a clean edge.
    public static func tighten(smooth: [UInt8], source: [UInt8], width: Int, height: Int) -> [UInt8] {
        guard width > 0, height > 0, source.count == width * height, smooth.count == 4 * width * height else { return smooth }
        // The source's spread around each of its pixels.
        var weight = [Double](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                var lo = UInt8.max, hi = UInt8.min
                for ny in max(0, y - 1)...min(height - 1, y + 1) {
                    for nx in max(0, x - 1)...min(width - 1, x + 1) {
                        let a = source[ny * width + nx]
                        lo = min(lo, a)
                        hi = max(hi, a)
                    }
                }
                let spread = Double(hi - lo) / 255
                weight[y * width + x] = min(1, max(0, (spread - cleanEdge.lowerBound) / (cleanEdge.upperBound - cleanEdge.lowerBound)))
            }
        }
        var out = smooth
        let wide = 2 * width
        for y in 0..<(2 * height) {
            for x in 0..<wide {
                let w = weight[(y / 2) * width + x / 2]
                guard w > 0 else { continue }
                let u = Double(smooth[y * wide + x]) / 255
                let tight = min(1, max(0, (u - 0.5) * steepness + 0.5))
                out[y * wide + x] = UInt8((255 * (w * tight + (1 - w) * u)).rounded())
            }
        }
        return out
    }
}
