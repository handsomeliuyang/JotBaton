import CorePlatform
import Foundation

/// Serializes locked read-merge-write transactions off the main actor.
/// Explicit synchronous saves for updates and termination remain bounded by
/// the document lock timeout.
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
