import Foundation
import Testing
@testable import PelmetCore

@Suite struct PanelOptionsTests {
    private func decode(_ json: String) throws -> PanelOptions {
        try JSONDecoder().decode(PanelOptions.self, from: Data(json.utf8))
    }

    @Test func defaultsAreCompactAutoAndFolded() throws {
        let options = PanelOptions()
        #expect(!options.centersOnClick)
        #expect(!options.showsNames)
        #expect(options.columnsWithNames == nil && options.columnsCompact == nil)
        #expect(!options.separatorsBreakRows)
        #expect(options.alwaysHidden == .folded)
        #expect(!options.alwaysHiddenOpen)
        #expect(options.alwaysHiddenFold == .tile)
        #expect(!options.showsClosedApps)
        #expect(!options.showsSettingsButton)
        #expect(PanelOptions.autoColumns == 5)
        #expect(try decode("{}") == options)
    }

    @Test func invalidClickCenteringFallsBackWithoutLosingOtherSettings() throws {
        let options = try decode(#"{"centersOnClick":"yes","showsNames":true}"#)
        #expect(!options.centersOnClick)
        #expect(options.showsNames)
    }

    @Test func roundTrips() throws {
        var options = PanelOptions()
        options.centersOnClick = true
        options.showsNames = true
        options.columnsWithNames = 4
        options.columnsCompact = 7
        options.separatorsBreakRows = true
        options.alwaysHidden = .asLeft
        options.alwaysHiddenOpen = true
        options.alwaysHiddenFold = .handle
        options.showsClosedApps = true
        options.showsSettingsButton = true
        let back = try JSONDecoder().decode(PanelOptions.self, from: JSONEncoder().encode(options))
        #expect(back == options)
    }

    // One bad field resets that field and keeps the rest.
    @Test func aBadFieldKeepsTheOthers() throws {
        let options = try decode(#"""
        {"showsNames":"yes","columnsWithNames":6,"columnsCompact":"wide",
         "separatorsBreakRows":true,"alwaysHidden":"tucked","alwaysHiddenOpen":true,
         "alwaysHiddenFold":"drawer","showsSettingsButton":"on"}
        """#)
        #expect(options.showsNames == false)
        #expect(options.columnsWithNames == 6)
        #expect(options.columnsCompact == nil)
        #expect(options.separatorsBreakRows)
        #expect(options.alwaysHidden == .folded)
        #expect(options.alwaysHiddenOpen)
        #expect(options.alwaysHiddenFold == .tile)
        #expect(!options.showsSettingsButton)
    }

    @Test func aMissingFieldKeepsTheOthers() throws {
        let options = try decode(#"{"showsNames":true,"alwaysHidden":"hidden"}"#)
        #expect(options.showsNames)
        #expect(options.alwaysHidden == .hidden)
        #expect(options.columnsWithNames == nil && !options.separatorsBreakRows)
    }

    // A nil column count is Auto and stays nil; a stored one is pulled into
    // what the drag handle can reach.
    @Test func columnsStayInReach() throws {
        let wild = try decode(#"{"columnsWithNames":0,"columnsCompact":99}"#)
        #expect(wild.columnsWithNames == PanelOptions.columnRange.lowerBound)
        #expect(wild.columnsCompact == PanelOptions.columnRange.upperBound)
        let null = try decode(#"{"columnsWithNames":null}"#)
        #expect(null.columnsWithNames == nil)
    }

    // The edge drag writes whichever names mode is on; the other keeps its width.
    @Test func columnsFollowTheNamesMode() {
        var options = PanelOptions()
        options.columnsCompact = 7
        options.columnsWithNames = 4
        #expect(options.columns == 7)
        options.showsNames = true
        #expect(options.columns == 4)
        options.columns = 3
        #expect(options.columnsWithNames == 3 && options.columnsCompact == 7)
        options.columns = nil
        #expect(options.columnsWithNames == nil && options.columnsCompact == 7)
    }
}
