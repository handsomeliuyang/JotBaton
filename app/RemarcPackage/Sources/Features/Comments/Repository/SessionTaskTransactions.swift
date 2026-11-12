import CorePlatform
import Foundation

package struct SessionTaskCommit<Value: Sendable>: Sendable {
    package let state: AppState
    package let value: Value
}

/// Fresh-read transactions shared by the toolbar and the unattended cleanup.
/// No singleton or real user directory is needed to exercise them in tests.
package enum SessionTaskTransactions {
    package static func complete(fileURL: URL, candidate: AppState, baseline: AppState, sessionID: UUID,
                         scope: CommentCompletionScope, archiveImmediately: Bool = false,
                         now: Date) throws -> SessionTaskCommit<CommentCompletionReceipt> {
        try update(fileURL: fileURL, candidate: candidate, baseline: baseline, now: now) { state in
            guard state.sessions.contains(where: { $0.id == sessionID && !$0.isDeleted && !$0.isAutoDismissed }) else {
                throw PersistenceError.sessionUnavailable
            }
            return CommentCompletionPolicy.complete(&state, in: sessionID, scope: scope,
                                                    archiveImmediately: archiveImmediately, now: now)
        }
    }

    package static func undo(fileURL: URL, candidate: AppState, baseline: AppState,
                     receipt: CommentCompletionReceipt, now: Date) throws -> SessionTaskCommit<[UUID]> {
        try update(fileURL: fileURL, candidate: candidate, baseline: baseline, now: now) { state in
            CommentCompletionPolicy.undo(receipt, in: &state, now: now)
        }
    }

    package static func cleanupEmpty(fileURL: URL, candidate: AppState, baseline: AppState, interval: TimeInterval,
                             excluding: Set<UUID>, now: Date) throws -> SessionTaskCommit<[UUID]> {
        // A busy document is simply reconsidered next minute; never wait on the
        // main thread or queue a deletion against an obsolete empty snapshot.
        try update(fileURL: fileURL, candidate: candidate, baseline: baseline, timeout: 0, now: now) { state in
            EmptySessionCleanupPolicy.removeExpired(from: &state, interval: interval, excluding: excluding, now: now)
        }
    }

    package static func restoreHistorySession(fileURL: URL, candidate: AppState, baseline: AppState, sessionID: UUID,
                                      maxActiveSessions: Int, now: Date) throws -> SessionTaskCommit<Bool> {
        try update(fileURL: fileURL, candidate: candidate, baseline: baseline, now: now) { state in
            HistoryRestorationPolicy.restoreSession(sessionID, in: &state, maxActiveSessions: maxActiveSessions, now: now)
        }
    }

    private static func update<Value: Sendable>(fileURL: URL, candidate: AppState, baseline: AppState,
                                                timeout: TimeInterval = 2, now: Date,
                                                mutate: (inout AppState) throws -> Value) throws -> SessionTaskCommit<Value> {
        do {
            return try DocumentLock.withLock(fileURL, timeout: timeout) {
                let onDisk: AppState
                switch DocumentRead.read(fileURL) {
                case .absent: onDisk = baseline
                case .decoded(let state): onDisk = state
                case .unreadable(let reason): throw PersistenceError.documentUnreadable(reason)
                }
                var state = AppStateMerge.merge(base: baseline, ours: candidate, theirs: onDisk)
                EmptySessionCleanupPolicy.reconcile(&state, previous: baseline, now: now)
                let before = state
                let value = try mutate(&state)
                EmptySessionCleanupPolicy.reconcile(&state, previous: before, now: now)
                if state != before { state.markSnapshotDataChanged(at: now) }
                if state != onDisk {
                    let data: Data
                    do { data = try JSONEncoder().encode(state) }
                    catch { throw PersistenceError.encodeFailed("\(error)") }
                    do { try data.write(to: fileURL, options: .atomic) }
                    catch { throw PersistenceError.writeFailed("\(error)") }
                }
                return SessionTaskCommit(state: state, value: value)
            }
        } catch is DocumentLock.TimedOut {
            throw PersistenceError.lockTimeout
        }
    }
}

/// Lock polling, document decoding and atomic writes run on this actor's
/// executor, never on the UI's main actor. The on-disk lock still coordinates
/// with the MCP server and hooks.
package actor SessionTaskWriter {
    package init() {}
    package func complete(fileURL: URL, candidate: AppState, baseline: AppState, sessionID: UUID,
                  scope: CommentCompletionScope, archiveImmediately: Bool,
                  now: Date) throws -> SessionTaskCommit<CommentCompletionReceipt> {
        try SessionTaskTransactions.complete(
            fileURL: fileURL, candidate: candidate, baseline: baseline, sessionID: sessionID,
            scope: scope, archiveImmediately: archiveImmediately, now: now)
    }

    package func undo(fileURL: URL, candidate: AppState, baseline: AppState,
              receipt: CommentCompletionReceipt, now: Date) throws -> SessionTaskCommit<[UUID]> {
        try SessionTaskTransactions.undo(fileURL: fileURL, candidate: candidate,
                                         baseline: baseline, receipt: receipt, now: now)
    }
}
