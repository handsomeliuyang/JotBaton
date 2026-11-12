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
            // Hand off to the next durable write. Deferred saves and reloads run
            // when the chain finally drains, not between links.
            let next = documentSlotWaiters.removeFirst()
            next.resume()
            return
        }

        let wantsReload = deferredReloadRequested
        let wantsSave = deferredSaveRequested
        deferredReloadRequested = false
        deferredSaveRequested = false

        if wantsReload {
            // Suppression of a duplicate creation webhook is structural: the
            // comment is already published to `appState`, so the reload diff sees
            // it on both sides and emits nothing for it. reloadFromDisk flushes
            // pending edits itself, so a deferred save needs no separate run.
            reloadFromDisk()
        } else if wantsSave {
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

    /// Save synchronously, bypassing the debounce.
    ///
    /// Used by the wake CTA: paired integrations watch this file, so the comment has to
    /// be on disk before the event fires, or the woken session finds nothing.
    public func saveNow() {
        saveToDiskBlocking()
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

    func reloadFromDisk() {
        guard !documentWriteInFlight else {
            // Adopting disk state mid-transaction would overwrite `appState` and
            // `lastPersisted` with a snapshot the durable write is about to
            // supersede. Run once it publishes instead.
            deferredReloadRequested = true
            return
        }
        // Flush anything pending before adopting disk state. Cancelling instead
        // (the old behaviour) silently dropped in-flight UI edits whenever an
        // agent wrote to the file. If the flush fails we must NOT continue:
        // replacing appState from disk would discard exactly the edits the
        // flush could not write.
        guard saveToDiskBlocking() else {
            debugLog("CommentStore: Reload aborted - could not flush pending edits")
            return
        }
        saveCancellable?.cancel()
        saveCancellable = saveSubject
            .debounce(for: .milliseconds(250), scheduler: DispatchQueue.main)
            .sink { [weak self] in
                self?.saveToDisk()
            }

        guard let data = try? Data(contentsOf: fileURL),
              let state = try? JSONDecoder().decode(AppState.self, from: data) else {
            debugLog("CommentStore: Failed to reload from disk")
            return
        }
        let previousComments = appState.comments
        let previousSessions = appState.sessions
        appState = state
        if EmptySessionCleanupPolicy.reconcile(&appState, previous: AppState(sessions: previousSessions, comments: previousComments), now: Date()) {
            scheduleSave()
        }
        // Adopt the reloaded document as the merge baseline too. Leaving it
        // stale would make the next save treat every externally-made change as
        // a local edit, so "ours wins" could re-assert values we never touched.
        lastPersisted = state
        debugLog("CommentStore: Reloaded from disk (\(state.comments.count) comments, \(state.sessions.count) sessions)")

        // Out-of-process writers (MCP server, CLI) mutate comments.json directly,
        // so their changes never pass through the mutators above. Diff old vs new
        // state to fire webhooks for agent-driven changes too.
        onExternalChanges(previousComments, state.comments, previousSessions, state.sessions)

        autoDeleteResolvedComments()
        autoDeleteInactiveSessions()
    }


}
