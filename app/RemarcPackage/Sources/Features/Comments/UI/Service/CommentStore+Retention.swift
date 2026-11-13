import CoreLocalization
import CorePlatform
import CoreUI
import FeatureCapture
import FeatureComments
import FeatureIntegrations
import FeatureSettings
import Foundation
import Combine
import AppKit

extension CommentStore {
    // MARK: - Resolved Comment Auto-Deletion

    /// Soft-delete a single resolved comment if the setting is `.immediately`.
    /// Delays briefly so the resolved state change is visible before the comment disappears.
    func autoDeleteResolvedCommentIfImmediate(_ id: UUID) {
        guard SettingsManager.shared.resolvedCommentDeletion == .immediately else { return }
        let generation = snapshotGeneration
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(800))
            guard generation == snapshotGeneration,
                  !isCompletionUndoProtected(id, now: Date()),
                  let index = appState.comments.firstIndex(where: { $0.id == id && !$0.isDeleted && $0.status == .resolved }) else { return }
            let sessionID = appState.comments[index].sessionID
            let now = Date()
            appState.comments[index].isDeleted = true
            appState.comments[index].deletedAt = now
            appState.comments[index].updatedAt = now
            scheduleSave()
            debugLog("CommentStore: Immediately auto-deleted resolved comment \(id)")
            ToastManager.shared.show(L10n.tr("Moved to History"), undo: { [weak self] in
                self?.restoreComment(id, to: sessionID)
            })
        }
    }

    /// Scan all resolved comments and soft-delete those whose interval has expired.
    func autoDeleteResolvedComments() {
        let setting = SettingsManager.shared.resolvedCommentDeletion
        guard let interval = setting.interval else { return } // .never → no-op

        let now = Date()
        let expired = ResolvedCommentDeletionPolicy.expiredIDs(
            in: appState.comments, interval: interval, protectedUntil: completionUndoDeadlines, now: now
        )
        let didDelete = !expired.isEmpty
        for index in appState.comments.indices where expired.contains(appState.comments[index].id) {
            appState.comments[index].isDeleted = true
            appState.comments[index].deletedAt = now
            appState.comments[index].updatedAt = now
        }
        if didDelete {
            scheduleSave()
            debugLog("CommentStore: Auto-deleted expired resolved comments (setting: \(setting.rawValue))")
        }
    }

    /// Start or stop the 60-second repeating timer based on the deletion setting.
    func updateResolvedDeletionTimer(for setting: ResolvedCommentDeletion) {
        resolvedDeletionTimer?.invalidate()
        resolvedDeletionTimer = nil

        // Only need a timer for timed delays (not .never or .immediately)
        guard setting.interval != nil && setting != .immediately else { return }

        resolvedDeletionTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.autoDeleteResolvedComments()
            }
        }
        debugLog("CommentStore: Started resolved deletion timer (setting: \(setting.rawValue))")
    }

    // MARK: - Inactive Session Auto-Deletion

    @discardableResult
    func reconcileEmptySessions() -> Bool {
        EmptySessionCleanupPolicy.reconcile(&appState, previous: lastPersisted, now: Date())
    }

    func autoDeleteInactiveSessions() {
        let settings = SettingsManager.shared
        guard settings.inactiveSessionCleanupEnabled,
              !documentWriteInFlight, !backgroundSaveInFlight else { return }
        var protected = pinnedSessionIDs
        let input = CommentInputController.shared
        if input.isVisible, let id = input.targetSessionID ?? appState.activeSessionID { protected.insert(id) }
        let editor = FloatingEditorController.shared
        if editor.isVisible, let id = editor.targetSessionID ?? appState.activeSessionID { protected.insert(id) }
        do {
            let commit = try SessionTaskTransactions.cleanupEmpty(
                fileURL: fileURL, candidate: appState, baseline: lastPersisted,
                interval: settings.inactiveSessionCleanupInterval.interval,
                excluding: protected, now: Date()
            )
            appState = commit.state
            lastPersisted = commit.state
            for id in commit.value {
                if let session = appState.sessions.first(where: { $0.id == id }) {
                }
            }
            if !commit.value.isEmpty {
                debugLog("CommentStore: Auto-cleaned \(commit.value.count) continuously empty session(s)")
            }
        } catch {
            debugLog("CommentStore: Empty session cleanup deferred")
        }
    }

    func updateInactiveSessionTimer() {
        inactiveSessionTimer?.invalidate()
        inactiveSessionTimer = nil

        guard SettingsManager.shared.inactiveSessionCleanupEnabled else { return }

        inactiveSessionTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.autoDeleteInactiveSessions() }
        }
        debugLog("CommentStore: Started inactive session timer")

        // Run immediately so toggling on takes effect without waiting 60s
        autoDeleteInactiveSessions()
    }

    /// History records and their image families share one deadline. Keep a
    /// durable orphan record until deletion succeeds, including legacy orphans.
    @discardableResult
    static func pruneExpiredHistory(_ state: inout AppState, before cutoff: Date) -> Int {
        var queuedPaths = Set(state.orphanedImages.map(\.path))
        for comment in state.comments {
            guard comment.isDeleted, let deletedAt = comment.deletedAt, deletedAt <= cutoff else { continue }
            var paths = comment.attachments
            if let imagePath = comment.type.imagePath {
                paths.append(imagePath)
            }
            for path in paths where queuedPaths.insert(path).inserted {
                state.orphanedImages.append(OrphanedImage(path: path, deletedAt: deletedAt))
            }
        }

        state.comments.removeAll { comment in
            comment.isDeleted && (comment.deletedAt ?? .distantFuture) <= cutoff
        }

        state.sessions.removeAll { session in
            session.isDeleted && (session.deletedAt ?? .distantFuture) <= cutoff
        }

        // A remaining comment, including unexpired history, may share an image.
        let referencedPaths = Set(state.comments.flatMap { comment in
            comment.attachments + [comment.type.imagePath].compactMap { $0 }
        })
        let orphansBefore = state.orphanedImages.count
        Self.pruneExpiredImages(&state.orphanedImages, before: cutoff, referencedPaths: referencedPaths)
        return orphansBefore - state.orphanedImages.count
    }

    func pruneExpiredHistory() {
        let historyRetention = SettingsManager.shared.historyRetentionDays
        let now = Date()
        let historyCutoff = Calendar.current.date(byAdding: .day, value: -historyRetention, to: now) ?? now

        let commentsBefore = appState.comments.count
        let sessionsBefore = appState.sessions.count
        let orphansRemoved = Self.pruneExpiredHistory(&appState, before: historyCutoff)

        // Sweep up pairs stranded by an older build or by a delete that failed
        // partway. Without this, sidecars orphaned before deleteImageFamily
        // existed would never be collected by anything.
        AnnotationMarkStore.removeOrphanedSidecars()

        let commentsRemoved = commentsBefore - appState.comments.count
        let sessionsRemoved = sessionsBefore - appState.sessions.count
        if commentsRemoved > 0 || sessionsRemoved > 0 || orphansRemoved > 0 {
            debugLog("CommentStore: Pruned \(commentsRemoved) comments, \(sessionsRemoved) sessions, \(orphansRemoved) orphaned images")
            scheduleSave()
        }
    }
}
