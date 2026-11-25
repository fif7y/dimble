import Foundation
import Testing
@testable import Pelmet

@MainActor
struct OpenCapturesTests {
    @Test func aQuitWaitsForAStreamThatIsStarting() async {
        let captures = OpenCaptures()
        #expect(captures.begin())
        var stopped = false
        Task { try? await Task.sleep(for: .milliseconds(150)); stopped = true; captures.end() }
        #expect(await captures.close(within: 2))
        #expect(stopped)
    }

    @Test func noStreamStartsOnceQuitting() async {
        let captures = OpenCaptures()
        #expect(await captures.close(within: 1))
        #expect(!captures.begin())
    }

    @Test func aStreamThatNeverStopsDoesNotHoldTheQuit() async {
        let captures = OpenCaptures()
        #expect(captures.begin())
        let asked = Date()
        #expect(await !captures.close(within: 0.2))
        #expect(Date().timeIntervalSince(asked) < 1)
    }
}
