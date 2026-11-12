import CorePlatform
import FeatureComments
import FeatureSettings
import Foundation
import Combine
import AppKit

extension CommentStore {
    // MARK: - Comment Operations

    public func comments(for sessionID: UUID) -> [Comment] {
        appState.comments
            .filter { $0.sessionID == sessionID && !$0.isDeleted }
            .sorted { $0.createdAt < $1.createdAt }
    }

    public var allComments: [Comment] {
        appState.comments.filter { !$0.isDeleted }
    }

    /// Outstanding comments across every session. Resolved comments stay in
    /// `allComments`, but do not contribute to outstanding-work badges.
    /// Sidebar counts follow the comment list's selected statuses instead.
    public var unresolvedCommentCount: Int {
        CommentCountPolicy.unresolvedCount(in: appState.comments)
    }

    public var unresolvedCommentCountsBySession: [UUID: Int] {
        CommentCountPolicy.unresolvedCountsBySession(in: appState.comments)
    }

    public var activeComments: [Comment] {
        guard let activeID = appState.activeSessionID else { return [] }
        return comments(for: activeID)
    }

    @discardableResult
    public func createComment(type: CommentType, commentText: String, source: String, appBundleID: String?, attachments: [String] = [], webContext: WebContext? = nil, regionElements: [WebContext]? = nil, targetSessionID: UUID? = nil, wakeRequested: Bool = false, customTitle: String? = nil) -> Comment? {
        guard CommentSavePolicy.allowsSave(
            type: type,
            commentText: commentText,
            attachments: attachments
        ) else {
            debugLog("CommentStore: Rejected empty Quick Note")
            return nil
        }
        let normalizedCommentText = Comment.normalizedCommentText(commentText)

        // Auto-create a session if none exists
        if appState.activeSessionID == nil || activeSession == nil {
            let session = Session(name: CommentConstants.inboxSessionName)
            appState.sessions.append(session)
            appState.activeSessionID = session.id
            debugLog("CommentStore: Auto-created session '\(session.name)'")
        }

        // Use targetSessionID if provided, otherwise fall back to activeSessionID
        let sessionID = targetSessionID ?? appState.activeSessionID
        guard let sessionID else {
            debugLog("CommentStore: No active session for comment")
            return nil
        }

        // A wake comment is handed off the moment it is saved: the agent claims
        // it from there with a compare-and-set.
        let comment = Comment(
            type: type,
            commentText: normalizedCommentText,
            source: source,
            appBundleID: appBundleID,
            sessionID: sessionID,
            status: wakeRequested ? .handedOff : .open,
            attachments: attachments,
            webContext: webContext,
            regionElements: regionElements,
            wakeRequestedAt: wakeRequested ? Date() : nil,
            customTitle: customTitle
        )

        appState.comments.append(comment)
        appState.totalCommentsCreated += 1

        appState.markSnapshotDataChanged()
        if wakeRequested {
            // Agent integrations watch this file; the comment has to be on disk
            // before the change event fires, or the woken session finds nothing.
            saveNow()
        } else {
            scheduleSave()
        }
        debugLog("CommentStore: Created comment \(comment.shortID) (total: \(appState.totalCommentsCreated))")
        onCommentChange(.commentCreated,  comment)
        return comment
    }

    @discardableResult
    public func updateComment(_ id: UUID, text: String, attachments: [String]? = nil, customTitle: String?? = nil) -> Bool {
        guard let index = appState.comments.firstIndex(where: { $0.id == id }) else { return false }
        guard CommentSavePolicy.allowsSave(
            type: appState.comments[index].type,
            commentText: text,
            attachments: attachments ?? appState.comments[index].attachments
        ) else {
            debugLog("CommentStore: Rejected empty Quick Note update")
            return false
        }
        appState.comments[index].commentText = Comment.normalizedCommentText(text)
        // An omitted patch preserves the title; .some(nil) explicitly clears it.
        if let customTitle {
            appState.comments[index].customTitle = CommentTitlePolicy.normalizedCustomTitle(customTitle)
        }
        if let attachments = attachments {
            appState.comments[index].attachments = attachments
        }
        appState.comments[index].updatedAt = Date()
        scheduleSave()
        onCommentChange(.commentUpdated,  appState.comments[index])
        return true
    }

    public func deleteComment(_ id: UUID) {
        guard let index = appState.comments.firstIndex(where: { $0.id == id }) else { return }
        let now = Date()
        appState.comments[index].isDeleted = true
        appState.comments[index].deletedAt = now
        appState.comments[index].updatedAt = now
        scheduleSave()
        onCommentChange(.commentDeleted,  appState.comments[index])
    }

    public func permanentlyDeleteComment(_ id: UUID) {
        if let comment = appState.comments.first(where: { $0.id == id }) {
            // Only announce if it wasn't already soft-deleted (which fired its own event).
            if !comment.isDeleted {
                onCommentChange(.commentDeleted,  comment)
            }
            if let imagePath = comment.type.imagePath {
                Self.deleteImageOrRetainForRetry(imagePath, orphanedImages: &appState.orphanedImages)
            }
            for attachment in comment.attachments {
                Self.deleteImageOrRetainForRetry(attachment, orphanedImages: &appState.orphanedImages)
            }
        }
        appState.comments.removeAll { $0.id == id }
        scheduleSave()
    }

    public func restoreComment(_ id: UUID, to sessionID: UUID) {
        guard let index = appState.comments.firstIndex(where: { $0.id == id && $0.isDeleted }) else { return }
        HistoryRestorationPolicy.reopen(&appState.comments[index], to: sessionID, now: Date())
        scheduleSave()
    }

    public func restoreComments(_ ids: [UUID]) {
        let now = Date()
        for id in ids {
            guard let index = appState.comments.firstIndex(where: { $0.id == id }) else { continue }
            appState.comments[index].isDeleted = false
            appState.comments[index].deletedAt = nil
            appState.comments[index].updatedAt = now
        }
        scheduleSave()
    }

    @discardableResult
    public func clearAllComments(in sessionID: UUID) -> [UUID] {
        let now = Date()
        var clearedIDs: [UUID] = []
        for index in appState.comments.indices {
            if appState.comments[index].sessionID == sessionID && !appState.comments[index].isDeleted {
                appState.comments[index].isDeleted = true
                appState.comments[index].deletedAt = now
                appState.comments[index].updatedAt = now
                clearedIDs.append(appState.comments[index].id)
                onCommentChange(.commentDeleted,  appState.comments[index])
            }
        }
        scheduleSave()
        return clearedIDs
    }

    /// Soft-delete only the exact comment versions in a successful export.
    ///
    /// The comparison and mutation happen after a fresh read while holding the
    /// cross-process document lock. Checking only `appState` is unsafe: MCP can
    /// edit a comment on disk before its asynchronous reload notification reaches
    /// the app, and an in-memory check would then delete that newer version.
    @discardableResult
    public func clearExportedComments(
        _ receipt: ExportReceipt
    ) -> Result<[UUID], PersistenceError> {
        let candidate = appState
        let baseline = lastPersisted

        // This intentionally stays synchronous on the main actor. If it yielded
        // after taking `candidate`, an edit could land while the lock-held helper
        // was clearing the older version on disk. Repairing memory afterwards
        // would still leave a crash window before the compensating save. Keeping
        // the compare-and-set atomic with respect to app mutations avoids ever
        // committing that transient deletion. Cross-process writers remain
        // serialized by DocumentLock and are re-read inside the helper.
        do {
            let commit = try CommentStore.performExportReceiptClear(
                fileURL: fileURL,
                receipt: receipt,
                candidate: candidate,
                baseline: baseline
            )

            appState = commit.state
            lastPersisted = commit.state
            if reconcileEmptySessions() { scheduleSave() }
            for id in commit.clearedIDs {
                if let comment = appState.comments.first(where: { $0.id == id }) {
                    onCommentChange(.commentDeleted,  comment)
                }
            }
            return .success(commit.clearedIDs)
        } catch let error as PersistenceError {
            debugLog("CommentStore: Export clear failed - \(error)")
            return .failure(error)
        } catch {
            let persistenceError = PersistenceError.writeFailed("\(error)")
            debugLog("CommentStore: Export clear failed - \(persistenceError)")
            return .failure(persistenceError)
        }
    }

    public func moveComment(_ id: UUID, to sessionID: UUID) {
        guard let index = appState.comments.firstIndex(where: { $0.id == id }) else { return }
        appState.comments[index].sessionID = sessionID
        appState.comments[index].updatedAt = Date()
        scheduleSave()
        onCommentChange(.commentUpdated,  appState.comments[index])
    }

    public func resolveComment(_ id: UUID, summary: String, resolvedBy: String) {
        guard let index = appState.comments.firstIndex(where: { $0.id == id }) else { return }
        appState.comments[index].status = .resolved
        appState.comments[index].resolutionSummary = summary
        appState.comments[index].resolvedBy = resolvedBy
        appState.comments[index].resolvedAt = Date()
        appState.comments[index].updatedAt = Date()
        scheduleSave()
        debugLog("CommentStore: Resolved comment \(id)")
        onCommentChange(.commentResolved,  appState.comments[index])

        autoDeleteResolvedCommentIfImmediate(id)
    }

    public func reopenComment(_ id: UUID) {
        guard let index = appState.comments.firstIndex(where: { $0.id == id }) else { return }
        appState.comments[index].status = .open
        appState.comments[index].resolutionSummary = nil
        appState.comments[index].resolvedBy = nil
        appState.comments[index].resolvedAt = nil
        appState.comments[index].updatedAt = Date()
        scheduleSave()
        debugLog("CommentStore: Reopened comment \(id)")
        onCommentChange(.commentStatusChanged,  appState.comments[index])
    }

    public func setCommentStatus(_ id: UUID, to status: CommentStatus) {
        guard let index = appState.comments.firstIndex(where: { $0.id == id }) else { return }
        let previousStatus = appState.comments[index].status
        appState.comments[index].status = status
        appState.comments[index].updatedAt = Date()
        if status == .resolved {
            // Set resolvedAt if not already set (for timed auto-delete)
            if appState.comments[index].resolvedAt == nil {
                appState.comments[index].resolvedAt = Date()
            }
        } else {
            // Clear resolution metadata when moving away from resolved
            appState.comments[index].resolutionSummary = nil
            appState.comments[index].resolvedBy = nil
            appState.comments[index].resolvedAt = nil
        }
        scheduleSave()
        debugLog("CommentStore: Set comment \(id) status to \(status.rawValue)")

        if previousStatus != status {
            onCommentChange(
                status == .resolved ? .commentResolved : .commentStatusChanged,
                appState.comments[index]
            )
        }

        // Auto-delete immediately if setting is .immediately
        if status == .resolved {
            autoDeleteResolvedCommentIfImmediate(id)
        }
    }

    /// The receipt pins the exact completed versions and original states for Undo.
    public func completeComments(in sessionID: UUID, scope: CommentCompletionScope = .inProgress) async -> Result<CommentCompletionReceipt, PersistenceError> {
        guard !taskCompletionInFlight else { return .failure(.lockTimeout) }
        taskCompletionInFlight = true
        defer { taskCompletionInFlight = false }
        await acquireDocumentSlot()
        defer { releaseDocumentSlot() }
        do {
            // A routine save may already be running when we take the slot.
            // Drain its publication before fixing this transaction's merge base.
            while backgroundSaveInFlight { try await Task.sleep(for: .milliseconds(10)) }
            let launchState = appState
            pinnedSessionIDs.insert(sessionID)
            defer { pinnedSessionIDs.remove(sessionID) }
            let commit = try await sessionTaskWriter.complete(
                fileURL: fileURL, candidate: launchState, baseline: lastPersisted,
                sessionID: sessionID, scope: scope,
                archiveImmediately: SettingsManager.shared.resolvedCommentDeletion == .immediately,
                now: Date()
            )
            adoptTaskCommit(commit.state, launchedFrom: launchState)
            let receipt = commit.value
            // Immediate archiving is already part of the committed state.
            // This deadline only retains Undo protection for housekeeping.
            let deadline = Date().addingTimeInterval(5.2)
            for id in receipt.commentIDs { completionUndoDeadlines[id] = deadline }
            for comment in receipt.completedComments { onCommentChange(.commentResolved, comment) }
            if receipt.count > 0 {
                let generation = snapshotGeneration
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(5200))
                    guard let self, self.snapshotGeneration == generation else { return }
                    for id in receipt.commentIDs where self.completionUndoDeadlines[id] == deadline {
                        self.completionUndoDeadlines.removeValue(forKey: id)
                    }
                    self.autoDeleteResolvedComments()
                }
            }
            return .success(receipt)
        } catch let error as PersistenceError { return .failure(error) }
        catch { return .failure(.writeFailed("\(error)")) }
    }

    public func undoCompletion(_ receipt: CommentCompletionReceipt) async -> Result<Int, PersistenceError> {
        guard !taskCompletionInFlight else { return .failure(.lockTimeout) }
        taskCompletionInFlight = true
        defer { taskCompletionInFlight = false }
        await acquireDocumentSlot()
        defer { releaseDocumentSlot() }
        do {
            while backgroundSaveInFlight { try await Task.sleep(for: .milliseconds(10)) }
            let launchState = appState
            pinnedSessionIDs.insert(receipt.sessionID)
            defer { pinnedSessionIDs.remove(receipt.sessionID) }
            let commit = try await sessionTaskWriter.undo(
                fileURL: fileURL, candidate: launchState, baseline: lastPersisted, receipt: receipt, now: Date()
            )
            adoptTaskCommit(commit.state, launchedFrom: launchState)
            for id in commit.value {
                completionUndoDeadlines.removeValue(forKey: id)
                if let comment = appState.comments.first(where: { $0.id == id }) {
                    onCommentChange(.commentStatusChanged,  comment)
                }
            }
            return .success(commit.value.count)
        } catch let error as PersistenceError { return .failure(error) }
        catch { return .failure(.writeFailed("\(error)")) }
    }

    func adoptTaskCommit(_ committed: AppState, launchedFrom launchState: AppState) {
        // Session switching, text edits and new comments can arrive while IO is
        // suspended. Rebase them rather than publishing the older snapshot.
        appState = AppStateMerge.merge(base: launchState, ours: appState, theirs: committed)
        lastPersisted = committed
        if appState != committed { scheduleSave() }
    }

    func isCompletionUndoProtected(_ id: UUID, now: Date) -> Bool {
        completionUndoDeadlines[id].map { $0 > now } ?? false
    }


}
