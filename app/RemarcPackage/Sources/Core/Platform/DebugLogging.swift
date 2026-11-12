import AppKit
import os.log

private let logger = Logger(subsystem: AppIdentity.current.bundleIdentifier, category: "debug")
nonisolated(unsafe) private let debugLogFormatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    return f
}()
private let debugLogQueue = DispatchQueue(label: "com.metepolat.Remarc.debugLog", qos: .utility)

/// Selected text, window titles, and dictation transcripts pass through here
/// (issue #12), so release builds write no log file at all unless the user
/// opts in for a support case:
///
///     defaults write com.metepolat.Remarc debugFileLoggingEnabled -bool YES
///
/// While the flag is set the current launch logs to a fresh file and the
/// previous launch's file is kept as remarc_debug.log.old, so a bug whose
/// reproduction spans a relaunch (or a Sparkle update mid-support-case) still
/// has its pre-restart half. Two bounded files at most. With the flag unset
/// (the default) both files are deleted on launch, which also clears logs
/// accumulated by older builds that wrote unconditionally. Debug builds keep
/// the fixed /tmp path that local tooling tails.
private let debugLogFileURL: URL? = {
    #if DEBUG
    return URL(fileURLWithPath: AppIdentity.current.isDevelopment ? "/tmp/remarc_dev_debug.log" : "/tmp/remarc_debug.log")
    #else
    let logsDir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
        .appendingPathComponent("Logs/" + AppIdentity.current.directoryName, isDirectory: true)
    let logFile = logsDir.appendingPathComponent("remarc_debug.log")
    let previousLogFile = logsDir.appendingPathComponent("remarc_debug.log.old")
    guard UserDefaults.standard.bool(forKey: "debugFileLoggingEnabled") else {
        try? FileManager.default.removeItem(at: logFile)
        try? FileManager.default.removeItem(at: previousLogFile)
        return nil
    }
    try? FileManager.default.createDirectory(
        at: logsDir,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
    )
    try? FileManager.default.removeItem(at: previousLogFile)
    try? FileManager.default.moveItem(at: logFile, to: previousLogFile)
    return logFile
    #endif
}()

/// Runs the release-build log deletion/rotation above, eagerly. The first
/// debugLog call would do the same work lazily, but the docs promise "Remarc
/// deletes the log the next time it launches", and that must not depend on
/// early logging happening to come true. AppController.setup calls this
/// before anything else; calling it again is a no-op.
public func prepareDebugLogFile() {
    _ = debugLogFileURL
}

public func debugLog(_ message: String) {
    let timestamp = debugLogFormatter.string(from: Date())
    print("[Remarc] \(message)")
    logger.notice("\(message)")
    let logMessage = "[\(timestamp)] \(message)\n"
    debugLogQueue.async {
        guard let logFile = debugLogFileURL else { return }
        guard let data = logMessage.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: logFile) {
            handle.seekToEndOfFile()
            handle.write(data)
            handle.closeFile()
        } else {
            try? data.write(to: logFile)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: logFile.path)
        }
    }
}
