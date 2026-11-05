// OwnProcessAX.swift
// Reads an AX attribute from any thread, our own process's elements included.
//
// For another app, an AX read is a message that app answers on its main
// thread. For our own, HIServices skips the message and calls AppKit in
// process, on the calling thread. MenuBarAgent's tree nests every app that has
// a status item, Dimble too, so a background walk of the bar reaches our own
// elements and runs AppKit off the main thread. It crashed in `objc_msgSend`
// under `-[NSApplication _accessibilityValueForAttribute:clientError:]` about
// 2 s after a launch, while AppKit was still building windows (2026-11-05).

import ApplicationServices
import Foundation

/// `AXUIElementCopyAttributeValue` for code that can run off the main thread:
/// an element of our own process is read on the main thread, which waits for
/// it to come free. Anything else reads where it is, as a remote read may
/// block on a busy app.
@discardableResult
public func axCopyAttribute(_ element: AXUIElement, _ name: CFString, _ value: inout CFTypeRef?) -> AXError {
    var pid: pid_t = 0
    AXUIElementGetPid(element, &pid)
    guard pid == getpid(), !Thread.isMainThread else {
        return AXUIElementCopyAttributeValue(element, name, &value)
    }
    // This thread waits, so nothing else touches these while main has them.
    nonisolated(unsafe) let own = element
    nonisolated(unsafe) let attribute = name
    nonisolated(unsafe) var read: CFTypeRef?
    let error = DispatchQueue.main.sync { AXUIElementCopyAttributeValue(own, attribute, &read) }
    value = read
    return error
}
