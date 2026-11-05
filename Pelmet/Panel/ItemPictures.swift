// ItemPictures.swift
// One picture per item for the panel's tiles: the icon as the bar draws it,
// keyed out against the empty bar so it sits on glass with no bar around it
// (ported from the tray's TrayPictures). Kept across launches in the user's
// cache folder (#104). Nothing here captures: the picture pass hands
// pictures in (TransitionCoordinator.picturePass).

import AppKit
import ImageIO
import PelmetCore
import PelmetEngine
import UniformTypeIdentifiers

@MainActor
final class ItemPictures {
    struct Picture {
        let image: CGImage
        /// Points on the display it was taken on.
        let size: CGSize
        let takenAt: Date
        /// One colour, as most bar glyphs are: the tile tints it for the
        /// panel's own appearance, since the bar it was taken on can be
        /// dark over a light panel or the other way round.
        let isMonochrome: Bool
    }

    /// Past this a picture is retaken on the next open: an app can redraw
    /// its icon (a badge, a new state) while it is hidden and nothing tells
    /// Pelmet. One pass every 15 minutes of use at most. The old picture
    /// stays on its tile until the new one lands: dropped at expiry, every
    /// tile turned app icon for the pass's second (#81).
    static let maxAge: TimeInterval = 900

    private var pictures: [ItemID: Picture] = [:]
    /// Light or dark, as the pictures were taken. A one-colour picture is
    /// tinted for the panel; a coloured one keeps the bar's own look (white
    /// parts from a dark bar on light glass), so a switch drops those.
    private var takenDark: Bool?
    /// The write after a store, held a moment so a pass's batches go as one.
    private var saveTask: Task<Void, Never>?

    init() {
        load()
    }

    /// The latest picture, however old: `isStale` says when to retake it.
    func picture(for key: ItemID) -> Picture? {
        dropColouredOnAppearanceChange()
        return pictures[key]
    }

    func isStale(_ picture: Picture) -> Bool {
        -picture.takenAt.timeIntervalSinceNow >= Self.maxAge
    }

    func store(_ new: [ItemID: Picture]) {
        dropColouredOnAppearanceChange()
        pictures.merge(new) { _, latest in latest }
        scheduleSave()
    }

    private func dropColouredOnAppearanceChange() {
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let before = takenDark
        takenDark = dark
        guard let before, before != dark else { return }
        let coloured = pictures.filter { !$0.value.isMonochrome }.map(\.key)
        guard !coloured.isEmpty else { return }
        for key in coloured { pictures[key] = nil }
        PelmetLog.log("panel: \(dark ? "dark" : "light") mode, \(coloured.count) coloured picture(s) dropped")
        scheduleSave()
    }

    // MARK: - Kept across launches

    /// Pictures were memory only, so the first open after a launch drew app
    /// icons for the second the pass took, and the row's tiles jumped to
    /// their pictures' widths when they landed (#104). The last session's
    /// pictures are kept in the user's own cache folder and drawn from the
    /// first frame: each is past `maxAge` by then, so the pass retakes it as
    /// it does any stale picture, and a tile's width holds unless the icon
    /// itself changed. Nothing a pass could not take again, in a folder the
    /// system may clear; a picture is one of the user's own bar icons, keyed
    /// out, never the bar around it.
    private static var keptURL: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent(PelmetBundle.mainID, isDirectory: true)
            .appendingPathComponent("panel-pictures.plist")
    }

    /// Past this a kept picture is not loaded or written: an icon from a
    /// month ago is likelier wrong than right, and the file stays small.
    private static let keepFor: TimeInterval = 30 * 24 * 3600

    private struct Kept: Codable {
        struct Entry: Codable {
            let key: String
            let png: Data
            let width: Double
            let height: Double
            let takenAt: Date
            let isMonochrome: Bool
        }
        let dark: Bool
        let entries: [Entry]
    }

    private func load() {
        guard let url = Self.keptURL, let data = try? Data(contentsOf: url),
              let kept = try? PropertyListDecoder().decode(Kept.self, from: data) else { return }
        var loaded: [ItemID: Picture] = [:]
        for entry in kept.entries where -entry.takenAt.timeIntervalSinceNow < Self.keepFor {
            guard let source = CGImageSourceCreateWithData(entry.png as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { continue }
            loaded[ItemID(rawValue: entry.key)] = Picture(
                image: image, size: CGSize(width: entry.width, height: entry.height),
                takenAt: entry.takenAt, isMonochrome: entry.isMonochrome)
        }
        guard !loaded.isEmpty else { return }
        pictures = loaded
        takenDark = kept.dark
        PelmetLog.log("panel: \(loaded.count) picture(s) kept from the last launch")
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.save()
        }
    }

    private func save() {
        guard let url = Self.keptURL, let dark = takenDark else { return }
        let entries = pictures.compactMap { key, picture -> Kept.Entry? in
            guard -picture.takenAt.timeIntervalSinceNow < Self.keepFor, let png = Self.png(picture.image) else { return nil }
            return Kept.Entry(key: key.rawValue, png: png, width: picture.size.width, height: picture.size.height,
                              takenAt: picture.takenAt, isMonochrome: picture.isMonochrome)
        }
        guard let data = try? PropertyListEncoder().encode(Kept(dark: dark, entries: entries)) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    /// Drawn once more first: a picture cut from a stream frame does not
    /// serialize as it is (as `dumpPass` found).
    private static func png(_ image: CGImage) -> Data? {
        guard let bitmap = rgba(image, width: image.width, height: image.height) else { return nil }
        defer { withExtendedLifetime(bitmap.context) {} }
        guard let copy = bitmap.context.makeImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, copy, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    /// `snap` is one item's column of a keyed-out strip, trimmed to the
    /// glyph's own pixels: an AX frame is not centred on what its item draws
    /// (Control Center's Sound sat left in its cell), and the tile centres
    /// the glyph itself. `raw` and `background` are the same column as
    /// filmed and on the empty bar: a one-colour glyph is un-blended from
    /// them into a mask the tile tints (the keyed column keeps each
    /// antialiased edge whole, in the bar's colour: a dark fringe on light
    /// glass). Nil when the column is blank.
    static func picture(from snap: ConcealGhostOverlay.BarSnapshot, raw: CGImage?, background: CGImage?) -> Picture? {
        let image = snap.image
        guard snap.windowFrame.width > 0 else { return nil }
        let mask = raw.flatMap { raw in background.flatMap { flatMask(raw: raw, background: $0) } }
        // The box is read off the mask when there is one: the capsule the
        // bar draws behind an item drops out of the mask but stays in the
        // keyed column as faint ink, and a 17pt glyph in a 38pt capsule made
        // a 42pt row tile (Vorssaint, #102).
        guard let ink = inkBounds(of: mask ?? image), let trimmed = (mask ?? image).cropping(to: ink) else { return nil }
        let scale = CGFloat(image.width) / snap.windowFrame.width
        return Picture(
            image: trimmed,
            size: CGSize(width: CGFloat(trimmed.width) / scale, height: CGFloat(trimmed.height) / scale),
            takenAt: snap.takenAt,
            isMonochrome: mask != nil)
    }

    /// The box around the item's own ink, padded by one pixel. Ink is any
    /// pixel with alpha. A run of ink columns that touches the crop's edge
    /// and is see-through or narrow next to the widest run is a neighbour's
    /// capsule spilling over (Velja's, OpenClip's) and is left out. Nil when
    /// the picture is blank.
    private static func inkBounds(of image: CGImage) -> CGRect? {
        let w = image.width, h = image.height
        guard w > 0, h > 0, let bitmap = rgba(image, width: w, height: h) else { return nil }
        defer { withExtendedLifetime(bitmap.context) {} }
        let px = bitmap.pixels
        func alpha(_ x: Int, _ y: Int) -> Int { Int(px[(y * w + x) * 4 + 3]) }

        var runs: [ClosedRange<Int>] = []
        var start: Int?
        for x in 0...w {
            let inked = x < w && (0..<h).contains { alpha(x, $0) > 24 }
            if inked, start == nil { start = x }
            if !inked, let s = start { runs.append(s...(x - 1)); start = nil }
        }
        guard let widest = runs.map(\.count).max() else { return nil }
        let kept = runs.filter { run in
            guard runs.count > 1, run.lowerBound == 0 || run.upperBound == w - 1 else { return true }
            // A capsule's fill is see-through; a glyph has solid pixels.
            let solid = run.contains { x in (0..<h).contains { alpha(x, $0) > 160 } }
            return solid && run.count * 5 >= widest * 2
        }
        guard let minX = kept.first?.lowerBound, let maxX = kept.last?.upperBound else { return nil }
        var minY = h, maxY = -1
        for y in 0..<h where (minX...maxX).contains(where: { alpha($0, y) > 24 }) {
            minY = min(minY, y); maxY = max(maxY, y)
        }
        guard maxY >= minY else { return nil }
        let lo = max(0, minX - 1), hi = min(w - 1, maxX + 1)
        // Rows are counted from the top here; CGImage cropping is too.
        let top = max(0, minY - 1), bottom = min(h - 1, maxY + 1)
        return CGRect(x: lo, y: top, width: hi - lo + 1, height: bottom - top + 1)
    }

    /// A one-colour glyph as a white mask, or nil when it is not one: every
    /// clearly changed pixel lighter than the bar (or every one darker),
    /// barely any colour of its own (`inkTint`). Faint changes get no say: a
    /// window under the bar that gained focus since the empty bar was taken
    /// shades the bar's bottom rows a few levels, which refused a white
    /// glyph its mask (#127). Each pixel's alpha is how far it is from the bar, over how
    /// far the glyph's core is: antialiased edges come out partial, not in
    /// the bar's colour, and a grey capsule inside the frame comes out as a
    /// faint fill (one the frame cuts through drops out, `capsuleFill`).
    private static func flatMask(raw: CGImage, background: CGImage) -> CGImage? {
        let w = raw.width, h = raw.height
        // Both drawn once, for both reads.
        guard w > 0, h > 0, background.width == w, background.height == h,
              let rawBitmap = rgba(raw, width: w, height: h), let barBitmap = rgba(background, width: w, height: h)
        else { return nil }
        defer { withExtendedLifetime((rawBitmap.context, barBitmap.context)) {} }
        let s = rawBitmap.pixels, b = barBitmap.pixels
        // Measured from a capsule first. One that leaves no glyph is read
        // from the bar as before: a text widget whose strokes touch both
        // sides reads as a capsule too.
        return flatMask(s, b, width: w, height: h, fromCapsule: true)
            ?? flatMask(s, b, width: w, height: h, fromCapsule: false)
    }

    /// `s` the item as filmed, `b` the empty bar, RGBA8 of one size.
    /// `fromCapsule`: nil when the crop cuts through no capsule.
    private static func flatMask(_ s: UnsafeMutablePointer<UInt8>, _ b: UnsafeMutablePointer<UInt8>,
                                 width w: Int, height h: Int, fromCapsule: Bool) -> CGImage? {
        // A capsule the bar draws behind the item, wider than its frame
        // (Velja's and Herd's on macOS 27): measured from its fill rather
        // than the bar, the capsule drops out and the glyph is left. A
        // tinted one (over a purple wallpaper) failed the check below, and
        // the tile showed the capsule cut square at the frame (2026-10-12).
        let fill: Int?
        if fromCapsule {
            guard let found = capsuleFill(s, b, width: w, height: h) else { return nil }
            fill = found
        } else {
            fill = nil
        }
        var strong = 0, tinted = 0, lighter = 0, darker = 0
        var tintedLight = 0, tintedDark = 0
        var spread = [Int](repeating: 0, count: 256)
        for i in stride(from: 0, to: w * h * 4, by: 4) {
            guard distance(s, b, i) >= 26 else { continue }
            strong += 1
            let dl = luma(s, i) - luma(b, i)
            if dl > 0 { lighter += 1 } else if dl < 0 { darker += 1 }
            spread[min(255, abs(dl))] += 1
            if inkTint(s, b, i, sign: 1) > 60 { tintedLight += 1 }
            if inkTint(s, b, i, sign: -1) > 60 { tintedDark += 1 }
        }
        let sign = lighter * 20 >= strong * 19 ? 1 : darker * 20 >= strong * 19 ? -1 : 0
        guard sign != 0 else { return nil }
        tinted = sign > 0 ? tintedLight : tintedDark
        func base(_ i: Int) -> Int {
            guard let fill else { return luma(b, i) }
            return sign > 0 ? max(luma(b, i), fill + 4) : min(luma(b, i), fill - 4)
        }
        if fill != nil {
            strong = 0
            spread = [Int](repeating: 0, count: 256)
            for i in stride(from: 0, to: w * h * 4, by: 4) {
                let dl = (luma(s, i) - base(i)) * sign
                guard dl >= 26 else { continue }
                strong += 1
                spread[min(255, dl)] += 1
            }
        }
        guard strong > 0, fill != nil || tinted * 10 <= strong else { return nil }
        // The core's distance from the bar: the strong pixels' 90th
        // percentile, so a stray pixel does not set it.
        var seen = 0, peak = 255
        for level in 0...255 {
            seen += spread[level]
            if seen * 10 >= strong * 9 { peak = level; break }
        }
        guard peak >= 40 else { return nil }
        if fill != nil {
            // The glyph's antialiased rim is a blend with the capsule's
            // colour, tinted whenever the capsule is: only the core is
            // judged (Herd's H, a fifth of its pixels tinted, none in the core).
            var core = 0
            tinted = 0
            for i in stride(from: 0, to: w * h * 4, by: 4) where (luma(s, i) - base(i)) * sign >= peak / 2 {
                core += 1
                if chroma(s, i) > 40 { tinted += 1 }
            }
            guard tinted * 10 <= core else { return nil }
        }
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = ctx.data
        else { return nil }
        let out = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
        for i in stride(from: 0, to: w * h * 4, by: 4) {
            let dl = (luma(s, i) - base(i)) * sign
            let a = UInt8(clamping: max(0, min(255, dl * 255 / peak)))
            out[i] = a; out[i + 1] = a; out[i + 2] = a; out[i + 3] = a
        }
        return ctx.makeImage()
    }

    /// The luma of a capsule's fill when the crop cuts through one: a third
    /// or more of both side columns changed from the bar (Velja's 18pt
    /// capsule is 36 of a 39pt column's 78 rows). Their median, so the
    /// capsule's antialiased rim does not set it. Nil when either side is
    /// the bar, as it is around a glyph alone.
    private static func capsuleFill(_ s: UnsafeMutablePointer<UInt8>, _ b: UnsafeMutablePointer<UInt8>, width w: Int, height h: Int) -> Int? {
        guard w > 4 else { return nil }
        var levels: [Int] = []
        for x in [1, w - 2] {
            let column = (0..<h).map { ($0 * w + x) * 4 }.filter { distance(s, b, $0) >= 26 }
            guard column.count * 3 >= h else { return nil }
            levels += column.map { luma(s, $0) }
        }
        return levels.sorted()[levels.count / 2]
    }

    private static func luma(_ p: UnsafeMutablePointer<UInt8>, _ i: Int) -> Int {
        (Int(p[i]) * 3 + Int(p[i + 1]) * 6 + Int(p[i + 2])) / 10
    }

    /// How far pixel `i` is from plain ink over the bar, 0 when it is white
    /// (`sign` > 0) or black ink at some alpha: the spread of the alpha each
    /// channel gives. Measured on its own colour, Wi-Fi's dim arcs over a
    /// purple bar read tinted, the glyph failed the check and its tile kept
    /// the bar's purple; un-blended they spread 3 at most, a red or blue
    /// glyph 170 and up (2026-10-12). A channel the bar already holds near
    /// the ink's end says nothing and is left out.
    private static func inkTint(_ s: UnsafeMutablePointer<UInt8>, _ b: UnsafeMutablePointer<UInt8>, _ i: Int, sign: Int) -> Int {
        var lo = Int.max, hi = Int.min
        for c in 0..<3 {
            let pixel = Int(s[i + c]), bar = Int(b[i + c])
            let room = sign > 0 ? 255 - bar : bar
            guard room >= 24 else { continue }
            let alpha = (sign > 0 ? pixel - bar : bar - pixel) * 255 / room
            lo = min(lo, alpha); hi = max(hi, alpha)
        }
        return hi >= lo ? hi - lo : 0
    }

    private static func chroma(_ p: UnsafeMutablePointer<UInt8>, _ i: Int) -> Int {
        Int(max(p[i], p[i + 1], p[i + 2])) - Int(min(p[i], p[i + 1], p[i + 2]))
    }

    /// The largest channel difference of pixel `i` between two bitmaps.
    static func distance(_ s: UnsafeMutablePointer<UInt8>, _ b: UnsafeMutablePointer<UInt8>, _ i: Int) -> Int {
        max(abs(Int(s[i]) - Int(b[i])), abs(Int(s[i + 1]) - Int(b[i + 1])), abs(Int(s[i + 2]) - Int(b[i + 2])))
    }

    typealias Bitmap = (context: CGContext, pixels: UnsafeMutablePointer<UInt8>)

    /// RGBA8 premultiplied, top row first. The context owns the pixels:
    /// keep it while reading them. The pass's film compares its frames with
    /// it too; the cover's cut-out keeps its own (BGRA, sRGB, top-anchored).
    static func rgba(_ image: CGImage, width w: Int, height h: Int) -> Bitmap? {
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = ctx.data
        else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return (ctx, data.bindMemory(to: UInt8.self, capacity: w * h * 4))
    }
}
