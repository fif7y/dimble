// LiveActivityLogParserTests.swift
// Fixtures follow MenuBarAgent's `liveActivities` lines from macOS 27.2
// (2026-10-27, an activity mirrored from the iPhone), with the app and the
// ids swapped for made-up ones. The descriptor line is cut at os_log's 1 KB
// exactly where the real one was, before the activity's state.

import Foundation
import Testing
@testable import PelmetCore

struct LiveActivityLogParserTests {
    static let uuid = "A1B2C3D4-5E6F-4A1B-8C2D-3E4F5A6B7C8D"
    static let descriptor = #"Received live activity descriptor states: [MenuBarCore.LiveActivityElementObserver.(unknown context at $104a3408c).ObservedActivityState(descriptorState: ActivityKit.ActivityDescriptorState(descriptor: ActivityKit.ActivityDescriptor(id: "A1B2C3D4-5E6F-4A1B-8C2D-3E4F5A6B7C8D", attributesType: Attributes type: RemoteStartAttributes, attributesData: 125 bytes, requester: com.example.orders, sceneTargets: [lockscreen: widget(containingProcess: com.example.orders)], alertSceneTargets: [:], contentSources: [push(pushType: token(environment: "production"), topic: com.example.orders), process(com.example.orders), sync], presentationOptions: ["Destinations: [ambient, banner, lockscreen, systemAperture]", "User dismissal allowed: true", "Should suppress system aperture content on lock screen: true", "Should suppress alert content on host application: true", "Platter tint color: nil", "Authorization options type: No Options", "Action Button Initiated: false", "Should Show System Aperture: false"], isEphemeral: false, isMomen<…>"#
    static let created = "Create client element for Live Activity: A1B2C3D4"
    static let notShown = "Not showing remote live activity from com.example.orders: remoteLiveActivitiesEnabled=true, companionDeviceSupportsLiveActivities=true, isAllowed=true, state=dismissed"
    static let departed = "Keeping departed live activity alive: \(uuid)"
    static let released = "Releasing kept-alive live activity: \(uuid)"
    static let scene = "ComponentSceneID(9F0E1D2C): Creating server scene for Live Activity A1B2C3D4, role: compactLeading"

    static let agent: Int32 = 501
    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    /// Reads `lines` in order at `date`; whether each changed the set.
    private static func read(_ lines: [String], into activities: inout LiveActivities, at date: Date = t0, agent: Int32 = agent) -> [Bool] {
        lines.map { activities.read($0, at: date, agent: agent) }
    }

    @Test func aStartNamesTheAppFromTheDescriptorJustBeforeIt() {
        var activities = LiveActivities()
        let changed = Self.read([Self.descriptor, Self.created], into: &activities)
        #expect(changed == [false, true])
        // The real line's sceneTargets name the widget's process too.
        #expect(activities.active == [LiveActivity(id: "A1B2C3D4", bundleID: "com.example.orders",
                                                  hostBundleID: "com.example.orders", startedAt: Self.t0, agent: Self.agent)])
    }

    @Test func theEndLinesTakeItAwayByID() {
        var activities = LiveActivities()
        _ = Self.read([Self.descriptor, Self.created], into: &activities)
        // The end's descriptor copy reads like the start's, and the
        // dismissal names the app only: the per-id lines end it.
        let changed = Self.read([Self.descriptor, Self.notShown, Self.departed, Self.released], into: &activities, at: Self.t0.addingTimeInterval(3000))
        #expect(changed == [false, false, true, false])
        #expect(activities.active.isEmpty)
    }

    @Test func theReleaseAloneEndsItToo() {
        var activities = LiveActivities()
        let changed = Self.read([Self.created, Self.released], into: &activities)
        #expect(changed == [true, true])
        #expect(activities.active.isEmpty)
    }

    /// The app's debug activity (`pelmet.debug.fakeLiveActivity`) starts
    /// through the same reading as a real one.
    @Test func theDebugStartLinesStartOneOfThatApp() {
        var activities = LiveActivities()
        let changed = Self.read(LiveActivities.startLines(id: Self.uuid, requester: "com.example.car"), into: &activities)
        #expect(changed == [false, true])
        #expect(activities.active == [LiveActivity(id: "A1B2C3D4", bundleID: "com.example.car", startedAt: Self.t0, agent: Self.agent)])
        // And ends like one.
        _ = Self.read([Self.released], into: &activities)
        #expect(activities.active.isEmpty)
    }

    @Test func aLaterDescriptorNamesAnActivityStartedWithoutOne() {
        var activities = LiveActivities()
        _ = Self.read([Self.created], into: &activities)
        #expect(activities.latest?.bundleID == nil)
        let changed = Self.read([Self.descriptor], into: &activities)
        #expect(changed == [true])
        #expect(activities.latest?.bundleID == "com.example.orders")
    }

    @Test func aStartSeenTwiceIsOneActivity() {
        var activities = LiveActivities()
        let changed = Self.read([Self.created, Self.created], into: &activities)
        #expect(changed == [true, false])
        #expect(activities.active.count == 1)
    }

    @Test func sceneChatterIsNotOurs() {
        var activities = LiveActivities()
        let changed = Self.read([Self.scene], into: &activities)
        #expect(changed == [false])
        #expect(activities.active.isEmpty)
    }

    @Test func aDescriptorCutBeforeItsRequesterNamesNoApp() {
        let second = #", ObservedActivityState(descriptorState: ActivityKit.ActivityDescriptorState(descriptor: ActivityKit.ActivityDescriptor(id: "0F1E2D3C-0000-4000-8000-000000000002", attributesType: Attri<…>"#
        let found = LiveActivities.requesters(in: Self.descriptor.replacingOccurrences(of: "isMomen<…>", with: "") + second)
        #expect(found.map(\.id) == ["A1B2C3D4"])
        #expect(found.map(\.bundle) == ["com.example.orders"])
    }

    @Test func twoActivitiesShowTheLatest() {
        var activities = LiveActivities()
        _ = Self.read([Self.descriptor, Self.created], into: &activities)
        _ = Self.read(["Create client element for Live Activity: 0F1E2D3C"], into: &activities, at: Self.t0.addingTimeInterval(60))
        #expect(activities.active.map(\.id) == ["A1B2C3D4", "0F1E2D3C"])
        #expect(activities.latest?.id == "0F1E2D3C")
    }

    @Test func aRefusalTakesThatAppsActivitiesAway() {
        var activities = LiveActivities()
        _ = Self.read([Self.descriptor, Self.created], into: &activities)
        let refused = "Not showing remote live activity from com.example.orders: remoteLiveActivitiesEnabled=false, companionDeviceSupportsLiveActivities=true, isAllowed=true, state=active"
        let changed = Self.read([refused], into: &activities)
        #expect(changed == [true])
        #expect(activities.active.isEmpty)
    }

    @Test func aNewAgentDropsWhatTheOldOneAnnounced() {
        var activities = LiveActivities()
        _ = Self.read([Self.created], into: &activities)
        let restarted = Self.agent + 1
        let changed = Self.read(["Create client element for Live Activity: 0F1E2D3C"], into: &activities, agent: restarted)
        #expect(changed == [true])
        #expect(activities.active.map(\.id) == ["0F1E2D3C"])
        #expect(activities.active.first?.agent == restarted)
    }

    @Test func pruneLetsGoPastTheLifetimeAndOfAGoneAgent() {
        var activities = LiveActivities()
        _ = Self.read([Self.created], into: &activities)
        #expect(activities.nextExpiry == Self.t0.addingTimeInterval(LiveActivities.lifetime))
        let early = activities.prune(now: Self.t0.addingTimeInterval(LiveActivities.lifetime - 1), agent: Self.agent)
        let unknownAgent = activities.prune(now: Self.t0, agent: nil)
        let late = activities.prune(now: Self.t0.addingTimeInterval(LiveActivities.lifetime), agent: Self.agent)
        #expect([early, unknownAgent, late] == [false, false, true])
        #expect(activities.active.isEmpty)
        #expect(activities.nextExpiry == nil)

        _ = Self.read([Self.created], into: &activities)
        let gone = activities.prune(now: Self.t0, agent: Self.agent + 1)
        #expect(gone)
        #expect(activities.active.isEmpty)
    }

    @Test func endIDsAreCutToTheStartLinesEightDigits() {
        #expect(LiveActivities.id(after: LiveActivities.departedPrefix, in: Self.departed) == "A1B2C3D4")
        #expect(LiveActivities.id(after: LiveActivities.createdPrefix, in: "Create client element for Live Activity: a1b2c3d4") == "A1B2C3D4")
        #expect(LiveActivities.id(after: LiveActivities.createdPrefix, in: "Create client element for Live Activity: ") == nil)
    }

    // MARK: Across launches

    private static func saved(_ lines: [String], at date: Date = t0) -> LiveActivities.Saved {
        var seen = LiveActivities()
        _ = read(lines, into: &seen, at: date)
        return seen.saved
    }

    @Test func anEndOnlyTheLastLaunchSawHolds() {
        // The stream delivered the end, the replay of the log doesn't have it.
        let lastLaunch = Self.saved([Self.created, Self.departed])
        var replay = LiveActivities()
        _ = Self.read([Self.created], into: &replay, at: Self.t0)
        replay.merge(lastLaunch)
        #expect(replay.active.isEmpty)
    }

    @Test func aStartOnlyTheLastLaunchSawHolds() {
        var replay = LiveActivities()
        replay.merge(Self.saved([Self.descriptor, Self.created]))
        #expect(replay.active.map(\.id) == ["A1B2C3D4"])
        #expect(replay.active[0].bundleID == "com.example.orders")
        #expect(replay.active[0].fromBefore)
    }

    @Test func anEndOnlyTheLogHasHolds() {
        // Dimble was quit when it ended.
        let lastLaunch = Self.saved([Self.created])
        var replay = LiveActivities()
        _ = Self.read([Self.created], into: &replay, at: Self.t0)
        _ = Self.read([Self.departed], into: &replay, at: Self.t0.addingTimeInterval(60))
        replay.merge(lastLaunch)
        #expect(replay.active.isEmpty)
    }

    @Test func aStartAfterTheLastEndIsANewRun() {
        let lastLaunch = Self.saved([Self.created, Self.departed])
        var replay = LiveActivities()
        _ = Self.read([Self.created], into: &replay, at: Self.t0.addingTimeInterval(60))
        replay.merge(lastLaunch)
        #expect(replay.active.map(\.id) == ["A1B2C3D4"])
    }

    @Test func aNewerRunTheLastLaunchSawBeatsTheReplaysOlderOne() {
        // The agent restarted during a quarantine: the replay only has the first run.
        var lastLaunch = LiveActivities()
        _ = Self.read([Self.created], into: &lastLaunch, at: Self.t0.addingTimeInterval(3600), agent: Self.agent + 1)
        var replay = LiveActivities()
        _ = Self.read([Self.created], into: &replay, at: Self.t0)
        replay.merge(lastLaunch.saved)
        #expect(replay.active.map(\.startedAt) == [Self.t0.addingTimeInterval(3600)])
        let dropped = replay.prune(now: Self.t0.addingTimeInterval(3600), agent: Self.agent + 1)
        #expect(!dropped)
        #expect(replay.active.map(\.id) == ["A1B2C3D4"])
    }

    @Test func anActivityTheLastAgentAnnouncedDoesNotComeBack() {
        var replay = LiveActivities()
        replay.merge(Self.saved([Self.created]))
        let dropped = replay.prune(now: Self.t0, agent: Self.agent + 1)
        #expect(dropped)
        #expect(replay.active.isEmpty)
    }

    @Test func noPillDropsOnlyWhatCameFromBefore() {
        var activities = LiveActivities()
        activities.merge(Self.saved([Self.created]))
        let newOne = "Create client element for Live Activity: B1B2C3D4"
        _ = Self.read([newOne], into: &activities, at: Self.t0.addingTimeInterval(60))
        let first = activities.dropFromBefore()
        #expect(first)
        #expect(activities.active.map(\.id) == ["B1B2C3D4"])
        let second = activities.dropFromBefore()
        #expect(!second)
        // Not an end: the next launch can ask the bar again.
        #expect(activities.ended["A1B2C3D4"] == nil)
    }

    @Test func theAgentAnnouncingOneAgainClearsItsDoubt() {
        var activities = LiveActivities()
        activities.merge(Self.saved([Self.created]))
        _ = Self.read([Self.created], into: &activities, at: Self.t0.addingTimeInterval(60))
        #expect(!activities.active[0].fromBefore)
        let dropped = activities.dropFromBefore()
        #expect(!dropped)
    }

    @Test func oldEndsAreForgotten() {
        var activities = LiveActivities()
        _ = Self.read([Self.created, Self.departed], into: &activities)
        activities.prune(now: Self.t0.addingTimeInterval(LiveActivities.lifetime), agent: Self.agent)
        #expect(activities.ended.isEmpty)
    }

    /// Two slots, newest first (the live run of 2026-11-07: a Sports
    /// activity and three Shortcuts runs, Sports evicted every time).
    @Test func theNewestTwoAreTheOnesTheBarShows() {
        var activities = LiveActivities()
        for (index, id) in ["AAAA1111", "BBBB2222", "CCCC3333", "DDDD4444"].enumerated() {
            _ = Self.read(["Create client element for Live Activity: \(id)"],
                          into: &activities, at: Self.t0.addingTimeInterval(Double(index)))
        }
        let split = activities.slotted(avPill: false)
        #expect(split.onBar.map(\.id) == ["DDDD4444", "CCCC3333"])
        #expect(split.hidden.map(\.id) == ["BBBB2222", "AAAA1111"])
    }

    /// Apple's camera and mic pill takes one of the two
    /// ("evicting liveActivity(D52BA810) for better-ranked avModule(…)").
    @Test func theCameraPillTakesASlotFromTheActivities() {
        var activities = LiveActivities()
        for (index, id) in ["AAAA1111", "BBBB2222"].enumerated() {
            _ = Self.read(["Create client element for Live Activity: \(id)"],
                          into: &activities, at: Self.t0.addingTimeInterval(Double(index)))
        }
        let split = activities.slotted(avPill: true)
        #expect(split.onBar.map(\.id) == ["BBBB2222"])
        #expect(split.hidden.map(\.id) == ["AAAA1111"])
    }

    @Test func nothingRunningSplitsIntoNothing() {
        let split = LiveActivities().slotted(avPill: false)
        #expect(split.onBar.isEmpty && split.hidden.isEmpty)
    }

    /// The Shortcuts run indicator asks as a service no Mac has an app for,
    /// and names the app it belongs to in the same descriptor (27.3,
    /// 2026-11-07).
    @Test func theDescriptorNamesTheProcessTheWidgetLivesIn() {
        var activities = LiveActivities()
        let descriptor = #"Received live activity descriptor states: [ActivityKit.ActivityDescriptor(id: "A1B2C3D4-5E6F-4A1B-8C2D-3E4F5A6B7C8D", attributesType: Attributes type: ShortcutLiveActivityAttributes, requester: com.example.orders.ViewService, sceneTargets: [lockscreen: widget(containingProcess: com.example.orders)], isEphemeral: false)]"#
        _ = Self.read([descriptor, Self.created], into: &activities)
        #expect(activities.active.first?.bundleID == "com.example.orders.ViewService")
        #expect(activities.active.first?.hostBundleID == "com.example.orders")
    }

    /// One pill, one activity nothing names: they can only be each other.
    @Test func theOnlyPillNamesTheOnlyActivityWithoutAName() {
        let learned = LiveActivities.pairNames(pills: ["Sports"], onBar: [(bundle: "com.example.sports", known: nil)])
        #expect(learned.map(\.name) == ["Sports"])
        #expect(learned.map(\.bundle) == ["com.example.sports"])
    }

    /// A pill the Mac can already name is claimed by its own activity, and
    /// what is left over is the pair.
    @Test func aKnownPillIsClaimedBeforeTheLeftoverIsPaired() {
        let learned = LiveActivities.pairNames(
            pills: ["Shortcuts", "myVW"],
            onBar: [(bundle: "com.example.shortcuts", known: "Shortcuts"), (bundle: "com.example.car", known: nil)])
        #expect(learned.map(\.name) == ["myVW"])
        #expect(learned.map(\.bundle) == ["com.example.car"])
    }

    /// Two that nothing names: either pill could be either activity, so
    /// neither is learned.
    @Test func twoUnnamedActivitiesLearnNothing() {
        let learned = LiveActivities.pairNames(
            pills: ["Sports", "myVW"],
            onBar: [(bundle: "com.example.sports", known: nil), (bundle: "com.example.car", known: nil)])
        #expect(learned.isEmpty)
    }

    @Test func savedStateSurvivesCoding() throws {
        let saved = Self.saved([Self.descriptor, Self.created])
        let data = try JSONEncoder().encode(saved)
        #expect(try JSONDecoder().decode(LiveActivities.Saved.self, from: data) == saved)
    }
}

/// Two activities of one app share an AX description, and the press used to
/// take the first of them whichever pill was clicked (fif7y/dimble).
@Suite struct PillKeysTests {
    @Test func secondPillOfOneAppGetsASuffix() {
        #expect(PillKeys.keys(for: ["Sports", "Sports"]) == ["Sports", "Sports #2"])
        #expect(PillKeys.keys(for: ["Sports", "myVW", "Sports"]) == ["Sports", "myVW", "Sports #2"])
        #expect(PillKeys.keys(for: ["Sports", "Sports", "Sports"]) == ["Sports", "Sports #2", "Sports #3"])
    }

    @Test func aKeyFindsItsOwnPillNotTheFirstOfThatName() {
        let names = ["Sports", "Sports"]
        #expect(PillKeys.index(of: "Sports #2", in: names) == 1)
        #expect(PillKeys.index(of: "Sports", in: names) == 0)
    }

    @Test func aBareDescriptionStillFindsTheFirstOfThatName() {
        // What an open card reports as its owner is the description alone.
        #expect(PillKeys.index(of: "myVW", in: ["Sports", "myVW", "Sports"]) == 1)
        #expect(PillKeys.index(of: "Sports #3", in: ["Sports", "myVW", "Sports"]) == nil)
        #expect(PillKeys.index(of: "Timer", in: ["Sports", "Sports"]) == nil)
    }

    @Test func oneNameIsItsOwnKey() {
        #expect(PillKeys.keys(for: ["Sports"]) == ["Sports"])
        #expect(PillKeys.index(of: "Sports", in: ["Sports"]) == 0)
        #expect(PillKeys.keys(for: []) == [])
    }
}
