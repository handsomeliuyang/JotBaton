import Foundation

enum HistoryRestorationPolicy {
    static func reopen(_ comment: inout Comment, to sessionID: UUID, now: Date) {
        comment.isDeleted = false
        comment.deletedAt = nil
        comment.sessionID = sessionID
        comment.status = .open
        comment.resolutionSummary = nil
        comment.resolvedAt = nil
        comment.resolvedBy = nil
        comment.updatedAt = now
    }

    static func restoreSession(_ id: UUID, in state: inout AppState, maxActiveSessions: Int, now: Date) -> Bool {
        guard let index = state.sessions.firstIndex(where: { $0.id == id && ($0.isDeleted || $0.isAutoDismissed) }),
              state.sessions.filter({ !$0.isDeleted && !$0.isAutoDismissed }).count < maxActiveSessions else { return false }
        let deletedAt = state.sessions[index].deletedAt
        state.sessions[index].isDeleted = false
        state.sessions[index].deletedAt = nil
        state.sessions[index].isAutoDismissed = false
        state.sessions[index].autoDismissedAt = nil
        state.sessions[index].emptySince = state.sessions[index].isPinned ? nil : now

        // A cleaned empty session can still own comments archived earlier.
        // Only bring back comments that were deleted together with the session.
        if let deletedAt {
            for i in state.comments.indices where state.comments[i].sessionID == id
                && state.comments[i].isDeleted && state.comments[i].deletedAt == deletedAt {
                reopen(&state.comments[i], to: id, now: now)
            }
        }
        if state.comments.contains(where: { $0.sessionID == id && !$0.isDeleted }) {
            state.sessions[index].emptySince = nil
        }
        state.activeSessionID = id
        return true
    }
}
