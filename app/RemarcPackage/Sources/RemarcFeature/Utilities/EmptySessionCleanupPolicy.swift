import Foundation

/// Counts every retained comment, including completed ones. Empty time is local
/// housekeeping metadata; it is not task activity or a badge count.
enum EmptySessionCleanupPolicy {
    @discardableResult
    static func reconcile(_ state: inout AppState, previous: AppState, now: Date) -> Bool {
        let occupied = Set(state.comments.filter { !$0.isDeleted }.map(\.sessionID))
        let previousSessions = Dictionary(previous.sessions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let currentComments = Dictionary(state.comments.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var departures: [UUID: Date] = [:]
        for comment in state.comments where comment.isDeleted {
            let date = comment.deletedAt ?? comment.updatedAt
            departures[comment.sessionID] = max(departures[comment.sessionID] ?? .distantPast, date)
        }
        // A moved or permanently removed last task also starts a new interval.
        for comment in previous.comments where !comment.isDeleted {
            let current = currentComments[comment.id]
            if current == nil || current?.isDeleted == true || current?.sessionID != comment.sessionID {
                let date = current.map { $0.deletedAt ?? $0.updatedAt } ?? now
                departures[comment.sessionID] = max(departures[comment.sessionID] ?? .distantPast, date)
            }
        }
        var changed = false
        for index in state.sessions.indices {
            let session = state.sessions[index]
            let value: Date?
            if session.isInbox || session.isDeleted || session.isAutoDismissed || occupied.contains(session.id) {
                value = nil
            } else {
                let before = previousSessions[session.id]
                let restored = before?.isDeleted == true || before?.isAutoDismissed == true
                let initial = restored ? now : session.emptySince
                    ?? (before == nil ? session.createdAt : now)
                value = max(initial, departures[session.id] ?? .distantPast)
            }
            if session.emptySince != value {
                state.sessions[index].emptySince = value
                changed = true
            }
        }
        return changed
    }

    static func expiredIDs(in state: AppState, interval: TimeInterval, excluding: Set<UUID> = [], now: Date) -> [UUID] {
        let occupied = Set(state.comments.filter { !$0.isDeleted }.map(\.sessionID))
        return state.sessions.compactMap { session in
            guard !session.isInbox, !session.isDeleted, !session.isAutoDismissed,
                  !occupied.contains(session.id), !excluding.contains(session.id),
                  let since = session.emptySince, now.timeIntervalSince(since) >= interval else { return nil }
            return session.id
        }
    }

    static func removeExpired(from state: inout AppState, interval: TimeInterval, excluding: Set<UUID> = [], now: Date) -> [UUID] {
        let ids = expiredIDs(in: state, interval: interval, excluding: excluding, now: now)
        let deleted = Set(ids)
        for index in state.sessions.indices where deleted.contains(state.sessions[index].id) {
            state.sessions[index].isDeleted = true
            state.sessions[index].deletedAt = now
            state.sessions[index].emptySince = nil
        }
        if let active = state.activeSessionID, deleted.contains(active) {
            state.activeSessionID = state.sessions.first { $0.isInbox && !$0.isDeleted }?.id
                ?? state.sessions.first { !$0.isDeleted && !$0.isAutoDismissed }?.id
        }
        // Never delete comments here. A fresh retained task always disqualifies
        // its session, even if the timer was based on an older snapshot.
        return ids
    }
}
