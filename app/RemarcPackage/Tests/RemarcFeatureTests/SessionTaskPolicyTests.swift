import Foundation
import Testing
@testable import RemarcFeature

@Suite("Empty session cleanup and task completion")
struct SessionTaskPolicyTests {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private let delay: TimeInterval = 1800

    private func task(_ session: Session, status: CommentStatus = .inProgress) -> RemarcFeature.Comment {
        RemarcFeature.Comment(type: .quickNote, commentText: "Task", source: "Tests", appBundleID: nil,
            createdAt: now.addingTimeInterval(-7200), updatedAt: now.addingTimeInterval(-7200),
            sessionID: session.id, status: status)
    }

    @Test("All retained statuses protect a session, including completed tasks and a zero badge count")
    func retainedTasksProtectSessions() {
        for status in CommentStatus.allCases {
            let session = Session(name: "Work", createdAt: now.addingTimeInterval(-7200), emptySince: now.addingTimeInterval(-7200))
            var state = AppState(sessions: [session], comments: [task(session, status: status)], activeSessionID: session.id)
            let previous = state
            EmptySessionCleanupPolicy.reconcile(&state, previous: previous, now: now)
            #expect(state.sessions[0].emptySince == nil)
            #expect(EmptySessionCleanupPolicy.expiredIDs(in: state, interval: delay, now: now).isEmpty)
        }
    }

    @Test("Removing the last task starts now, not at session creation; new tasks cancel and restart the clock")
    func emptyTransitions() {
        let session = Session(name: "Work", createdAt: now.addingTimeInterval(-7200))
        var state = AppState(sessions: [session], comments: [task(session)], activeSessionID: session.id)
        let occupied = state
        state.comments[0].isDeleted = true
        state.comments[0].deletedAt = now
        state.comments[0].updatedAt = now
        EmptySessionCleanupPolicy.reconcile(&state, previous: occupied, now: now)
        #expect(state.sessions[0].emptySince == now)
        #expect(EmptySessionCleanupPolicy.expiredIDs(in: state, interval: delay, now: now.addingTimeInterval(1799)).isEmpty)
        #expect(EmptySessionCleanupPolicy.expiredIDs(in: state, interval: delay, now: now.addingTimeInterval(1800)) == [session.id])
        let empty = state
        state.comments[0].isDeleted = false
        state.comments[0].deletedAt = nil
        EmptySessionCleanupPolicy.reconcile(&state, previous: empty, now: now.addingTimeInterval(1200))
        #expect(state.sessions[0].emptySince == nil)
        let restored = state
        state.comments[0].isDeleted = true
        state.comments[0].deletedAt = now.addingTimeInterval(1300)
        EmptySessionCleanupPolicy.reconcile(&state, previous: restored, now: now.addingTimeInterval(1300))
        #expect(state.sessions[0].emptySince == now.addingTimeInterval(1300))
    }

    @Test("Moving the last task starts empty time for its source and cancels empty time for its target")
    func movedTask() {
        let source = Session(name: "Source", createdAt: now.addingTimeInterval(-7200))
        let target = Session(name: "Target", createdAt: source.createdAt, emptySince: source.createdAt)
        let previous = AppState(sessions: [source, target], comments: [task(source)])
        var state = previous
        state.comments[0].sessionID = target.id
        state.comments[0].updatedAt = now
        EmptySessionCleanupPolicy.reconcile(&state, previous: previous, now: now)
        #expect(state.sessions[0].emptySince == now)
        #expect(state.sessions[1].emptySince == nil)
    }

    @Test("Old empty sessions get a full interval; known empty time survives relaunch and JSON round trip")
    func legacyAndPersistence() throws {
        let session = Session(name: "Legacy", createdAt: now.addingTimeInterval(-7200))
        var state = AppState(sessions: [session])
        let legacy = state
        EmptySessionCleanupPolicy.reconcile(&state, previous: legacy, now: now)
        #expect(state.sessions[0].emptySince == now)
        var decoded = try JSONDecoder().decode(AppState.self, from: JSONEncoder().encode(state))
        let previous = decoded
        EmptySessionCleanupPolicy.reconcile(&decoded, previous: previous, now: now.addingTimeInterval(600))
        #expect(decoded.sessions[0].emptySince == now)
        #expect(EmptySessionCleanupPolicy.expiredIDs(in: decoded, interval: delay, now: now.addingTimeInterval(600)).isEmpty)
    }

    @Test("New empty sessions count from creation; an expired current session returns to Inbox without deleting history")
    func emptyCurrentSession() {
        let inbox = Session(name: "Inbox", createdAt: now.addingTimeInterval(-7200), emptySince: now.addingTimeInterval(-7200))
        let session = Session(name: "Work", createdAt: inbox.createdAt, emptySince: inbox.createdAt)
        var deleted = task(session)
        deleted.isDeleted = true
        deleted.deletedAt = now.addingTimeInterval(-3600)
        var state = AppState(sessions: [inbox, session], comments: [deleted], activeSessionID: session.id)
        let previous = state
        EmptySessionCleanupPolicy.reconcile(&state, previous: previous, now: now)
        #expect(EmptySessionCleanupPolicy.expiredIDs(in: state, interval: delay, excluding: [session.id], now: now).isEmpty)
        #expect(EmptySessionCleanupPolicy.removeExpired(from: &state, interval: delay, now: now) == [session.id])
        #expect(!state.sessions[0].isDeleted && state.sessions[1].isDeleted)
        #expect(state.activeSessionID == inbox.id)
        #expect(state.comments == [deleted])
    }

    @Test("The default completion scope affects only this session's live in-progress tasks; Undo restores original values")
    func completionScopeAndUndo() {
        let session = Session(name: "Work"), other = Session(name: "Other")
        var deleted = task(session); deleted.isDeleted = true
        let comments = [task(session, status: .open), task(session, status: .handedOff), task(session),
                        task(session, status: .resolved), task(other), deleted]
        var state = AppState(sessions: [session, other], comments: comments, activeSessionID: session.id)
        let receipt = CommentCompletionPolicy.complete(&state, in: session.id, scope: .inProgress, now: now)
        #expect(receipt.count == 1)
        #expect(receipt.commentIDs == [comments[2].id])
        #expect(state.comments.enumerated().allSatisfy { $0.offset == 2 || $0.element == comments[$0.offset] })
        #expect(state.comments[2].status == .resolved && state.comments[2].resolvedAt == now)
        state.activeSessionID = other.id
        #expect(CommentCompletionPolicy.undo(receipt, in: &state, now: now.addingTimeInterval(1)) == [comments[2].id])
        #expect(state.comments[2].status == .inProgress && state.comments[2].resolvedAt == comments[2].resolvedAt)
        #expect(state.activeSessionID == other.id)
        #expect(CommentCompletionPolicy.undo(receipt, in: &state, now: now.addingTimeInterval(2)).isEmpty)
    }

    @Test("Undo never reverts later edits, moves, deletions, agent updates, or tasks added after the click")
    func undoPreservesLaterChanges() {
        let session = Session(name: "Work"), other = Session(name: "Other")
        var state = AppState(sessions: [session, other], comments: (0..<5).map { _ in task(session) })
        let receipt = CommentCompletionPolicy.complete(&state, in: session.id, scope: .inProgress, now: now)
        state.comments[0].commentText = "Edited later"
        state.comments[1].sessionID = other.id
        state.comments[2].isDeleted = true
        state.comments[3].resolvedBy = "agent"
        state.comments.append(task(session))
        let later = state
        #expect(CommentCompletionPolicy.undo(receipt, in: &state, now: now.addingTimeInterval(1)) == [later.comments[4].id])
        #expect(state.comments.prefix(4) == later.comments.prefix(4))
        #expect(state.comments[5] == later.comments[5])
    }

    @Test("More / Resolve All keeps its broader scope and can restore mixed original statuses")
    func broaderCompletion() {
        let session = Session(name: "Work")
        let comments = CommentStatus.allCases.map { task(session, status: $0) }
        var state = AppState(sessions: [session], comments: comments)
        let receipt = CommentCompletionPolicy.complete(&state, in: session.id, scope: .allUnresolved, now: now)
        #expect(receipt.count == 3)
        #expect(state.comments.allSatisfy { $0.status == .resolved })
        #expect(CommentCompletionPolicy.undo(receipt, in: &state, now: now.addingTimeInterval(1)).count == 3)
        #expect(state.comments.map(\.status) == comments.map(\.status))
    }

    @Test("Immediate resolved deletion waits for the Undo window; a retained completed task still protects the session")
    func undoProtection() {
        let session = Session(name: "Work")
        var state = AppState(sessions: [session], comments: [task(session)])
        let receipt = CommentCompletionPolicy.complete(&state, in: session.id, scope: .inProgress, now: now)
        let protection = [state.comments[0].id: now.addingTimeInterval(5.2)]
        #expect(ResolvedCommentDeletionPolicy.expiredIDs(in: state.comments, interval: 0, protectedUntil: protection, now: now.addingTimeInterval(5)).isEmpty)
        #expect(ResolvedCommentDeletionPolicy.expiredIDs(in: state.comments, interval: 0, protectedUntil: protection, now: now.addingTimeInterval(6)) == Set(receipt.commentIDs))
        let completed = state
        EmptySessionCleanupPolicy.reconcile(&state, previous: completed, now: now)
        #expect(state.sessions[0].emptySince == nil)
        _ = CommentCompletionPolicy.undo(receipt, in: &state, now: now.addingTimeInterval(2))
        #expect(ResolvedCommentDeletionPolicy.expiredIDs(in: state.comments, interval: 0, now: now.addingTimeInterval(6)).isEmpty)
    }
}
