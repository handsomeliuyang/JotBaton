import Foundation

public enum CommentCompletionScope: Sendable {
    case inProgress, allUnresolved

    package func includes(_ status: CommentStatus) -> Bool {
        switch self {
        case .inProgress: return status == .inProgress
        case .allUnresolved: return status != .resolved
        }
    }
}

public struct CommentCompletionReceipt: Sendable {
    public struct Entry: Sendable {
        let before: Comment
        let completed: Comment
    }
    public let sessionID: UUID
    let entries: [Entry]
    package var completedComments: [Comment] { entries.map(\.completed) }
    public var count: Int { entries.count }
    package var commentIDs: [UUID] { entries.map { $0.before.id } }
}

package enum CommentCompletionPolicy {
    package static func complete(_ state: inout AppState, in sessionID: UUID, scope: CommentCompletionScope,
                         archiveImmediately: Bool = false, now: Date) -> CommentCompletionReceipt {
        var entries: [CommentCompletionReceipt.Entry] = []
        for index in state.comments.indices {
            let before = state.comments[index]
            guard before.sessionID == sessionID, !before.isDeleted, scope.includes(before.status) else { continue }
            state.comments[index].status = .resolved
            state.comments[index].resolvedAt = now
            state.comments[index].resolvedBy = nil
            state.comments[index].resolutionSummary = nil
            state.comments[index].updatedAt = now
            if archiveImmediately {
                state.comments[index].isDeleted = true
                state.comments[index].deletedAt = now
            }
            entries.append(.init(before: before, completed: state.comments[index]))
        }
        return CommentCompletionReceipt(sessionID: sessionID, entries: entries)
    }

    /// Compare exact versions: later edits, moves, deletions and agent updates
    /// must survive an Undo, even if another session is currently selected.
    package static func undo(_ receipt: CommentCompletionReceipt, in state: inout AppState, now: Date) -> [UUID] {
        guard state.sessions.contains(where: { $0.id == receipt.sessionID && !$0.isDeleted && !$0.isAutoDismissed }) else { return [] }
        var restored: [UUID] = []
        for entry in receipt.entries {
            guard let index = state.comments.firstIndex(where: { $0.id == entry.completed.id }),
                  state.comments[index] == entry.completed else { continue }
            var comment = entry.before
            comment.updatedAt = now
            state.comments[index] = comment
            restored.append(comment.id)
        }
        return restored
    }
}
