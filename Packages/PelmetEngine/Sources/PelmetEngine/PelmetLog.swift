// PelmetLog.swift
// Dead-simple file logger: ~/Library/Logs/Dimble/dimble.log. Exists because
// os.Logger output from this app never reaches the unified log store on the
// current macOS 27 beta — debugging blind is worse than a plain file.
//
// The app was called Pelmet until 0.3.1 (~/Library/Logs/Pelmet) and Pliss in
// the 0.3.2 betas (~/Library/Logs/Pliss, with Pelmet a symlink to it). At the
// first use in a process, before any file is opened, the newest real old
// folder moves to Dimble and a symlink takes its place, so old instructions
// and tools that tail an old path still land on the live log.

import Foundation

public enum PelmetLog {
    private static let queue = DispatchQueue(label: "pelmet.log", qos: .utility)
    private static let logsRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs")
    static let folderName = "Dimble"
    /// Newest first: a beta install has a real Pliss folder and Pelmet as a
    /// symlink to it, a 0.3.1 install only a real Pelmet folder.
    static let oldFolderNames = ["Pliss", "Pelmet"]

    /// Runs once, ahead of everything that touches the folder. What it did,
    /// as a line for the log (nil when there was nothing to move).
    private static let folderMigration: String? = migrateOldFolder(in: logsRoot)

    private static let dir: URL = {
        _ = folderMigration
        let dir = logsRoot.appendingPathComponent(folderName)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
    private static let url = dir.appendingPathComponent("dimble.log")
    /// The log file, for Settings › About › "Report an issue" to select in Finder.
    public static var fileURL: URL { url }

    /// Moves the first real folder among `oldFolderNames` to `logs/Dimble`
    /// and leaves a symlink to it at the old path (an older symlink, Pelmet →
    /// Pliss, then resolves through it). Only a real old folder moves, and
    /// only into an empty spot: if Dimble already exists (a second copy ran
    /// first, a hand-made folder) nothing is touched. Never throws, never
    /// blocks a launch; the return value is the one log line saying what
    /// happened.
    static func migrateOldFolder(in logs: URL) -> String? {
        let fm = FileManager.default
        let new = logs.appendingPathComponent(folderName)
        guard (try? fm.attributesOfItem(atPath: new.path)) == nil else { return nil }
        // attributesOfItem does not follow symlinks: a symlink already at
        // an old path reads as a link, not a folder.
        guard let old = oldFolderNames.map({ logs.appendingPathComponent($0) }).first(where: {
            (try? fm.attributesOfItem(atPath: $0.path))?[.type] as? FileAttributeType == .typeDirectory
        }) else { return nil }
        do {
            try fm.moveItem(at: old, to: new)
        } catch {
            return "log: could not move \(old.path) to \(new.path) — \(error.localizedDescription)"
        }
        do {
            try fm.createSymbolicLink(atPath: old.path, withDestinationPath: folderName)
        } catch {
            return "log: moved \(old.path) to \(new.path), no symlink left at the old path — \(error.localizedDescription)"
        }
        return "log: moved \(old.path) to \(new.path), symlink left at the old path (older logs keep their old names)"
    }

    /// Rotate at 5 MB into one `.old` generation — a 24/7 agent otherwise
    /// grows the file forever (and it rides backups).
    private static let rotateBytes = 5 * 1024 * 1024

    /// One open handle for the process (per-line open/seek/close was three
    /// syscalls of pure overhead per line). Written only on `queue`.
    nonisolated(unsafe) private static var handle: FileHandle? = {
        rotateIfNeeded()
        let handle = openAppending()
        if let note = folderMigration {
            handle?.write(Data("\(stamp.string(from: Date())) \(note)\n".utf8))
        }
        return handle
    }()

    /// O_APPEND, so every write lands at the file's current end. A handle
    /// that carries its own offset (what `FileHandle(forWritingTo:)` opens)
    /// keeps writing past the end once anything truncates the file under
    /// it — a second copy of the app rotating, a `: > dimble.log` — and the
    /// kernel fills the gap with NUL bytes, wiping what was there. One
    /// report came in with 355 KB of zeros ahead of the first line
    /// (fif7y/dimble#130). O_CREAT covers a missing file.
    private static func openAppending() -> FileHandle? {
        let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard fd >= 0 else { return nil }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    /// Mid-process rotation — the launch-time check alone never fires again
    /// in a long-lived app. Checked every `rotateCheckInterval` writes, on
    /// `queue` (which also owns the handle).
    nonisolated(unsafe) private static var writesSinceRotateCheck = 0
    private static let rotateCheckInterval = 2000

    private static func rotateOnQueueIfNeeded() {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int ?? 0
        guard size > rotateBytes else { return }
        try? handle?.close()
        rotateIfNeeded()
        handle = openAppending()
    }

    private static func rotateIfNeeded() {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int ?? 0
        guard size > rotateBytes else { return }
        let old = dir.appendingPathComponent("dimble.log.old")
        try? FileManager.default.removeItem(at: old)
        try? FileManager.default.moveItem(at: url, to: old)
    }

    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    private static func line(_ message: String) -> String {
        // Strip control characters: AX-derived strings (third-party status
        // item titles) flow into log lines, and an embedded newline could
        // forge entries.
        let clean = message.unicodeScalars
            .map { $0 == "\n" || $0.properties.generalCategory == .control ? " " : Character($0) }
        return "\(stamp.string(from: Date())) \(String(clean))\n"
    }

    /// Writes before it returns. For the line at quit: the process can exit
    /// before `queue` drains, and that line is the one saying Dimble went
    /// down on purpose rather than being killed.
    public static func logBlocking(_ message: String) {
        let line = line(message)
        queue.sync { handle?.write(Data(line.utf8)) }
    }

    public static func log(_ message: String) {
        let line = line(message)
        queue.async {
            handle?.write(Data(line.utf8))
            writesSinceRotateCheck += 1
            if writesSinceRotateCheck >= rotateCheckInterval {
                writesSinceRotateCheck = 0
                rotateOnQueueIfNeeded()
            }
        }
    }
}
