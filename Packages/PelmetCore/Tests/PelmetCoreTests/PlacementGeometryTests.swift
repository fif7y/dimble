// PlacementGeometryTests.swift
// Locks Apply's neighbour math: between-centers target with the corner
// floor 200 / trailing clamp maxX−60, the slot check, primary-band
// membership and the overflow trapped count.

import CoreGraphics
import Testing
@testable import PelmetCore

struct PlacementGeometryTests {
    let maxX: CGFloat = 1728
    func rect(_ x: CGFloat, width: CGFloat = 30) -> CGRect {
        CGRect(x: x, y: 0, width: width, height: 24)
    }

    @Test func centeredPanelStaysCenteredAwayFromEdges() {
        #expect(PlacementGeometry.centeredPanelX(pointerX: 800, width: 400,
                                                  screenMinX: 0, screenMaxX: 1728, margin: 20) == 600)
    }

    @Test func centeredPanelClampsToBothScreenEdges() {
        #expect(PlacementGeometry.centeredPanelX(pointerX: 10, width: 400,
                                                  screenMinX: 0, screenMaxX: 1728, margin: 20) == 20)
        #expect(PlacementGeometry.centeredPanelX(pointerX: 1718, width: 400,
                                                  screenMinX: 0, screenMaxX: 1728, margin: 20) == 1308)
    }

    @Test func inSlotChecksOrderAgainstPresentNeighborsOnly() {
        #expect(PlacementGeometry.inSlot(x: 450, leftMidX: 400, rightMidX: 500))
        #expect(!PlacementGeometry.inSlot(x: 390, leftMidX: 400, rightMidX: 500))
        #expect(!PlacementGeometry.inSlot(x: 510, leftMidX: 400, rightMidX: 500))
        #expect(PlacementGeometry.inSlot(x: 510, leftMidX: 400, rightMidX: nil))
        #expect(PlacementGeometry.inSlot(x: 390, leftMidX: nil, rightMidX: nil))
    }

    @Test func betweenCentersUsesMidpointWithCornerClamps() {
        #expect(PlacementGeometry.betweenCentersX(left: rect(400), right: rect(500), screenMaxX: maxX)
            == 465)
        #expect(PlacementGeometry.betweenCentersX(left: rect(40), right: rect(120), screenMaxX: maxX)
            == 200)
        #expect(PlacementGeometry.betweenCentersX(left: rect(1690), right: rect(1720), screenMaxX: maxX)
            == maxX - 60)
    }

    @Test func primaryBandRejectsOtherDisplaysAndOffBandFrames() {
        #expect(PlacementGeometry.isPrimary(rect(1100), screenMaxX: maxX))
        #expect(!PlacementGeometry.isPrimary(CGRect(x: 1100, y: 500, width: 30, height: 24), screenMaxX: maxX))
        #expect(!PlacementGeometry.isPrimary(rect(-614), screenMaxX: maxX))
        #expect(!PlacementGeometry.isPrimary(rect(1800), screenMaxX: maxX))
    }

    @Test func trappedIsEveryFrameOverlappingAnother() {
        func f(_ x: CGFloat, _ w: CGFloat = 30) -> CGRect { CGRect(x: x, y: 0, width: w, height: 24) }
        // One shared minX (2026-08-21).
        #expect(PlacementGeometry.overflowTrappedCount([f(909), f(909.2), f(950), f(1005), f(909.1)]) == 3)
        // Staggered phantoms (2026-09-21): Velja, DBngin, a separator, then OpenClip.
        let bar = [f(1044, 37), f(1049, 24), f(1055, 26), f(1087, 36), f(1121, 37)]
        #expect(PlacementGeometry.overflowTrapped(bar) == [0, 1, 2])
        // Edge to edge, or the ~2pt of AX padding real neighbours share, is not an overlap.
        #expect(PlacementGeometry.overflowTrappedCount([f(900, 50), f(950, 55), f(1005)]) == 0)
        #expect(PlacementGeometry.overflowTrappedCount([f(1232, 34), f(1264, 39), f(1339, 44)]) == 0)
        #expect(PlacementGeometry.overflowTrappedCount([]) == 0)
    }

    @Test func aFrameNoLongerDrawnNeverTrapsADrawnOne() {
        func f(_ x: CGFloat, _ w: CGFloat = 30) -> CGRect { CGRect(x: x, y: 0, width: w, height: 24) }
        // Camera & mic collapsing onto the chevron: the chevron stays.
        #expect(PlacementGeometry.overflowTrapped([f(1100), f(1105), f(1200)], drawn: [true, false, true]) == [1])
        // Drawn phantoms are still phantoms, the leaving frame with them.
        #expect(PlacementGeometry.overflowTrapped([f(1044, 37), f(1049, 24), f(1055, 26)], drawn: [true, true, false]) == [0, 1, 2])
        // Two leaving frames on top of each other are trapped as before.
        #expect(PlacementGeometry.overflowTrapped([f(900), f(902), f(1000)], drawn: [false, false, true]) == [0, 1])
        #expect(PlacementGeometry.overflowTrapped([f(900), f(1000)], drawn: [false, true]).isEmpty)
    }
}
