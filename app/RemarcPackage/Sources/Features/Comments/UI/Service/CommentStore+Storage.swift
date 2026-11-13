import CorePlatform
import FeatureComments
import Foundation
import Combine
import AppKit

extension CommentStore {
    func scheduleSave(dataChanged: Bool = true) {
        if dataChanged { appState.markSnapshotDataChanged() }
        reconcileEmptySessions()
        saveSubject.send()
    }

    /// Write our state, merged with whatever landed on disk since we last read
    /// it, under the cross-process lock.
    ///
    /// Writing a long-lived in-memory snapshot directly can erase changes made
    /// since it was read. Locking alone does not fix that: the snapshot itself
    /// is stale, so we re-read and merge inside the lock.
    /// Routine save: does the locked read-merge-write on a background actor so
    /// contention with another process never blocks the UI.
    func saveToDisk() {
        reconcileEmptySessions()
        // A durable write owns the document. Running now would merge against a
        // baseline it is about to replace, publishing state computed from an
        // older snapshot over the newer one. `saveToDiskBlocking` deliberately
        // does NOT take this gate: its whole purpose is that the bytes are on
        // disk before it returns, and it re-reads and merges under the lock, so
        // a concurrent durable commit is picked up rather than lost.
        guard !documentWriteInFlight else {
            deferredSaveRequested = true
            return
        }
        // Coalesce rather than drop: a request arriving mid-save means the
        // in-flight snapshot is already stale, so remember to run again. The
        // previous guard discarded that request entirely and then assigned the
        // stale merged result back over newer edits, deleting them.
        guard !backgroundSaveInFlight else {
            backgroundSaveRequested = true
            return
        }
        backgroundSaveInFlight = true
        let ours = appState
        let base = lastPersisted
        let url = fileURL
        Task { [weak self] in
            let merged = await self?.documentWriter.save(fileURL: url, base: base, ours: ours)
            await MainActor.run {
                guard let self else { return }
                self.backgroundSaveInFlight = false
                guard let merged else {
                    // Lock busy or write failed: state stays in memory, and a
                    // later mutation retries.
                    debugLog("CommentStore: Save deferred - could not acquire document lock")
                    if self.backgroundSaveRequested {
                        self.backgroundSaveRequested = false
                        self.saveToDisk()
                    }
                    return
                }
                self.lastPersisted = merged
                if self.appState == ours {
                    // Nothing changed while we were writing: adopting the
                    // merged document is safe and picks up other processes'
                    // commits.
                    if merged != self.appState { self.appState = merged }
                    if self.reconcileEmptySessions() { self.backgroundSaveRequested = true }
                } else {
                    // Edits landed mid-save. Keep them and write again rather
                    // than overwriting with the older snapshot.
                    self.backgroundSaveRequested = true
                }
                if self.backgroundSaveRequested {
                    self.backgroundSaveRequested = false
                    self.saveToDisk()
                }
            }
        }
    }

    /// Blocking variant for the two places that genuinely need the bytes on
    /// disk before returning: paired integrations watch this file, so a
    /// comment must be readable before the change event fires) and termination.
    @discardableResult
    func saveToDiskBlocking() -> Bool {
        reconcileEmptySessions()
        do {
            try DocumentLock.withLock(fileURL) {
                let onDisk: AppState
                switch DocumentRead.read(fileURL) {
                case .absent:
                    onDisk = lastPersisted
                case .decoded(let decoded):
                    onDisk = decoded
                case .unreadable(let reason):
                    throw DocumentUnreadable(reason: reason)
                }
                let merged = AppStateMerge.merge(base: lastPersisted, ours: appState, theirs: onDisk)
                let data = try JSONEncoder().encode(merged)
                try data.write(to: fileURL, options: .atomic)
                lastPersisted = merged
                if merged != appState { appState = merged }
                if reconcileEmptySessions() { scheduleSave() }
            }
            return true
        } catch is DocumentLock.TimedOut {
            debugLog("CommentStore: Blocking save skipped - could not acquire document lock")
            return false
        } catch let error as DocumentUnreadable {
            DocumentRecovery.dump(appState, beside: fileURL, reason: error.reason)
            return false
        } catch {
            debugLog("CommentStore: Failed to save - \(error)")
            return false
        }
    }


    #if DEBUG
    func removeDocumentForTesting() {
        try? FileManager.default.removeItem(at: fileURL)
        try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent().appendingPathComponent("data.json"))
        debugLog("Data file removed - restart app to reset")
    }
    #endif

}
