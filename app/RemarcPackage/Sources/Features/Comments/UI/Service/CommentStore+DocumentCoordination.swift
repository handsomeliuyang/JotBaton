import CorePlatform
import FeatureComments
import Foundation
import Combine
import AppKit

extension CommentStore {
    // MARK: - Document slot

    func acquireDocumentSlot() async {
        while documentWriteInFlight {
            await withCheckedContinuation { continuation in
                documentSlotWaiters.append(continuation)
            }
        }
        documentWriteInFlight = true
    }

    func releaseDocumentSlot() {
        documentWriteInFlight = false

        if !documentSlotWaiters.isEmpty {
            // Hand off to the next durable write. Deferred saves run
            // when the chain finally drains, not between links.
            let next = documentSlotWaiters.removeFirst()
            next.resume()
            return
        }

        if deferredSaveRequested {
            deferredSaveRequested = false
            saveToDisk()
        }

        applyDeferredSessionDeletions()
    }

    func applyDeferredSessionDeletions() {
        guard !deferredSessionDeletions.isEmpty else { return }
        let pending = deferredSessionDeletions
        deferredSessionDeletions.removeAll()
        for id in pending {
            // Skip it if the transaction we deferred behind put a live comment in
            // there. `deleteSession` soft-deletes every comment in the session, so
            // applying it here would destroy the comment the durable write just
            // reported as saved - and the unattended inactivity timer is one of the
            // callers, so nobody would have asked for that.
            let hasFreshComment = appState.comments.contains {
                $0.sessionID == id && !$0.isDeleted
            }
            guard !hasFreshComment else {
                debugLog("CommentStore: Dropped deferred deletion of session \(id) - it now holds a live comment")
                continue
            }
            deleteSession(id)
        }
    }

    /// Refuse an update if pending edits cannot be durably written.
    public func prepareForUpdate() -> Bool {
        guard !documentWriteInFlight else { return false }
        return saveToDiskBlocking()
    }

    /// Synchronous save for app termination.
    ///
    /// Forced past the in-flight guard: see `saveToDisk(force:)`. Without this a
    /// quit landing inside a durable write's await window silently discards
    /// everything typed since the last debounce.
    public func saveImmediately() {
        saveToDiskBlocking()
    }

}
