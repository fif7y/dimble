import Testing
@testable import PelmetCore

@Suite struct MaskEnlargementTests {
    /// Three rows of the same row, the mask's width four.
    private func rows(_ row: [UInt8], _ count: Int) -> [UInt8] { Array([[UInt8]](repeating: row, count: count).joined()) }

    // A clean edge, clear to solid: the smooth ramp across it is pulled tight.
    @Test func aCleanEdgeIsPulledTight() {
        let source = rows([0, 0, 255, 255], 3)
        let smooth = rows([0, 0, 0, 64, 192, 255, 255, 255], 6)
        let out = MaskEnlargement.tighten(smooth: smooth, source: source, width: 4, height: 3)
        #expect(Array(out.prefix(8)) == [0, 0, 0, 0, 255, 255, 255, 255])
        #expect(out.count == smooth.count)
    }

    // A faint line (half cover at its peak) stays as smooth as it was: pulled
    // tight it would fade or close up.
    @Test func faintDetailStaysSmooth() {
        let source = rows([0, 128, 0, 0], 3)
        let smooth = rows([0, 60, 128, 100, 40, 0, 0, 0], 6)
        #expect(MaskEnlargement.tighten(smooth: smooth, source: source, width: 4, height: 3) == smooth)
    }

    @Test func aMismatchedBufferComesBackAsItWas() {
        let smooth: [UInt8] = [1, 2, 3]
        #expect(MaskEnlargement.tighten(smooth: smooth, source: [0, 255], width: 2, height: 1) == smooth)
    }
}
