// MessagePortLink.swift
// A CFMessagePort pair: the smallest transport that reaches a helper we
// launched ourselves without launchd plumbing. One local port per process
// (named by bundle id), fire-and-forget data messages, delivered on the
// receiver's main run loop.

import Foundation

public final class MessagePortListener: @unchecked Sendable {
    private var port: CFMessagePort?
    private var source: CFRunLoopSource?
    private let handler: @Sendable (Data) -> Void

    /// Nil when the name is already taken (another instance is listening).
    public init?(name: String, handler: @escaping @Sendable (Data) -> Void) {
        self.handler = handler
        var context = CFMessagePortContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        guard let port = CFMessagePortCreateLocal(
            nil, name as CFString,
            { _, _, data, info in
                guard let info, let data, CFDataGetLength(data) <= HelperWire.maximumMessageBytes else { return nil }
                let listener = Unmanaged<MessagePortListener>.fromOpaque(info).takeUnretainedValue()
                listener.handler(data as Data)
                return nil
            },
            &context, nil
        ) else { return nil }
        self.port = port
        let source = CFMessagePortCreateRunLoopSource(nil, port, 0)
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    }

    deinit {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let port { CFMessagePortInvalidate(port) }
    }
}

public enum MessagePortLink {
    /// True when the remote port accepted the message. The send only waits
    /// for kernel queue space, not for the helper to handle the message, so
    /// the timeout only ever fires on a hung helper — and it fires on the
    /// caller's main thread, so it is short (was 1s; perf audit 2026-09-15).
    @discardableResult
    public static func send(_ data: Data, to name: String) -> Bool {
        guard data.count <= HelperWire.maximumMessageBytes else { return false }
        guard let remote = CFMessagePortCreateRemote(nil, name as CFString) else { return false }
        defer { CFMessagePortInvalidate(remote) }
        return CFMessagePortSendRequest(remote, 0, data as CFData, 0.25, 0, nil, nil) == kCFMessagePortSuccess
    }

    public static func isListening(_ name: String) -> Bool {
        guard let remote = CFMessagePortCreateRemote(nil, name as CFString) else { return false }
        CFMessagePortInvalidate(remote)
        return true
    }
}
