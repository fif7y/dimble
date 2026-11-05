// AccentPicker.swift
// The Accent color row in Settings › General: flat swatches, the last one the
// user's own, picked in a popover attached to it. Not the system color panel:
// that is a window of its own, which opens wherever it likes, a display away.

import AppKit
import SwiftUI

/// What a color picked by hand becomes on each ground, and the label a solid
/// fill of it carries. A color that reads on a ground stays exactly as picked.
enum AccentShade {
    /// Settings' card fills: the grounds an accent's text and rings sit on.
    static let lightGround: UInt32 = 0xF2F2F4
    static let darkGround: UInt32 = 0x2A2A2C
    /// Enough for a ring or a selected label to read. The brand purple's dark
    /// shade is 3.3 on its ground.
    static let minContrast = 3.0
    /// White stays down to here, where the brand purple's dark shade (4.4) keeps it.
    static let whiteLabelContrast = 3.5

    static func shades(of hex: UInt32) -> (light: UInt32, dark: UInt32) {
        (reading(hex, on: lightGround, movingTo: 0x000000), reading(hex, on: darkGround, movingTo: 0xFFFFFF))
    }

    static func label(on hex: UInt32) -> UInt32 {
        contrast(0xFFFFFF, hex) >= whiteLabelContrast ? 0xFFFFFF : 0x1A1A1A
    }

    static func contrast(_ a: UInt32, _ b: UInt32) -> Double {
        let (x, y) = (luminance(a), luminance(b))
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    /// `hex`, mixed toward `target` only as far as it takes to read on `ground`.
    private static func reading(_ hex: UInt32, on ground: UInt32, movingTo target: UInt32) -> UInt32 {
        for step in 0...50 {
            let mixed = mix(hex, target, Double(step) / 50)
            if contrast(mixed, ground) >= minContrast { return mixed }
        }
        return target
    }

    private static func mix(_ a: UInt32, _ b: UInt32, _ t: Double) -> UInt32 {
        [16, 8, 0].reduce(UInt32(0)) { out, shift in
            let (x, y) = (Double((a >> UInt32(shift)) & 0xFF), Double((b >> UInt32(shift)) & 0xFF))
            return out | UInt32((x + (y - x) * t).rounded()) << UInt32(shift)
        }
    }

    private static func luminance(_ hex: UInt32) -> Double {
        func linear(_ shift: UInt32) -> Double {
            let c = Double((hex >> shift) & 0xFF) / 255
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(16) + 0.7152 * linear(8) + 0.0722 * linear(0)
    }
}

/// Hue, saturation and brightness, each 0...1: what the wheel and the slider
/// hold. The picker keeps these and writes 0xRRGGBB out, so a hue survives
/// dragging through black or white, where the hex alone would lose it.
struct AccentHSB: Equatable {
    var hue: Double
    var saturation: Double
    var brightness: Double

    init(hue: Double, saturation: Double, brightness: Double) {
        self.hue = hue
        self.saturation = saturation
        self.brightness = brightness
    }

    init(hex: UInt32) {
        let r = Double((hex >> 16) & 0xFF) / 255
        let g = Double((hex >> 8) & 0xFF) / 255
        let b = Double(hex & 0xFF) / 255
        let top = max(r, g, b)
        let span = top - min(r, g, b)
        let sector = span == 0 ? 0 : top == r ? (g - b) / span : top == g ? (b - r) / span + 2 : (r - g) / span + 4
        hue = (sector / 6 + 1).truncatingRemainder(dividingBy: 1)
        saturation = top == 0 ? 0 : span / top
        brightness = top
    }

    var hex: UInt32 {
        let sector = hue * 6
        let part = sector - floor(sector)
        let low = brightness * (1 - saturation)
        let falling = brightness * (1 - saturation * part)
        let rising = brightness * (1 - saturation * (1 - part))
        let (r, g, b): (Double, Double, Double)
        switch Int(sector) % 6 {
        case 0: (r, g, b) = (brightness, rising, low)
        case 1: (r, g, b) = (falling, brightness, low)
        case 2: (r, g, b) = (low, brightness, rising)
        case 3: (r, g, b) = (low, falling, brightness)
        case 4: (r, g, b) = (rising, low, brightness)
        default: (r, g, b) = (brightness, low, falling)
        }
        let byte = { (v: Double) in UInt32((v * 255).rounded()) }
        return byte(r) << 16 | byte(g) << 8 | byte(b)
    }

    /// Red on the right, turning counterclockwise, white in the middle, as
    /// macOS draws its own wheel.
    func wheelPoint(radius: CGFloat) -> CGPoint {
        let angle = hue * 2 * .pi
        return CGPoint(x: radius + radius * saturation * cos(angle), y: radius - radius * saturation * sin(angle))
    }

    /// This color with the hue and saturation under `point`, held to the rim.
    func onWheel(at point: CGPoint, radius: CGFloat) -> AccentHSB {
        let (dx, dy) = (point.x - radius, radius - point.y)
        let angle = atan2(dy, dx) / (2 * .pi)
        return AccentHSB(
            hue: angle < 0 ? angle + 1 : angle,
            saturation: min(1, hypot(dx, dy) / radius),
            brightness: brightness)
    }

    static func text(_ hex: UInt32) -> String { String(format: "#%06X", hex) }

    /// "#7E5FF2", "7e5ff2" or "#abc"; nil for anything else.
    static func parse(_ text: String) -> UInt32? {
        var digits = text.trimmingCharacters(in: .whitespaces)
        if digits.hasPrefix("#") { digits.removeFirst() }
        if digits.count == 3 { digits = digits.map { "\($0)\($0)" }.joined() }
        guard digits.count == 6, digits.allSatisfy(\.isHexDigit) else { return nil }
        return UInt32(digits, radix: 16)
    }
}

/// The picker the last swatch opens: wheel, brightness, hex, eyedropper. Every
/// change is the accent at once, as a preset's click is.
struct AccentPopover: View {
    @State private var color: AccentHSB
    @State private var text: String
    @State private var opening = true
    @State private var sampling = false
    @FocusState private var typing: Bool

    private static let wheelSize: CGFloat = 176
    /// Held here: a sampler nothing holds is gone before it can report.
    private static let sampler = NSColorSampler()

    init(hex: UInt32) {
        _color = State(initialValue: AccentHSB(hex: hex))
        _text = State(initialValue: AccentHSB.text(hex))
    }

    var body: some View {
        VStack(spacing: 14) {
            wheel
            brightness
            HStack(spacing: 8) {
                hexField
                eyedropper
            }
        }
        .padding(14)
        .frame(width: Self.wheelSize + 28)
        .interactiveDismissDisabled(sampling)
        .task {
            // A popover hands its first field the keyboard. This one opens at rest.
            try? await Task.sleep(for: .milliseconds(50))
            endTyping()
            opening = false
        }
    }

    private func apply(_ new: AccentHSB) {
        color = new
        AccentStore.shared.customHex = new.hex
        AccentStore.shared.choice = .custom
    }

    /// From the wheel, the slider or the eyedropper: the field follows and lets go.
    private func pick(_ new: AccentHSB) {
        endTyping()
        apply(new)
        text = AccentHSB.text(new.hex)
    }

    private func endTyping() {
        typing = false
        NSApp.keyWindow?.makeFirstResponder(nil)
    }

    private func thumb(_ fill: Color) -> some View {
        Circle()
            .fill(fill)
            .frame(width: 14, height: 14)
            .overlay(Circle().strokeBorder(.white, lineWidth: 2))
            .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
    }

    private var wheel: some View {
        let radius = Self.wheelSize / 2
        return ZStack {
            HueDisc()
            Circle().fill(RadialGradient(
                colors: [.white, .white.opacity(0)], center: .center, startRadius: 0, endRadius: radius))
            Circle().fill(.black.opacity(1 - color.brightness))
            thumb(Color(nsColor: AccentChoice.ns(color.hex)))
                .position(color.wheelPoint(radius: radius))
                .allowsHitTesting(false)
        }
        .frame(width: Self.wheelSize, height: Self.wheelSize)
        .contentShape(Circle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
            pick(color.onWheel(at: drag.location, radius: radius))
        })
        .accessibilityElement()
        .accessibilityLabel(Text("Color wheel"))
        .accessibilityValue(Text(verbatim: AccentHSB.text(color.hex)))
    }

    private var brightness: some View {
        let inset: CGFloat = 7
        return GeometryReader { geometry in
            let span = geometry.size.width - 2 * inset
            ZStack {
                Capsule().fill(LinearGradient(
                    colors: [.black, Color(hue: color.hue, saturation: color.saturation, brightness: 1)],
                    startPoint: .leading, endPoint: .trailing))
                thumb(Color(nsColor: AccentChoice.ns(color.hex)))
                    .position(x: inset + span * color.brightness, y: geometry.size.height / 2)
                    .allowsHitTesting(false)
            }
            .contentShape(Capsule())
            .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                var next = color
                next.brightness = min(1, max(0, (drag.location.x - inset) / span))
                pick(next)
            })
        }
        .frame(height: 14)
        .accessibilityElement()
        .accessibilityLabel(Text("Brightness"))
        .accessibilityValue(Text(verbatim: "\(Int((color.brightness * 100).rounded()))%"))
        .accessibilityAdjustableAction { direction in
            var next = color
            next.brightness = min(1, max(0, next.brightness + (direction == .increment ? 0.05 : -0.05)))
            pick(next)
        }
    }

    /// The alias field's recipe in Search: a soft fill, the accent ring while typing.
    private var hexField: some View {
        let active = typing && !opening
        return TextField("Hex color", text: $text)
            .labelsHidden()
            .textFieldStyle(.plain)
            .font(.system(size: 12, design: .monospaced))
            .autocorrectionDisabled()
            .focused($typing)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 7).fill(.primary.opacity(active ? 0.04 : 0.08)))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(PelmetAccent.accent, lineWidth: active ? 1.5 : 0))
            .onChange(of: text) { _, new in
                guard typing, let hex = AccentHSB.parse(new), hex != color.hex else { return }
                apply(AccentHSB(hex: hex))
            }
            .onSubmit {
                text = AccentHSB.text(color.hex)
                endTyping()
            }
            .onChange(of: typing) { _, now in
                if now { selectWholeOnRelease() } else { text = AccentHSB.text(color.hex) }
            }
    }

    /// A click into the field takes the whole color, ready to be replaced. It
    /// waits for the release, which would put the caret back, and a drag keeps
    /// the selection it made.
    private func selectWholeOnRelease() {
        guard !opening else { return }
        Task {
            while NSEvent.pressedMouseButtons & 1 != 0 {
                try? await Task.sleep(for: .milliseconds(10))
            }
            try? await Task.sleep(for: .milliseconds(40))
            guard let editor = NSApp.keyWindow?.firstResponder as? NSTextView,
                  editor.selectedRange().length == 0 else { return }
            editor.selectAll(nil)
        }
    }

    private var eyedropper: some View {
        Button {
            sampling = true
            Self.sampler.show { picked in
                let byte = { (v: CGFloat) in UInt32((min(max(v, 0), 1) * 255).rounded()) }
                let hex = picked?.usingColorSpace(.sRGB).map {
                    byte($0.redComponent) << 16 | byte($0.greenComponent) << 8 | byte($0.blueComponent)
                }
                Task { @MainActor in
                    sampling = false
                    if let hex { pick(AccentHSB(hex: hex)) }
                }
            }
        } label: {
            Image(systemName: "eyedropper")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 24)
                .background(RoundedRectangle(cornerRadius: 7).fill(.primary.opacity(0.08)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(Text("Pick a color from the screen"))
        .accessibilityLabel(Text("Pick a color from the screen"))
    }
}

/// The wheel's hues. Hue math has a hard crease at each primary, which reads as
/// spokes on a disc this size, so it is softened a little and cut to the circle.
private struct HueDisc: View {
    private static let hues = stride(from: 1.0, through: 0, by: -1.0 / 24).map {
        Color(hue: $0, saturation: 1, brightness: 1)
    }

    var body: some View {
        Rectangle()
            .fill(AngularGradient(colors: Self.hues, center: .center))
            .padding(-16)
            .blur(radius: 7)
            .clipShape(Circle())
    }
}

struct AccentSwatches: View {
    @Environment(\.colorScheme) private var scheme
    @State private var picking = false

    private var showing: UInt32 {
        let hex = AccentStore.shared.choice.hex
        return scheme == .dark ? hex.dark : hex.light
    }

    var body: some View {
        HStack(spacing: 8) {
            ForEach(AccentChoice.allCases.filter { $0 != .custom }) { choice in
                button(choice) { AccentStore.shared.choice = choice }
            }
            button(.custom, action: openPicker)
                // While it's open, a click here only closes it.
                .allowsHitTesting(!picking)
                .popover(isPresented: $picking, arrowEdge: .bottom) {
                    AccentPopover(hex: AccentStore.shared.customHex ?? showing)
                }
        }
    }

    /// The first time it starts from the accent showing, so the click alone
    /// changes nothing.
    private func openPicker() {
        AccentStore.shared.customHex = AccentStore.shared.customHex ?? showing
        AccentStore.shared.choice = .custom
        picking = true
    }

    private func button(_ choice: AccentChoice, action: @escaping () -> Void) -> some View {
        let selected = AccentStore.shared.choice == choice
        return Button(action: action) {
            swatch(choice)
                .frame(width: 18, height: 18)
                .padding(3)
                .overlay(Circle().strokeBorder(
                    Color(nsColor: choice.nsColor), lineWidth: selected ? 1.5 : 0))
        }
        .buttonStyle(.plain)
        .help(Text(choice.label))
        .accessibilityLabel(Text(choice.label))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// The presets are the color itself. The last is the wheel of them all,
    /// which says "any color", holding the user's own once there is one.
    @ViewBuilder private func swatch(_ choice: AccentChoice) -> some View {
        if choice == .custom {
            let wheel = AccentChoice.allCases.filter { $0 != .custom }.map { Color(nsColor: $0.nsColor) }
            Circle()
                .fill(AngularGradient(colors: wheel + [wheel[0]], center: .center))
                .overlay {
                    if AccentStore.shared.customHex != nil {
                        Circle()
                            .fill(Color(nsColor: choice.nsColor))
                            .padding(3.5)
                    }
                }
        } else {
            Circle().fill(Color(nsColor: choice.nsColor))
        }
    }
}
