import Foundation

/// Cross-process lock around `comments.json`.
///
/// The app is not the only writer: the MCP server and the hooks plugin mutate
/// the same file from Node. `mkdir` is atomic on POSIX and behaves identically
/// from both languages, so it is the lock primitive both sides share - Node has
/// no `flock` binding, which rules out the more obvious choice.
///
/// The lock must span read-through-rename. Locking only the write still loses
/// updates, because the snapshot being written can predate another process's
/// commit.
package enum DocumentLock {
    /// Matches the TypeScript side (`plugins/shared/data.ts`).
    private static let defaultTimeout: TimeInterval = 2.0
    private static let pollInterval: TimeInterval = 0.025
    private static let staleAfter: TimeInterval = 10.0

    package struct TimedOut: Error {}

    package static func lockURL(for fileURL: URL) -> URL {
        URL(fileURLWithPath: fileURL.path + ".lock")
    }

    /// Run `body` while holding the lock. Always releases, including on throw.
    package static func withLock<T>(_ fileURL: URL, timeout: TimeInterval = defaultTimeout, _ body: () throws -> T) throws -> T {
        let lock = lockURL(for: fileURL)
        try acquire(lock, timeout: timeout)
        defer { release(lock) }
        return try body()
    }

    private static func acquire(_ lock: URL, timeout: TimeInterval) throws {
        let fm = FileManager.default
        let deadline = Date().addingTimeInterval(timeout)

        while true {
            do {
                // withIntermediateDirectories: false is what makes this atomic -
                // it fails when the directory already exists.
                try fm.createDirectory(at: lock, withIntermediateDirectories: false)
                let owner = ["pid": ProcessInfo.processInfo.processIdentifier,
                             "at": Int(Date().timeIntervalSince1970 * 1000)] as [String: Any]
                if let data = try? JSONSerialization.data(withJSONObject: owner) {
                    try? data.write(to: lock.appendingPathComponent("owner.json"))
                }
                return
            } catch {
                if reclaimIfAbandoned(lock) { continue }
                if Date() > deadline { throw TimedOut() }
                Thread.sleep(forTimeInterval: pollInterval)
            }
        }
    }

    /// Remove a lock whose owner is gone, so one crashed writer cannot wedge
    /// every other process.
    private static func reclaimIfAbandoned(_ lock: URL) -> Bool {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: lock.path),
              let modified = attrs[.modificationDate] as? Date else {
            return false
        }

        // Liveness first, and it is decisive: a slow holder is still a holder.
        // Reclaiming on age alone breaks mutual exclusion outright - the victim
        // keeps working and later releases the lock the new owner is holding.
        if let data = try? Data(contentsOf: lock.appendingPathComponent("owner.json")),
           let owner = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let pid = owner["pid"] as? Int32 {
            // ESRCH means no such process. EPERM means it exists but belongs to
            // another user, which still counts as alive.
            let dead = kill(pid, 0) != 0 && errno == ESRCH
            guard dead else { return false }
        } else {
            // No readable owner: only age can decide, and only generously - the
            // owner may simply not have written the file yet.
            guard Date().timeIntervalSince(modified) > staleAfter else { return false }
        }

        do {
            try fm.removeItem(at: lock)
            return true
        } catch {
            // Removal genuinely failed (permissions, ACL). Reporting success
            // here would spin the acquire loop with no delay.
            return false
        }
    }

    private static func release(_ lock: URL) {
        try? FileManager.default.removeItem(at: lock)
    }
}
