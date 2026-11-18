import CoreGraphics
import Testing
@testable import PelmetCore

@Suite struct FrameMemoryTests {
    let chevron = ItemID(rawValue: "status:app.fif7y.Pelmet::Pelmet.StatusItem")
    let sound = ItemID(rawValue: "status:com.apple.MenuBarAgent::com.apple.menuextra.sound")
    let snib = ItemID.bundleKey("app.fif7y.Snib")
    let a = ItemID.bundleKey("com.a"), v1 = ItemID.bundleKey("com.v1")
    var roster: Roster { Roster(members: [a: .hidden, snib: .hidden, sound: .hidden]) }
    var hidden: Set<ItemID> { [a, snib, sound] }

    func frame(_ x: CGFloat) -> CGRect { CGRect(x: x, y: 0, width: 20, height: 24) }
    var live: [ItemID: CGRect] { [chevron: frame(200), v1: frame(230)] }

    /// The collapsed bar as the count and the settle read it: live frames,
    /// plus the remembered frame of each concealed icon.
    func bar(_ memory: FrameMemory) -> [ItemID] {
        let concealed = memory.frames.filter { hidden.contains($0.key) }
        return live.merging(concealed) { now, _ in now }.sorted { $0.value.minX < $1.value.minX }.map(\.key)
    }

    func count(_ edits: OrderEdits, bar: [ItemID]) -> Int {
        let plan = MovePlan.compute(bar: bar, edits: edits, roster: roster, chevron: chevron)
        return ApplyCount.count(
            plan, edits: edits, trapped: [], drawn: { _ in false }, concealed: { hidden.contains($0) }
        ).total
    }

    @Test func aRealReorderAfterAPassStaysPendingAndCounts() {
        // Hidden last read at rest as a, Snib, Sound. A pass then dragged
        // Snib while Hidden stayed concealed, so the bar is a, Sound, Snib
        // and nothing re-read it. Sound dropped after Snib is a real move.
        var memory = FrameMemory()
        memory.remember(
            [a: frame(100), snib: frame(130), sound: frame(160)].merging(live) { $1 },
            chevronMidX: 210, atRest: true
        )
        let edits = OrderEdits(
            order: [.hidden: [a, snib, sound]], previousOrder: [.hidden: [a, sound, snib]], dropped: [sound]
        )
        // Kept, the stale frames match the drawing in full: the settle
        // cleared the real edit at the drop, and Apply went dark (review,
        // 2026-10-13).
        #expect(OrderEditSettle.settledSections(
            edits, bar: bar(memory), live: Set(live.keys), concealed: hidden, roster: roster
        ) == [.hidden])
        // The walk after the drags reads Visible only: Hidden's frames go.
        #expect(memory.forget(allBut: Set(live.keys)) == hidden)
        #expect(bar(memory) == [chevron, v1])
        let settled = OrderEditSettle.settledSections(
            edits, bar: bar(memory), live: Set(live.keys), concealed: hidden, roster: roster
        )
        #expect(settled.isEmpty)
        #expect(count(edits, bar: bar(memory)) == 1)
        // Drawn back instead, it is no edit, frames or not.
        var back = OrderEdits(
            order: [.hidden: [a, sound, snib]], previousOrder: [.hidden: [a, sound, snib]], dropped: [sound]
        )
        let backSettled = OrderEditSettle.settledSections(
            back, bar: bar(memory), live: Set(live.keys), concealed: hidden, roster: roster
        )
        #expect(backSettled == [.hidden])
        for section in backSettled { back.clearOrder(for: section) }
        #expect(count(back, bar: bar(memory)) == 0)
    }

    @Test func aForgottenFrameComesBackOnlyFromAWalkAtRest() {
        var memory = FrameMemory()
        memory.remember([a: frame(100), snib: frame(130)], chevronMidX: 210, atRest: true)
        memory.forget(allBut: [])
        #expect(memory.frames.isEmpty && memory.chevronMidX.isEmpty)
        // Mid-reveal, the walk reads the strip a part at a time.
        memory.remember([a: frame(90), snib: frame(140)], chevronMidX: 210, atRest: false)
        #expect(memory.frames.isEmpty)
        memory.remember([a: frame(100), snib: frame(150)], chevronMidX: 210, atRest: true)
        #expect(memory.frames == [a: frame(100), snib: frame(150)])
        #expect(memory.awaitingRest.isEmpty)
        // An icon no pass made stale is remembered from any walk, as before.
        memory.remember([sound: frame(170)], chevronMidX: 210, atRest: false)
        #expect(memory.frames[sound] == frame(170))
    }

    @Test func whatTheWalkAfterThePassReadsIsKept() {
        // Hidden out for the pass: the walk after the drags reads it all.
        var memory = FrameMemory()
        memory.remember([a: frame(100), snib: frame(130), sound: frame(160)], chevronMidX: 210, atRest: true)
        memory.remember([a: frame(100), sound: frame(130), snib: frame(160)], chevronMidX: 210, atRest: true)
        #expect(memory.forget(allBut: hidden).isEmpty)
        #expect(memory.frames[snib] == frame(160) && memory.chevronMidX[snib] == 210)
    }

    @Test func alwaysHiddenKeepsLeftOfHiddenButAStrayKeepsItsSide() {
        let velja = ItemID.bundleKey("com.sindresorhus.Velja")
        let battery = ItemID(rawValue: "status:com.apple.MenuBarAgent::com.apple.menuextra.battery")
        // Velja remembered inside Hidden (left edge 100), Battery right of
        // the chevron (midX 210): Velja moves left of Hidden, Battery stays.
        let frames = [velja: frame(110), battery: frame(240), snib: frame(100)]
        let out = FrameMemory.alwaysHiddenLeftOfHidden(
            frames, alwaysHidden: [velja, battery], hiddenLeft: 100, chevronMidX: 210
        )
        #expect(out[velja] == frame(80))
        #expect(out[battery] == frame(240))
        #expect(out[snib] == frame(100))
        // Battery alone set the group's right edge before: Velja went 140pt
        // further left and Battery read in place.
        let group = FrameMemory.alwaysHiddenLeftOfHidden(
            frames, alwaysHidden: [velja, battery], hiddenLeft: 100, chevronMidX: nil
        )
        #expect(group[battery] == frame(100 - 20) && group[velja] == frame(110 - 160))
    }

    // MARK: Always Hidden out alone (#149)

    /// The bar of 2026-11-17 20:56:16: Always Hidden out by a middle click,
    /// Hidden concealed and read from memory, three icons each.
    @Test func alwaysHiddenOutAloneKeepsLeftOfTheHiddenItCovers() {
        let wifi = ItemID(rawValue: "status:com.apple.MenuBarAgent::com.apple.menuextra.wifi")
        let sconce = ItemID.bundleKey("com.gab.Sconce")
        let battery = ItemID(rawValue: "status:com.apple.MenuBarAgent::com.apple.menuextra.battery")
        let bitwarden = ItemID.bundleKey("com.bitwarden.desktop")
        let vorssaint = ItemID.bundleKey("com.vorssaint.utils")
        let chevron = self.chevron
        let section: (ItemID) -> PelmetCore.Section = {
            [wifi, sconce, battery].contains($0) ? .alwaysHidden : $0 == chevron ? .visible : .hidden
        }
        func f(_ x: CGFloat, _ w: CGFloat) -> CGRect { CGRect(x: x, y: 0, width: w, height: 24) }
        let frames = [
            wifi: f(1421, 22), sconce: f(1451, 38), battery: f(1497, 26), chevron: f(1531, 38),
            bitwarden: f(1306, 32), vorssaint: f(1418, 42), snib: f(1460, 33),
        ]
        func order(_ frames: [ItemID: CGRect]) -> [ItemID] { frames.sorted { $0.value.minX < $1.value.minX }.map(\.key) }
        // Read as they are, Vorssaint and Snib land among Always Hidden.
        #expect(order(frames) == [bitwarden, vorssaint, wifi, sconce, snib, battery, chevron])

        let apart = FrameMemory.alwaysHiddenApart(
            in: frames, remembered: [], concealed: [bitwarden, vorssaint, snib], section: section
        )
        #expect(apart == [wifi, sconce, battery])
        let out = FrameMemory.alwaysHiddenLeftOfHidden(frames, alwaysHidden: apart, hiddenLeft: 1306, chevronMidX: 1550)
        #expect(order(out) == [wifi, sconce, battery, bitwarden, vorssaint, snib, chevron])
    }

    /// With Hidden on the bar too it is one reading: an Always Hidden icon
    /// among Hidden's is drift, and stays where it reads.
    @Test func alwaysHiddenBesideHiddenOnTheBarIsReadAsItIs() {
        let velja = ItemID.bundleKey("com.sindresorhus.Velja")
        let section: (ItemID) -> PelmetCore.Section = { $0 == velja ? .alwaysHidden : .hidden }
        let frames = [a: frame(100), velja: frame(130), snib: frame(160)]
        #expect(FrameMemory.alwaysHiddenApart(in: frames, remembered: [], concealed: [], section: section).isEmpty)
        #expect(FrameMemory.alwaysHiddenApart(in: frames, remembered: [], concealed: [velja], section: section).isEmpty)
    }

    @Test func anIconRememberedRightOfTheChevronIsNamed() {
        // #157: Apple's Siri is in Hidden and macOS keeps it right of the
        // chevron. Revealed, the bar read a, Snib, «, v1, Siri.
        let siri = ItemID.bundleKey("com.apple.systemuiserver")
        var memory = FrameMemory()
        memory.remember(
            [a: frame(100), snib: frame(130), chevron: frame(200), v1: frame(230), siri: frame(260)],
            chevronMidX: 210, atRest: true
        )
        #expect(memory.rightOfChevron(among: [a, snib, siri]) == [siri])
        // Only the icons asked about: v1 is right of it too, and visible.
        #expect(memory.rightOfChevron(among: [a, snib]) == [])
    }

    @Test func anIconNeverReadIsNotCalledRightOfTheChevron() {
        // No frame, or a frame read with no chevron on the bar and none
        // now: unknown, and a reveal keeps its pictures.
        var memory = FrameMemory()
        memory.remember([a: frame(260)], chevronMidX: nil, atRest: true)
        #expect(memory.rightOfChevron(among: [a, snib]) == [])
    }

    @Test func aFrameReadWithNoChevronIsJudgedAgainstTheConcealedBars() {
        // The launch walk read every icon out and no chevron (it sat behind
        // macOS's own «). Concealed, the chevron stands at 200…220: Control
        // Center at 230 is past it, Snib at 130 is not, and an icon on the
        // chevron's own spot (a glyphless chevron reads there) is not.
        let center = ItemID(rawValue: "status:com.apple.MenuBarAgent::com.apple.menuextra.controlcenter")
        var memory = FrameMemory()
        memory.remember([snib: frame(130), a: frame(195), center: frame(230)], chevronMidX: nil, atRest: true)
        #expect(memory.rightOfChevron(among: [snib, a, center], chevronNow: frame(200)) == [center])
        // Read again with the chevron on the bar, that reading decides.
        memory.remember([center: frame(230)], chevronMidX: 250, atRest: true)
        #expect(memory.rightOfChevron(among: [center], chevronNow: frame(200)) == [])
    }

    @Test func anIconNotReadSinceLaunchIsJudgedByItsLaunchFrame() {
        // First reveal of a launch: nothing read Control Center in its slot
        // yet, the launch walk's frame is all there is.
        let center = ItemID(rawValue: "status:com.apple.MenuBarAgent::com.apple.menuextra.controlcenter")
        let launch = [snib: frame(130), center: frame(230)]
        let memory = FrameMemory()
        #expect(memory.rightOfChevron(among: [snib, center], chevronNow: frame(200), launchFrames: launch) == [center])
        #expect(memory.rightOfChevron(among: [snib, center], launchFrames: launch) == [])
        // Once the bar has read it beside the chevron, the launch frame is not asked.
        var read = FrameMemory()
        read.remember([center: frame(150)], chevronMidX: 210, atRest: true)
        #expect(read.rightOfChevron(among: [center], chevronNow: frame(200), launchFrames: launch) == [])
    }

    @Test func anIconDraggedBackLeftOfTheChevronIsNoLongerNamed() {
        var memory = FrameMemory()
        memory.remember([a: frame(260)], chevronMidX: 210, atRest: true)
        #expect(memory.rightOfChevron(among: [a]) == [a])
        memory.remember([a: frame(100)], chevronMidX: 210, atRest: true)
        #expect(memory.rightOfChevron(among: [a]) == [])
    }
}
