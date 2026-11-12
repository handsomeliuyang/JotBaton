import CorePlatform
import Foundation

/// Serializes document writes off the main actor.
///
/// `PersistenceManager` is `@MainActor` and its debounced save ran the locked
/// read-merge-write inline, so contention with an agent's MCP write blocked the
/// main thread in `Thread.sleep` for up to the lock timeout - a visible UI
/// freeze. Routine saves now hop here instead; only explicitly synchronous
/// paths (the wake button, which must have the comment on disk before it
/// returns, and termination) still block, and both are bounded and deliberate.
package actor DocumentWriter {
    package init() {}
    /// Performs the transaction and returns the merged document, or nil if the
    /// lock could not be taken (the caller keeps its state and retries later).
    package func save(
        fileURL: URL,
        base: AppState,
        ours: AppState
    ) -> AppState? {
        do {
            return try DocumentLock.withLock(fileURL) {
                let onDisk: AppState
                switch DocumentRead.read(fileURL) {
                case .absent:
                    onDisk = base
                case .decoded(let decoded):
                    onDisk = decoded
                case .unreadable(let reason):
                    // Do not merge against a guess and write it back.
                    throw DocumentUnreadable(reason: reason)
                }
                let merged = AppStateMerge.merge(base: base, ours: ours, theirs: onDisk)
                let data = try JSONEncoder().encode(merged)
                try data.write(to: fileURL, options: .atomic)
                return merged
            }
        } catch let error as DocumentUnreadable {
            DocumentRecovery.dump(ours, beside: fileURL, reason: error.reason)
            return nil
        } catch {
            return nil
        }
    }
}
