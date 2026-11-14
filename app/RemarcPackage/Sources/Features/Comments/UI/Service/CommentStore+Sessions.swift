import CorePlatform
import FeatureCapture
import FeatureComments
import Foundation
import Combine
import AppKit

extension CommentStore {
    // MARK: - Session Operations

    public var activeSession: Session? {
        appState.sessions.first { $0.id == appState.activeSessionID && !$0.isDeleted }
    }

    public var activeSessions: [Session] {
        SessionPinningPolicy.activeSessions(in: appState.sessions)
    }

    public func setActiveSession(_ id: UUID) {
        appState.activeSessionID = id
        scheduleSave()
    }

    @discardableResult
    public func createSession(name: String) -> Session? {
        var session = Session(name: name)
        session.emptySince = session.createdAt
        appState.sessions.append(session)

        // If this is the only active session, make it active
        if activeSessions.count == 1 {
            appState.activeSessionID = session.id
        }

        scheduleSave()
        debugLog("CommentStore: Created session '\(name)'")
        return session
    }

    public func renameSession(_ id: UUID, to name: String) {
        guard let index = appState.sessions.firstIndex(where: { $0.id == id }),
              !appState.sessions[index].isInbox else { return }
        appState.sessions[index].name = name
        scheduleSave()
    }

    public func setSessionPinned(_ id: UUID, to pinned: Bool) {
        guard SessionPinningPolicy.setPinned(pinned, for: id, in: &appState, now: Date()) else { return }
        scheduleSave()
    }

    public func deleteSession(_ id: UUID) {
        guard !pinnedSessionIDs.contains(id) else {
            // A durable write is staging a comment into this session. Validation
            // inside the write only compares the candidate against disk; it cannot
            // see a local deletion landing during the await, and the rebase would
            // re-apply it afterwards. The inactivity timer calls this unattended,
            // so the case is not hypothetical.
            deferredSessionDeletions.append(id)
            debugLog("CommentStore: Deferred deletion of pinned session \(id)")
            return
        }
        guard let index = appState.sessions.firstIndex(where: { $0.id == id }),
              !appState.sessions[index].isInbox else { return }
        let now = Date()
        appState.sessions[index].isDeleted = true
        appState.sessions[index].deletedAt = now

        // Soft-delete all comments in this session
        for i in appState.comments.indices where appState.comments[i].sessionID == id && !appState.comments[i].isDeleted {
            appState.comments[i].isDeleted = true
            appState.comments[i].deletedAt = now
            appState.comments[i].updatedAt = now
        }

        // If this was the active session, switch to another
        if appState.activeSessionID == id {
            appState.activeSessionID = activeSessions.first?.id
        }


        scheduleSave()
        debugLog("CommentStore: Deleted session")
    }

    /// Delete a stored image and every file derived from it.
    ///
    /// The one place image deletion happens, so no path can remove the primary
    /// PNG and leave its editing base behind. That matters more than it sounds:
    /// for an image annotated with vectors only, the base is a byte-for-byte
    /// copy of the original capture, so a missed sidecar means a permanently
    /// deleted comment's screenshot stays on disk.
    ///
    /// A failed deletion stays tracked by the caller so an unavailable custom
    /// folder or a partially deleted family can be retried on a later launch.
    @discardableResult
    static func deleteImageFamily(_ relativePath: String) -> Bool {
        do {
            try AnnotationMarkStore.deleteImageFamily(relativePath)
            return true
        } catch {
            debugLog("CommentStore: could not fully delete \(relativePath) - \(error)")
            return false
        }
    }

    /// Permanent deletion removes the comment immediately; any files that
    /// could not be removed still need a durable cleanup reference.
    static func deleteImageOrRetainForRetry(_ path: String, orphanedImages: inout [OrphanedImage]) {
        guard !deleteImageFamily(path) else { return }
        if let index = orphanedImages.firstIndex(where: { $0.path == path }) {
            orphanedImages[index] = OrphanedImage(
                id: orphanedImages[index].id, path: path, deletedAt: .distantPast)
        } else {
            orphanedImages.append(OrphanedImage(path: path, deletedAt: .distantPast))
        }
    }

    /// Keep failed cleanup records, including when the primary PNG was removed
    /// but one of its annotation sidecars could not be deleted.
    static func pruneExpiredImages(_ orphanedImages: inout [OrphanedImage], before cutoff: Date,
                                   referencedPaths: Set<String> = []) {
        // Older records may use relative paths while newer ones use absolute paths.
        let referencedURLs = Set(referencedPaths.map { resolveImagePath($0).standardizedFileURL })
        orphanedImages.removeAll { orphan in
            orphan.deletedAt <= cutoff
                && !referencedURLs.contains(resolveImagePath(orphan.path).standardizedFileURL)
                && deleteImageFamily(orphan.path)
        }
    }

    public func permanentlyDeleteSession(_ id: UUID) {
        for comment in appState.comments where comment.sessionID == id {
            if let imagePath = comment.type.imagePath {
                Self.deleteImageOrRetainForRetry(imagePath, orphanedImages: &appState.orphanedImages)
            }
            for attachment in comment.attachments {
                Self.deleteImageOrRetainForRetry(attachment, orphanedImages: &appState.orphanedImages)
            }
        }
        appState.sessions.removeAll { $0.id == id }
        appState.comments.removeAll { $0.sessionID == id }
        scheduleSave()
    }

    @discardableResult
    public func restoreSession(_ id: UUID) -> Bool {
        guard !documentWriteInFlight, !backgroundSaveInFlight else { return false }
        do {
            let commit = try SessionTaskTransactions.restoreHistorySession(
                fileURL: fileURL, candidate: appState, baseline: lastPersisted,
                sessionID: id, now: Date()
            )
            appState = commit.state
            lastPersisted = commit.state
            return commit.value
        } catch {
            debugLog("CommentStore: Could not restore session")
            return false
        }
    }

    public func dismissSession(_ id: UUID) {
        guard let index = appState.sessions.firstIndex(where: { $0.id == id }),
              !appState.sessions[index].isPinned else { return }
        appState.sessions[index].isAutoDismissed = true
        appState.sessions[index].autoDismissedAt = Date()

        if appState.activeSessionID == id {
            appState.activeSessionID = activeSessions.first?.id
        }

        scheduleSave()
    }


}
