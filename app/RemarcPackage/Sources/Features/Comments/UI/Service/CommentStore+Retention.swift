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
                    removeClaudeCodeMarkerFile(for: session)
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

    // MARK: - Claude Code Marker Cleanup

    /// Marker files at /tmp/remarc-claude-<claudeSessionId>.marker are used by the SessionEnd
    /// hook to locate which Remarc session to wind down. Abnormal Claude Code exits (kill,
    /// terminal close) skip the hook and leave the marker pinned, which pins the Remarc
    /// session. Couple marker cleanup to session deletion so they can't outlive it.
    func removeClaudeCodeMarkerFile(for session: Session) {
        guard let claudeSessionId = session.claudeCodeSessionId else { return }
        let path = IntegrationConstants.claudeCodeMarkerPath(for: claudeSessionId)
        try? FileManager.default.removeItem(atPath: path)
    }

    /// Launch-time sweep for markers whose Remarc session is missing or already deleted —
    /// catches cruft from versions before marker cleanup was coupled to deleteSession.
    func cleanupStaleClaudeCodeMarkers() {
        let tmpDir = IntegrationConstants.claudeCodeMarkerDirectory
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: tmpDir) else { return }
        let prefix = IntegrationConstants.claudeCodeMarkerPrefix
        let suffix = IntegrationConstants.claudeCodeMarkerSuffix
        var removed = 0
        for entry in entries where entry.hasPrefix(prefix) && entry.hasSuffix(suffix) {
            let claudeSessionId = String(entry.dropFirst(prefix.count).dropLast(suffix.count))
            let session = appState.sessions.first { $0.claudeCodeSessionId == claudeSessionId }
            guard session?.isDeleted ?? true else { continue }
            try? FileManager.default.removeItem(atPath: "\(tmpDir)/\(entry)")
            removed += 1
        }
        if removed > 0 {
            debugLog("CommentStore: Cleaned up \(removed) stale Claude Code marker file(s)")
        }
    }

    func pruneExpiredHistory() {
        let historyRetention = SettingsManager.shared.historyRetentionDays
        let imageRetention = SettingsManager.shared.imageRetentionDays
        let transcriptionRetention = SettingsManager.shared.transcriptionRetentionDays
        let now = Date()
        let historyCutoff = Calendar.current.date(byAdding: .day, value: -historyRetention, to: now) ?? now
        let imageCutoff = Calendar.current.date(byAdding: .day, value: -imageRetention, to: now) ?? now
        let transcriptionCutoff = Calendar.current.date(byAdding: .day, value: -transcriptionRetention, to: now) ?? now

        let commentsBefore = appState.comments.count
        let sessionsBefore = appState.sessions.count

        // Pass 1: Prune comment records, orphan their images
        for comment in appState.comments where comment.isDeleted && (comment.deletedAt ?? Date.distantFuture) < historyCutoff {
            let deletedAt = comment.deletedAt ?? now
            if let imagePath = comment.type.imagePath {
                appState.orphanedImages.append(OrphanedImage(path: imagePath, deletedAt: deletedAt))
            }
            for attachment in comment.attachments {
                appState.orphanedImages.append(OrphanedImage(path: attachment, deletedAt: deletedAt))
            }
        }

        appState.comments.removeAll { comment in
            comment.isDeleted && (comment.deletedAt ?? Date.distantFuture) < historyCutoff
        }

        appState.sessions.removeAll { session in
            session.isDeleted && (session.deletedAt ?? Date.distantFuture) < historyCutoff
        }

        // Pass 2: Prune orphaned images past image retention
        let orphansBefore = appState.orphanedImages.count
        Self.pruneExpiredImages(&appState.orphanedImages, before: imageCutoff)

        // Sweep up pairs stranded by an older build or by a delete that failed
        // partway. Without this, sidecars orphaned before deleteImageFamily
        // existed would never be collected by anything.
        AnnotationMarkStore.removeOrphanedSidecars()

        // Pass 3: Prune old transcriptions (soft-deleted or past retention)
        let transcriptionsBefore = appState.transcriptions.count
        appState.transcriptions.removeAll { transcription in
            if transcription.isDeleted, let deletedAt = transcription.deletedAt {
                return deletedAt < historyCutoff
            }
            return transcription.createdAt < transcriptionCutoff
        }
        let transcriptionsRemoved = transcriptionsBefore - appState.transcriptions.count

        let commentsRemoved = commentsBefore - appState.comments.count
        let sessionsRemoved = sessionsBefore - appState.sessions.count
        let orphansRemoved = orphansBefore - appState.orphanedImages.count

        if commentsRemoved > 0 || sessionsRemoved > 0 || orphansRemoved > 0 || transcriptionsRemoved > 0 {
            debugLog("CommentStore: Pruned \(commentsRemoved) comments, \(sessionsRemoved) sessions, \(orphansRemoved) orphaned images, \(transcriptionsRemoved) transcriptions")
            scheduleSave()
        }
    }
}
