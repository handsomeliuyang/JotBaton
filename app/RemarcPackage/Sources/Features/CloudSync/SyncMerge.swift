import FeatureComments
import Foundation

/// The same field group of one comment changed on two Macs since they last
/// merged. The newer edit is kept so every Mac converges on one value; the
/// other version is retained so the user can switch to it.
package struct SyncConflict: Codable, Equatable, Sendable, Identifiable {
    package enum Field: String, Codable, Sendable { case text, title, status, session }

    package var id: String { "\(commentID.uuidString)-\(field.rawValue)" }
    package let commentID: UUID
    package let field: Field
    package let deviceName: String
    package let localWon: Bool
    /// The version of the comment whose value for `field` was not kept.
    package let alternative: Comment
    package let date: Date

    /// Writes the alternative's value for this field into `comment` as a new edit.
    package func applyAlternative(to comment: inout Comment, now: Date = Date()) {
        SyncMerge.copy(field, from: alternative, to: &comment)
        comment.updatedAt = max(now, comment.updatedAt.addingTimeInterval(0.001))
    }
}

/// Per-comment, per-field three-way merge between this Mac and one other device.
///
/// Unlike `AppStateMerge`, which serves processes sharing one file on one Mac and
/// lets the live UI win, both Macs run this merge independently and must reach
/// the same answer: a field group changed on both sides goes to the newer
/// `updatedAt`, ties to the higher device identifier.
///
/// `remote` and `base` are projections (`SyncProjection`). Device-local fields are
/// only ever taken from `local`.
package enum SyncMerge {
    package struct Result: Sendable {
        package var state: AppState
        package var conflicts: [SyncConflict]
    }

    package static func merge(base: AppState?, local: AppState, remote: AppState,
                              localWinsTie: Bool, remoteName: String, now: Date = Date()) -> Result {
        var conflicts: [SyncConflict] = []
        var result = local
        result.comments = mergeList(base: base?.comments, local: local.comments, remote: remote.comments,
                                    id: \.id, isDeleted: \.isDeleted) { base, local, remote in
            mergeComment(base: base, local: local, remote: remote, localWinsTie: localWinsTie,
                         remoteName: remoteName, now: now, conflicts: &conflicts)
        }
        result.sessions = mergeList(base: base?.sessions, local: local.sessions, remote: remote.sessions,
                                    id: \.id, isDeleted: \.isDeleted) { base, local, remote in
            mergeSession(base: base, local: local, remote: remote, localWinsTie: localWinsTie)
        }
        result.totalCommentsCreated = max(local.totalCommentsCreated, remote.totalCommentsCreated)
        foldInboxes(&result, now: now)
        return Result(state: result, conflicts: conflicts)
    }

    // MARK: - Comments

    private struct Group: Sendable {
        let field: SyncConflict.Field?
        let equal: @Sendable (Comment, Comment) -> Bool
        let copy: @Sendable (inout Comment, Comment) -> Void
    }

    /// Fields that only make sense together travel together, so a merge never
    /// pairs one Mac's status with the other Mac's resolution summary.
    private static let groups: [Group] = [
        Group(field: .text, equal: { $0.commentText == $1.commentText }, copy: { $0.commentText = $1.commentText }),
        Group(field: .title, equal: { $0.customTitle == $1.customTitle }, copy: { $0.customTitle = $1.customTitle }),
        Group(field: .status, equal: {
            $0.status == $1.status && $0.resolutionSummary == $1.resolutionSummary
                && $0.resolvedBy == $1.resolvedBy && $0.resolvedAt == $1.resolvedAt
        }, copy: {
            $0.status = $1.status
            $0.resolutionSummary = $1.resolutionSummary
            $0.resolvedBy = $1.resolvedBy
            $0.resolvedAt = $1.resolvedAt
        }),
        Group(field: .session, equal: { $0.sessionID == $1.sessionID }, copy: { $0.sessionID = $1.sessionID }),
        Group(field: nil, equal: {
            $0.type == $1.type && $0.attachments == $1.attachments && $0.webContext == $1.webContext
                && $0.regionElements == $1.regionElements && $0.source == $1.source && $0.appBundleID == $1.appBundleID
        }, copy: {
            $0.type = $1.type
            $0.attachments = $1.attachments
            $0.webContext = $1.webContext
            $0.regionElements = $1.regionElements
            $0.source = $1.source
            $0.appBundleID = $1.appBundleID
        }),
    ]

    package static func copy(_ field: SyncConflict.Field, from source: Comment, to target: inout Comment) {
        groups.first { $0.field == field }?.copy(&target, source)
    }

    private static func mergeComment(base: Comment?, local: Comment, remote: Comment, localWinsTie: Bool,
                                     remoteName: String, now: Date, conflicts: inout [SyncConflict]) -> Comment {
        let localNewer = local.updatedAt == remote.updatedAt ? localWinsTie : local.updatedAt > remote.updatedAt
        var out = local
        for group in groups where !group.equal(local, remote) {
            // Without a base (first contact with a device) every difference counts
            // as a change on both sides: resolve it the same way, but do not report
            // a conflict nobody created.
            let localChanged = base.map { !group.equal($0, local) } ?? true
            let remoteChanged = base.map { !group.equal($0, remote) } ?? true
            switch (localChanged, remoteChanged) {
            case (false, _): group.copy(&out, remote)
            case (true, false): break
            case (true, true):
                if !localNewer { group.copy(&out, remote) }
                if let field = group.field, base != nil {
                    conflicts.append(SyncConflict(commentID: local.id, field: field, deviceName: remoteName,
                                                  localWon: localNewer, alternative: localNewer ? remote : local, date: now))
                }
            }
        }
        mergeDeletion(\.isDeleted, \.deletedAt, base: base, local: local, remote: remote, into: &out)
        out.updatedAt = max(local.updatedAt, remote.updatedAt)
        return out
    }

    // MARK: - Sessions

    private static func mergeSession(base: Session?, local: Session, remote: Session, localWinsTie: Bool) -> Session {
        var out = local
        take(\.name, base: base, local: local, remote: remote, into: &out, localWinsTie: localWinsTie)
        take(\.isPinned, base: base, local: local, remote: remote, into: &out, localWinsTie: localWinsTie)
        take(\.origin, base: base, local: local, remote: remote, into: &out, localWinsTie: localWinsTie)
        mergeDeletion(\.isDeleted, \.deletedAt, base: base, local: local, remote: remote, into: &out)
        mergeDeletion(\.isAutoDismissed, \.autoDismissedAt, base: base, local: local, remote: remote, into: &out)
        return out
    }

    /// Two Macs that each captured into an empty inbox create two inbox sessions.
    /// Every Mac keeps the same one and moves the other's tasks into it.
    private static func foldInboxes(_ state: inout AppState, now: Date) {
        let inboxes = state.sessions.filter { $0.isInbox }
        guard let keeper = inboxes.filter({ !$0.isDeleted }).min(by: { $0.id.uuidString < $1.id.uuidString }) else { return }
        let folded = Set(inboxes.map(\.id)).subtracting([keeper.id])
        for index in state.comments.indices where folded.contains(state.comments[index].sessionID) {
            state.comments[index].sessionID = keeper.id
        }
        for index in state.sessions.indices where folded.contains(state.sessions[index].id) && !state.sessions[index].isDeleted {
            state.sessions[index].isDeleted = true
            state.sessions[index].deletedAt = now
        }
        if let active = state.activeSessionID, folded.contains(active) { state.activeSessionID = keeper.id }
    }

    // MARK: - Shared rules

    /// A field changed on one side goes to that side; changed on both, to the tie-break.
    private static func take<T, V: Equatable>(_ path: WritableKeyPath<T, V>, base: T?, local: T, remote: T,
                                              into out: inout T, localWinsTie: Bool) {
        let mine = local[keyPath: path], theirs = remote[keyPath: path]
        guard mine != theirs else { return }
        let localChanged = base.map { $0[keyPath: path] != mine } ?? true
        let remoteChanged = base.map { $0[keyPath: path] != theirs } ?? true
        if !localChanged || (remoteChanged && !localWinsTie) { out[keyPath: path] = theirs }
    }

    /// Deletion is a decision: an unrelated edit or a stale copy never undoes it.
    /// An explicit restore on one side does, when the other side left it alone.
    private static func mergeDeletion<T>(_ flag: WritableKeyPath<T, Bool>, _ date: WritableKeyPath<T, Date?>,
                                         base: T?, local: T, remote: T, into out: inout T) {
        guard local[keyPath: flag] != remote[keyPath: flag] || local[keyPath: date] != remote[keyPath: date] else { return }
        func changed(_ side: T) -> Bool {
            base.map { $0[keyPath: flag] != side[keyPath: flag] || $0[keyPath: date] != side[keyPath: date] } ?? true
        }
        switch (changed(local), changed(remote)) {
        case (false, _):
            out[keyPath: flag] = remote[keyPath: flag]
            out[keyPath: date] = remote[keyPath: date]
        case (true, false): break
        case (true, true):
            let deleted = local[keyPath: flag] || remote[keyPath: flag]
            out[keyPath: flag] = deleted
            // The earliest decision; identical on every Mac.
            out[keyPath: date] = deleted
                ? [local, remote].filter { $0[keyPath: flag] }.compactMap { $0[keyPath: date] }.min()
                : nil
        }
    }

    /// Entities are matched by identifier. One that exists in the base but is gone
    /// from one side was pruned there; it stays gone only if the other side also
    /// deleted it. Without that rule, expired history would come back from
    /// whichever Mac pruned it last.
    private static func mergeList<T>(base: [T]?, local: [T], remote: [T], id: KeyPath<T, UUID>,
                                     isDeleted: KeyPath<T, Bool>, combine: (T?, T, T) -> T) -> [T] {
        let baseByID = base.map { Dictionary($0.map { ($0[keyPath: id], $0) }, uniquingKeysWith: { first, _ in first }) } ?? [:]
        let remoteByID = Dictionary(remote.map { ($0[keyPath: id], $0) }, uniquingKeysWith: { first, _ in first })
        var merged: [T] = []
        var seen = Set<UUID>()
        for item in local {
            let key = item[keyPath: id]
            guard seen.insert(key).inserted else { continue }
            if let theirs = remoteByID[key] {
                merged.append(combine(baseByID[key], item, theirs))
            } else if baseByID[key] == nil || !item[keyPath: isDeleted] {
                merged.append(item)
            }
        }
        for item in remote {
            let key = item[keyPath: id]
            guard seen.insert(key).inserted else { continue }
            if baseByID[key] == nil || !item[keyPath: isDeleted] { merged.append(item) }
        }
        return merged
    }
}
