import CorePlatform
import FeatureComments
import Foundation
import Combine
import AppKit

extension CommentStore {
    // MARK: - Durable creation

    /// Create a comment and return only once it is provably on disk.
    ///
    /// `createComment` cannot do this on either of its branches. The debounced
    /// branch has not written anything yet when it returns, the `wakeRequested`
    /// branch reaches `saveToDisk`, which swallows every error including a lock
    /// timeout, and its only `nil` return is guarded by a session it created
    /// moments earlier. A non-nil return therefore proves nothing, which is fine
    /// for a menu action and not fine for a capture that tears down an overlay, a
    /// draft, and an annotation session on the strength of it.
    ///
    /// This goes through the same cross-process protocol as every other write:
    /// acquire the lock, re-read, three-way merge against `lastPersisted`, encode,
    /// atomic rename. Writing the staged candidate directly would erase whatever
    /// the MCP server and hooks committed in between.
    ///
    /// Not cancellable once the helper has entered the lock. A cancelled task
    /// still completes the write and the publish, because abandoning between the
    /// rename and the publish would leave the document written but unknown to
    /// memory. Callers cancel before preparing, not during.
    public func createCommentDurably(
        type: CommentType,
        commentText: String,
        source: String,
        appBundleID: String?,
        attachments: [String] = [],
        webContext: WebContext? = nil,
        regionElements: [WebContext]? = nil,
        targetSessionID: UUID? = nil,
        wakeRequested: Bool = false,
        customTitle: String? = nil
    ) async -> Result<Comment, PersistenceError> {

        guard CommentSavePolicy.allowsSave(
            type: type,
            commentText: commentText,
            attachments: attachments
        ) else {
            debugLog("CommentStore: Rejected empty Quick Note from durable create")
            return .failure(.invalidComment)
        }

        await acquireDocumentSlot()

        // Snapshotted BEFORE the candidate is built. This is the merge base on
        // the way back, and naming it wrongly deletes the comment that was just
        // written: with `candidate` as the base, the new comment is present in
        // both base and theirs but absent from the current `appState`, and
        // `mergeEntities` appends a theirs-only entity only when it is absent
        // from base. It would be dropped from memory, then from disk.
        let launchState = appState

        var candidate = appState
        let sessionID: UUID
        if let targetSessionID {
            sessionID = targetSessionID
        } else if let active = candidate.activeSessionID,
                  candidate.sessions.contains(where: { $0.id == active && !$0.isDeleted }) {
            sessionID = active
        } else {
            let session = Session(name: CommentConstants.inboxSessionName)
            candidate.sessions.append(session)
            candidate.activeSessionID = session.id
            sessionID = session.id
            debugLog("CommentStore: Auto-created session '\(session.name)' for durable create")
        }

        let comment = Comment(
            type: type,
            commentText: Comment.normalizedCommentText(commentText),
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
        candidate.comments.append(comment)
        candidate.markSnapshotDataChanged()
        // Inside the candidate, never applied afterwards: the counter is part of
        // the encoded document and the merge resolves it by max, so incrementing
        // after the write would diverge memory from disk.
        candidate.totalCommentsCreated += 1

        pinnedSessionIDs.insert(sessionID)

        let url = fileURL
        let baseline = lastPersisted
        let staged = candidate

        let outcome: Result<AppState, PersistenceError>
        do {
            let merged = try await Task.detached(priority: .userInitiated) {
                try CommentStore.performDocumentWrite(
                    fileURL: url, candidate: staged, baseline: baseline, requiredSessionID: sessionID)
            }.value
            outcome = .success(merged)
        } catch let error as PersistenceError {
            outcome = .failure(error)
        } catch {
            outcome = .failure(.writeFailed("\(error)"))
        }

        pinnedSessionIDs.remove(sessionID)

        switch outcome {
        case .failure(let error):
            debugLog("CommentStore: Durable create failed - \(error)")
            releaseDocumentSlot()
            return .failure(error)

        case .success(let merged):
            appState = AppStateMerge.merge(base: launchState, ours: appState, theirs: merged)
            lastPersisted = merged

            guard let stored = appState.comments.first(where: { $0.id == comment.id }) else {
                // Unreachable: an entity present in ours and absent from base takes
                // the "we created it" branch of mergeEntities and is appended
                // unchanged. Treated as a failure rather than asserted, because
                // returning a comment the caller cannot find is worse.
                debugLog("CommentStore: Durable create lost the comment in rebase")
                releaseDocumentSlot()
                return .failure(.writeFailed("comment absent after rebase"))
            }

            if appState != merged {
                // Local edits made during the await are still only in memory.
                scheduleSave()
            }
            debugLog("CommentStore: Durably created comment \(stored.shortID) (total: \(appState.totalCommentsCreated))")
            releaseDocumentSlot()
            // Dispatched after publication, and exactly once from this process.
            // Not end-to-end exactly-once: dispatch is fire-and-forget with up to
            // three attempts, so an ambiguous response can still arrive twice at
            // the receiver, and a crash between the rename and this line loses the
            // event. A real guarantee needs an outbox plus receiver idempotency.
            onCommentChange(.commentCreated,  stored)
            return .success(stored)
        }
    }

    /// One lock-held read, merge, encode, and atomic rename, off the main actor.
    ///
    /// `DocumentLock.acquire` polls with `Thread.sleep` up to a 2s timeout, and
    /// this sits on the capture save's critical path during the fly animation.
    /// `AppState` is a value type, so the candidate crosses by copy.
    ///
    /// Internal rather than private so tests can drive it against a temporary
    /// file. Exercising it through the singleton would mutate the real
    /// `comments.json` in the user's Application Support directory.
    nonisolated static func performDocumentWrite(
        fileURL: URL,
        candidate: AppState,
        baseline: AppState,
        requiredSessionID: UUID?
    ) throws -> AppState {
        do {
            return try DocumentLock.withLock(fileURL) {
                let onDisk: AppState
                if FileManager.default.fileExists(atPath: fileURL.path) {
                    // Propagate read and decode errors instead of falling back to
                    // the baseline the way `saveToDisk` does. Overwriting a
                    // malformed, briefly unreadable, or forward-incompatible
                    // document with stale state destroys whatever a newer build
                    // wrote. The only permitted fallback is a missing file.
                    let data: Data
                    do { data = try Data(contentsOf: fileURL) }
                    catch { throw PersistenceError.documentUnreadable("\(error)") }
                    do { onDisk = try JSONDecoder().decode(AppState.self, from: data) }
                    catch { throw PersistenceError.documentUnreadable("\(error)") }
                } else {
                    onDisk = AppState.defaultState()
                }

                let merged = AppStateMerge.merge(base: baseline, ours: candidate, theirs: onDisk)

                // Sessions merge as whole entities, so another writer soft-deleting
                // the target wins for that untouched session while the new comment
                // still points at it. Deleted sessions are excluded from
                // navigation, so the comment would exist and be invisible. Fail
                // instead; v1 does not silently reparent to Inbox.
                if let requiredSessionID {
                    guard let session = merged.sessions.first(where: { $0.id == requiredSessionID }),
                          !session.isDeleted,
                          // `activeSessions` filters on BOTH flags, so an
                          // auto-dismissed target leaves the comment just as
                          // unreachable as a deleted one.
                          !session.isAutoDismissed else {
                        throw PersistenceError.sessionUnavailable
                    }
                }

                let encoded: Data
                do { encoded = try JSONEncoder().encode(merged) }
                catch { throw PersistenceError.encodeFailed("\(error)") }
                do { try encoded.write(to: fileURL, options: .atomic) }
                catch { throw PersistenceError.writeFailed("\(error)") }
                return merged
            }
        } catch is DocumentLock.TimedOut {
            throw PersistenceError.lockTimeout
        }
    }

    struct ExportClearCommit: Sendable {
        let state: AppState
        let clearedIDs: [UUID]
    }

    /// Lock-held compare-and-set for post-export clearing.
    ///
    /// `candidate` carries app edits that have not reached disk yet. It is merged
    /// with the fresh on-disk document first; only versions that still match the
    /// export receipt after that merge are soft-deleted. Internal for tests so
    /// adversarial disk races can be exercised without touching user data.
    nonisolated static func performExportReceiptClear(
        fileURL: URL,
        receipt: ExportReceipt,
        candidate: AppState,
        baseline: AppState
    ) throws -> ExportClearCommit {
        do {
            return try DocumentLock.withLock(fileURL) {
                let onDisk: AppState
                switch DocumentRead.read(fileURL) {
                case .absent:
                    onDisk = AppState.defaultState()
                case .decoded(let decoded):
                    onDisk = decoded
                case .unreadable(let reason):
                    throw PersistenceError.documentUnreadable(reason)
                }

                var merged = AppStateMerge.merge(
                    base: baseline,
                    ours: candidate,
                    theirs: onDisk
                )
                let clearableIDs = receipt.clearableCommentIDs(in: merged.comments)
                let clearableSet = Set(clearableIDs)
                let now = Date()

                for index in merged.comments.indices
                    where clearableSet.contains(merged.comments[index].id) {
                    merged.comments[index].isDeleted = true
                    merged.comments[index].deletedAt = now
                    merged.comments[index].updatedAt = now
                }

                if !clearableIDs.isEmpty { merged.markSnapshotDataChanged() }
                let encoded: Data
                do { encoded = try JSONEncoder().encode(merged) }
                catch { throw PersistenceError.encodeFailed("\(error)") }
                do { try encoded.write(to: fileURL, options: .atomic) }
                catch { throw PersistenceError.writeFailed("\(error)") }

                return ExportClearCommit(state: merged, clearedIDs: clearableIDs)
            }
        } catch is DocumentLock.TimedOut {
            throw PersistenceError.lockTimeout
        }
    }


}
