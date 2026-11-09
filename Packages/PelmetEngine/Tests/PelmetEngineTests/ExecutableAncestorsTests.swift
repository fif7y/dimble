import Foundation
import Testing
@testable import PelmetEngine

/// The walk from an executable up to its `.app`, which names a bundle-less
/// host. A bridged NSURL holding a doubled slash used to spin there forever
/// (fif7y/dimble#133, Wine's "…/T//winetemp-…/steam.exe").
@Suite struct ExecutableAncestorsTests {
    @Test func climbsToTheRoot() {
        let list = ItemEnumerator.ancestors(of: URL(fileURLWithPath: "/Applications/Thing.app/Contents/MacOS/Thing"))
        #expect(list.map(\.path) == [
            "/Applications/Thing.app/Contents/MacOS/Thing",
            "/Applications/Thing.app/Contents/MacOS",
            "/Applications/Thing.app/Contents",
            "/Applications/Thing.app",
            "/Applications",
        ])
    }

    /// The bug: `NSURL`'s own deletingLastPathComponent() appends "../" past
    /// a doubled slash instead of climbing, so this never used to end.
    @Test func aDoubledSlashStillEnds() {
        let path = "/var/folders/ab/T//winetemp-1234/steam.exe"
        let bridged = NSURL(fileURLWithPath: path) as URL
        let list = ItemEnumerator.ancestors(of: bridged)
        #expect(list.count == 6)
        #expect(list.first?.path == "/var/folders/ab/T/winetemp-1234/steam.exe")
        #expect(list.last?.path == "/var")
        #expect(!list.contains { $0.path.contains("..") })
    }

    /// A Wine executable under a real .app still finds its bundle's folder,
    /// doubled slash and all: the ancestors are what `hostBundle` tests for.
    @Test func aDoubledSlashKeepsTheAppAncestor() {
        let bridged = NSURL(fileURLWithPath: "/Users/x/Games//Steam.app/Contents/MacOS/steam") as URL
        let list = ItemEnumerator.ancestors(of: bridged)
        #expect(list.contains { $0.pathExtension == "app" })
        #expect(list.first { $0.pathExtension == "app" }?.path == "/Users/x/Games/Steam.app")
    }

    @Test func theRootItselfWalksNowhere() {
        #expect(ItemEnumerator.ancestors(of: URL(fileURLWithPath: "/")).isEmpty)
    }
}

/// The bundle id read off that walk. Ported from ZeLebo's fif7y/dimble#134,
/// which built the nested bundles on disk rather than trusting the path shape.
@Suite struct EnclosingBundleIDTests {
    /// A login item nested in another app is filed under itself: the walk has
    /// to stop at the nearest .app, not climb on to the one shipping it.
    @Test func theNearestAppWins() throws {
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

    /// A doubled slash used to spin here forever; a literal ".." is the same
    /// shape, and standardizing collapses both before the climb starts.
    @Test(arguments: ["/tmp//wine/steam.exe", "/private/var/../executable", "/usr/bin/executable", "/"])
    func aPathWithoutAnAppHasNoBundleID(_ path: String) {
        let bridged = NSURL(fileURLWithPath: path) as URL
        #expect(ItemEnumerator.enclosingBundleID(for: bridged) == nil)
    }
}
