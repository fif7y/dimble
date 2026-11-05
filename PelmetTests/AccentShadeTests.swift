import CoreGraphics
import Testing
@testable import Pelmet

@MainActor
struct AccentShadeTests {
    @Test func aColorThatReadsOnBothGroundsStaysAsPicked() {
        let shades = AccentShade.shades(of: 0x3B82F6)
        #expect(shades.light == 0x3B82F6)
        #expect(shades.dark == 0x3B82F6)
    }

    @Test func whiteIsDarkenedOnALightWindowOnly() {
        let shades = AccentShade.shades(of: 0xFFFFFF)
        #expect(shades.dark == 0xFFFFFF)
        #expect(AccentShade.contrast(shades.light, AccentShade.lightGround) >= AccentShade.minContrast)
    }

    @Test func blackIsLightenedOnADarkWindowOnly() {
        let shades = AccentShade.shades(of: 0x000000)
        #expect(shades.light == 0x000000)
        #expect(AccentShade.contrast(shades.dark, AccentShade.darkGround) >= AccentShade.minContrast)
    }

    @Test func theBrandPurpleKeepsItsWhiteLabel() {
        #expect(AccentShade.label(on: 0x6841ED) == 0xFFFFFF)
        #expect(AccentShade.label(on: 0x7E5FF2) == 0xFFFFFF)
    }

    @Test func aLightAccentGetsADarkLabel() {
        #expect(AccentShade.label(on: 0xF6AB6B) == 0x1A1A1A)
    }

    @Test func purpleIsTheFirstChoiceAndItsColorsHaveNotChanged() {
        #expect(AccentChoice.allCases.first == .purple)
        #expect(AccentChoice.purple.hex.light == 0x6841ED)
        #expect(AccentChoice.purple.hex.dark == 0x7E5FF2)
    }

    @Test func everyPresetSurvivesTheWheel() {
        for choice in AccentChoice.allCases where choice != .custom {
            #expect(AccentHSB(hex: choice.hex.light).hex == choice.hex.light)
            #expect(AccentHSB(hex: choice.hex.dark).hex == choice.hex.dark)
        }
    }

    @Test func theWheelHasRedOnTheRightAndWhiteInTheMiddle() {
        let bright = AccentHSB(hue: 0, saturation: 0, brightness: 1)
        #expect(bright.onWheel(at: CGPoint(x: 88, y: 88), radius: 88).hex == 0xFFFFFF)
        #expect(bright.onWheel(at: CGPoint(x: 176, y: 88), radius: 88).hex == 0xFF0000)
        // Counterclockwise: yellow is up and to the right, like macOS's own wheel.
        let yellow = AccentHSB(hue: 1.0 / 6, saturation: 1, brightness: 1)
        let point = yellow.wheelPoint(radius: 88)
        #expect(point.x > 88)
        #expect(point.y < 88)
        #expect(yellow.hex == 0xFFFF00)
    }

    @Test func aDragPastTheRimStaysOnTheRim() {
        let dragged = AccentHSB(hue: 0, saturation: 0, brightness: 1).onWheel(at: CGPoint(x: 500, y: 88), radius: 88)
        #expect(dragged.saturation == 1)
    }

    @Test func aDragThroughBlackKeepsItsHue() {
        var color = AccentHSB(hex: 0x69C6FA)
        let hue = color.hue
        color.brightness = 0
        #expect(color.hex == 0x000000)
        #expect(color.hue == hue)
    }

    @Test func hexTextParses() {
        #expect(AccentHSB.parse("#7E5FF2") == 0x7E5FF2)
        #expect(AccentHSB.parse("7e5ff2") == 0x7E5FF2)
        #expect(AccentHSB.parse(" #abc ") == 0xAABBCC)
        #expect(AccentHSB.parse("#7E5FF") == nil)
        #expect(AccentHSB.parse("purple") == nil)
    }
}
