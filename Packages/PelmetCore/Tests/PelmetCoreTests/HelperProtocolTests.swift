import Foundation
import Testing
@testable import PelmetCore

struct HelperProtocolTests {
    let item = HostedItem(title: "separator", kind: .separator)

    @Test func normalMessagesRoundTrip() throws {
        let command = try #require(HelperWire.encode(HelperCommand.sync([item])))
        let decoded = try #require(HelperWire.decode(HelperCommand.self, from: command))
        #expect(decoded.isValid)
        guard case .sync(let items) = decoded else { Issue.record("Expected sync"); return }
        #expect(items == [item])
        let event = HelperEvent.clicked(bundle: PelmetBundle.hiddenHostID, title: item.title, rightButton: false, x: -100, y: 20)
        let data = try #require(HelperWire.encode(event))
        #expect(HelperWire.decode(HelperEvent.self, from: data)?.isValid == true)
        #expect(HelperCommand.quit.isValid)
        #expect(HelperCommand.sync([]).isValid)
    }

    @Test func rejectsOversizedValidJSONBeforeDecoding() throws {
        var data = try #require(HelperWire.encode(HelperCommand.quit))
        data.append(Data(repeating: 32, count: HelperWire.maximumMessageBytes - data.count))
        #expect(HelperWire.decode(HelperCommand.self, from: data) != nil)
        data.append(32)
        #expect(HelperWire.decode(HelperCommand.self, from: data) == nil)
        #expect(HelperWire.encode(String(repeating: "x", count: HelperWire.maximumMessageBytes)) == nil)
    }

    @Test func rejectsExcessiveItemCountAndDuplicates() {
        let items = (0..<256).map { HostedItem(title: "item-\($0)", kind: .separator) }
        #expect(HelperCommand.sync(items).isValid)
        #expect(!HelperCommand.sync(items + [item]).isValid)
        #expect(!HelperCommand.sync([item, item]).isValid)
    }

    @Test func boundsTextAndImageSizes() {
        var spec = item
        spec.title = String(repeating: "x", count: 256)
        spec.text = String(repeating: "x", count: 1024)
        spec.imagePNG = Data(count: 256 * 1024)
        #expect(HelperCommand.sync([spec]).isValid)
        spec.imagePNG?.append(0)
        #expect(!HelperCommand.sync([spec]).isValid)
        spec = item
        spec.text = String(repeating: "x", count: 1025)
        #expect(!HelperCommand.sync([spec]).isValid)
        spec = item
        spec.title = String(repeating: "\u{e9}", count: 129)
        #expect(!HelperCommand.sync([spec]).isValid)
    }

    @Test func rejectsInvalidGeometryAndOpacity() {
        for length in [-1, Double.infinity, Double.nan, 1025] {
            var spec = item
            spec.length = length
            #expect(!HelperCommand.sync([spec]).isValid)
        }
        for alpha in [-0.1, 1.1, Double.nan] {
            var spec = item
            spec.alpha = alpha
            #expect(!HelperCommand.sync([spec]).isValid)
        }
    }

    @Test func boundsEventNamesAndCoordinates() {
        #expect(HelperEvent.ready(bundle: PelmetBundle.hiddenHostID).isValid)
        #expect(!HelperEvent.ready(bundle: "").isValid)
        #expect(!HelperEvent.ready(bundle: String(repeating: "x", count: 257)).isValid)
        #expect(!HelperEvent.hosted(bundle: PelmetBundle.hiddenHostID, title: "").isValid)
        #expect(!HelperEvent.draggedOff(bundle: PelmetBundle.hiddenHostID, title: String(repeating: "x", count: 257)).isValid)
        #expect(!HelperEvent.clicked(bundle: PelmetBundle.hiddenHostID, title: item.title, rightButton: false, x: .nan, y: 0).isValid)
        #expect(!HelperEvent.clicked(bundle: PelmetBundle.hiddenHostID, title: item.title, rightButton: false, x: 0, y: .infinity).isValid)
    }
}
