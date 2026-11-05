// OwnProcessAXTests.swift
// A read of our own process answers the same on and off the main thread, and
// a main actor awaiting that read doesn't deadlock it.

import ApplicationServices
import PelmetEngine
import Testing

@MainActor
struct OwnProcessAXTests {
    private nonisolated static func ownRole() -> (error: AXError, role: String?) {
        var value: CFTypeRef?
        let error = axCopyAttribute(AXUIElementCreateApplication(getpid()), kAXRoleAttribute as CFString, &value)
        return (error, value as? String)
    }

    @Test func anOwnReadAnswersTheSameOffTheMainThread() async {
        let onMain = Self.ownRole()
        let offMain = await Task.detached { Self.ownRole() }.value
        #expect(onMain.error == .success)
        #expect(onMain.role == "AXApplication")
        #expect(offMain.error == onMain.error)
        #expect(offMain.role == onMain.role)
    }
}
