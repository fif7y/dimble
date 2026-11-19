// PillMatch.swift
// Which mirror a pill found on the bar belongs to, and when a pill's read is
// fit to draw. Two games in Apple's Sports app are both "Sports" in AX, with
// the same identifier, so keys in bar order ("Sports", "Sports #2") were the
// only identity, and a discovery that missed one of the two handed the other
// game's pill to the "Sports" mirror: it showed Wizards 9 Raptors 5 where
// Canadiens 0 Devils 0 stood (2026-11-18 19:48:59, Gab: "displaying others
// numbers"). And macOS animates a pill when its content changes, its logos
// and numbers sliding: a read taken half-way put the numbers outside the
// pill and the mirror's width jumping from 68 to 178 pt and back.

import Foundation

public enum PillMatch {
    /// A pill as a discovery found it, in bar order.
    public struct Found: Equatable, Sendable {
        public var name: String
        public var text: String
        public var midX: Double
        /// The held mirror whose AX element this very element is, if any.
        public var same: Int?
        public init(name: String, text: String, midX: Double, same: Int? = nil) {
            self.name = name; self.text = text; self.midX = midX; self.same = same
        }
    }

    /// A mirror already held, with the copy it last took.
    public struct Held: Equatable, Sendable {
        public var name: String
        public var text: String
        public var midX: Double
        public init(name: String, text: String, midX: Double) {
            self.name = name; self.text = text; self.midX = midX
        }
    }

    /// The letters of a pill's text, lowercased: what stays while its numbers
    /// move ("Wizards 18 Raptors 15" → "wizardsraptors"). Empty for a timer.
    public static func words(_ text: String) -> String {
        String(text.lowercased().filter(\.isLetter))
    }

    /// For each found pill, the index in `held` of the mirror it is, or nil
    /// for a pill no mirror has. First the same AX element; then the same
    /// words, when they tell one pill of that name from the others; then
    /// the rest of each name in bar order when every one of them is there,
    /// and nearest to where each mirror's pill last stood when some are not.
    public static func assign(_ found: [Found], to held: [Held]) -> [Int?] {
        var out = [Int?](repeating: nil, count: found.count)
        var taken = Set<Int>()
        func take(_ f: Int, _ h: Int) { out[f] = h; taken.insert(h) }
        for (f, pill) in found.enumerated() {
            if let h = pill.same, held.indices.contains(h), !taken.contains(h), held[h].name == pill.name { take(f, h) }
        }
        for (f, pill) in found.enumerated() where out[f] == nil {
            let w = words(pill.text)
            guard !w.isEmpty else { continue }
            let mirrors = held.indices.filter { !taken.contains($0) && held[$0].name == pill.name && words(held[$0].text) == w }
            let pills = found.indices.filter { out[$0] == nil && found[$0].name == pill.name && words(found[$0].text) == w }
            if mirrors.count == 1, pills.count == 1 { take(f, mirrors[0]) }
        }
        var names: [String] = []
        for pill in found where !names.contains(pill.name) { names.append(pill.name) }
        for name in names {
            let pills = found.indices.filter { out[$0] == nil && found[$0].name == name }
            let mirrors = held.indices.filter { !taken.contains($0) && held[$0].name == name }.sorted { held[$0].midX < held[$1].midX }
            if pills.count == mirrors.count {
                for (f, h) in zip(pills, mirrors) { take(f, h) }
                continue
            }
            let pairs = pills.flatMap { f in mirrors.map { h in (f: f, h: h, d: abs(found[f].midX - held[h].midX)) } }
                .sorted { $0.d < $1.d }
            for pair in pairs where out[pair.f] == nil && !taken.contains(pair.h) { take(pair.f, pair.h) }
        }
        return out
    }

    /// The key of a new mirror for `name`: the name when no mirror has it,
    /// else " #2", " #3"… (`PillKeys`' shape, so a card's owner still finds it).
    public static func newKey(_ name: String, taken: Set<String>) -> String {
        guard taken.contains(name) else { return name }
        var n = 2
        while taken.contains("\(name) #\(n)") { n += 1 }
        return "\(name) #\(n)"
    }
}

/// When a pill's read is drawn: once its shape (its frame and where its texts
/// sit) stands still. A read like the last one drawn is drawn at once; a new
/// shape waits until a second read `settle` later agrees, so a pill caught
/// mid-slide is never drawn. One that keeps moving for `giveUp` is drawn
/// anyway, the read in hand, and waits again from there.
public struct PillSettle: Equatable, Sendable {
    /// The shape last drawn.
    public private(set) var drawn: [Double]?
    /// A shape not drawn yet, first read at `since`; `first` is when the
    /// pill began to move.
    public private(set) var waiting: [Double]?
    public private(set) var since: Date?
    public private(set) var first: Date?

    public init() {}

    /// Waiting for a pill to stand still: it is read every tick meanwhile.
    public var moving: Bool { waiting != nil }

    public static func alike(_ a: [Double], _ b: [Double]) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { abs($0 - $1) < 1 }
    }

    /// Whether the read with this shape is drawn.
    public mutating func read(_ shape: [Double], now: Date, settle: TimeInterval = 0.2, giveUp: TimeInterval = 2) -> Bool {
        guard let drawn, !Self.alike(shape, drawn) else { return draw(shape) }
        let start = first ?? now
        if now.timeIntervalSince(start) >= giveUp { return draw(shape) }
        if let waiting, let since, Self.alike(shape, waiting) {
            return now.timeIntervalSince(since) >= settle ? draw(shape) : false
        }
        waiting = shape; since = now; first = start
        return false
    }

    private mutating func draw(_ shape: [Double]) -> Bool {
        drawn = shape; waiting = nil; since = nil; first = nil
        return true
    }
}
