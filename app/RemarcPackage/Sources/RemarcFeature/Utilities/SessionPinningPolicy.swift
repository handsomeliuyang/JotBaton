import Foundation

enum SessionPinningPolicy {
    /// Stable groups, shared by navigation and comment destination pickers.
    static func activeSessions(in sessions: [Session]) -> [Session] {
        let active = sessions.filter { !$0.isDeleted && !$0.isAutoDismissed }
        return active.filter(\.isInbox)
            + active.filter { !$0.isInbox && $0.isPinned }
            + active.filter { !$0.isInbox && !$0.isPinned }
    }

    @discardableResult
    static func setPinned(_ pinned: Bool, for id: UUID, in state: inout AppState, now: Date) -> Bool {
        guard let index = state.sessions.firstIndex(where: { $0.id == id }),
              !state.sessions[index].isInbox, !state.sessions[index].isDeleted,
              !state.sessions[index].isAutoDismissed, state.sessions[index].isPinned != pinned else { return false }
        state.sessions[index].isPinned = pinned
        let occupied = state.comments.contains { $0.sessionID == id && !$0.isDeleted }
        state.sessions[index].emptySince = pinned || occupied ? nil : now
        return true
    }
}
