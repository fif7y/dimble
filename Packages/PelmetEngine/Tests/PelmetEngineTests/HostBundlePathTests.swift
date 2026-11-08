import Foundation
import Testing
@testable import PelmetEngine

struct HostBundlePathTests {
    @Test func wineExecutableWithoutAnAppBundleTerminates() {
        // AppKit returns a bridged NSURL; constructing a Swift URL masks this loop.
        let executable = NSURL(fileURLWithPath: "/tmp//wine/steam.exe") as URL

        #expect(ItemEnumerator.enclosingBundleID(for: executable) == nil)
    }

    @Test func parentPathComponentTerminates() {
        let executable = NSURL(fileURLWithPath: "/private/var/../executable") as URL

        #expect(ItemEnumerator.enclosingBundleID(for: executable) == nil)
    }

    @Test(arguments: ["/usr/bin/executable", "/"])
    func pathWithoutAnAppBundleHasNoBundleID(_ path: String) {
        #expect(ItemEnumerator.enclosingBundleID(for: URL(fileURLWithPath: path)) == nil)
    }

    @Test func resolvesTheNearestEnclosingAppBundle() throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("host-bundle-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let outer = scratch.appendingPathComponent("Outer.app")
        let inner = outer.appendingPathComponent("Contents/Library/LoginItems/Inner.app")
        for (app, id) in [(outer, "test.outer"), (inner, "test.inner")] {
            let contents = app.appendingPathComponent("Contents")
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            let plist = try PropertyListSerialization.data(
                fromPropertyList: ["CFBundleIdentifier": id, "CFBundlePackageType": "APPL"],
                format: .xml, options: 0
            )
            try plist.write(to: contents.appendingPathComponent("Info.plist"))
        }

        #expect(ItemEnumerator.enclosingBundleID(for: outer.appendingPathComponent("Contents/MacOS/Main")) == "test.outer")
        #expect(ItemEnumerator.enclosingBundleID(for: inner.appendingPathComponent("Contents/MacOS/Helper")) == "test.inner")
    }
}
