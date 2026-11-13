import CoreLocalization
import FeatureComments
import FeatureSnapshotSync
import Foundation
import Combine
import AppKit

extension CommentStore {
    // MARK: - Persistence

    /// Flush and adopt local document changes before capturing a snapshot. The
    /// slot also drains a routine save's main-actor publication, not just IO.
    package func stateForSnapshot() async throws -> AppState {
        await acquireDocumentSlot()
        defer { releaseDocumentSlot() }
        while backgroundSaveInFlight { try await Task.sleep(for: .milliseconds(10)) }
        guard saveToDiskBlocking() else { throw SnapshotError.message(L10n.tr("Could not save local changes. Please try again.")) }
        return appState
    }

    package var snapshotReceipt: SnapshotReceipt? {
        guard let value = appState.unknownFields["_snapshotReceipt"],
              let bytes = try? JSONEncoder().encode(value) else { return nil }
        return try? JSONDecoder().decode(SnapshotReceipt.self, from: bytes)
    }

    package var snapshotContentStamp: SnapshotContentStamp? {
        guard let value = appState.unknownFields["_snapshotContentStamp"],
              let bytes = try? JSONEncoder().encode(value) else { return nil }
        return try? JSONDecoder().decode(SnapshotContentStamp.self, from: bytes)
    }

    package var snapshotUndo: SnapshotVersion? { SnapshotRollbackStore.version(in: appState) }

    package func recordSnapshotReceipt(_ receipt: SnapshotReceipt) async throws {
        await acquireDocumentSlot()
        defer { releaseDocumentSlot() }
        while backgroundSaveInFlight { try await Task.sleep(for: .milliseconds(10)) }
        appState.unknownFields["_snapshotReceipt"] = try JSONDecoder().decode(JSONValue.self, from: SnapshotArchive.encode(receipt))
        guard saveToDiskBlocking() else { throw SnapshotError.message(L10n.tr("The snapshot was published, but its local version label could not be saved. Check updates before retrying.")) }
    }

    /// Intentionally replaces the complete document. Never pass an imported
    /// snapshot through AppStateMerge: doing so resurrects local-only records.
    package func applySnapshot(_ prepared: SnapshotArchive.Prepared, version: SnapshotVersion, expected: AppState,
                       undo: SnapshotVersion? = nil, undoing: Bool = false) async throws {
        await acquireDocumentSlot()
        defer { releaseDocumentSlot() }
        while backgroundSaveInFlight { try await Task.sleep(for: .milliseconds(10)) }
        guard saveToDiskBlocking(), appState == expected else {
            throw SnapshotError.message(L10n.tr("Local data changed while preparing the snapshot. Nothing was replaced. Review it and try again."))
        }
        var replacement = prepared.state
        let selection = appState.activeSessionID
        replacement.activeSessionID = replacement.sessions.first(where: { $0.id == selection && !$0.isDeleted && !$0.isAutoDismissed })?.id
            ?? replacement.sessions.first(where: { $0.isInbox && !$0.isDeleted })?.id
            ?? replacement.sessions.first(where: { !$0.isDeleted && !$0.isAutoDismissed })?.id
        let receipt = SnapshotReceipt(version: version, contentHash: prepared.hash, appliedAt: Date(), localUpdatedAt: version.contentModifiedAt ?? version.createdAt)
        if undoing { replacement.unknownFields.removeValue(forKey: "_snapshotReceipt") }
        else { replacement.unknownFields["_snapshotReceipt"] = try JSONDecoder().decode(JSONValue.self, from: SnapshotArchive.encode(receipt)) }
        try SnapshotRollbackStore.set(undo, in: &replacement)
        replacement.snapshotDataUpdatedAt = undoing ? Date() : (version.contentModifiedAt ?? version.createdAt)
        let stamp = SnapshotContentStamp(contentHash: prepared.hash, modifiedAt: undoing ? Date() : version.contentModifiedAt)
        replacement.unknownFields["_snapshotContentStamp"] = try JSONDecoder().decode(JSONValue.self, from: SnapshotArchive.encode(stamp))
        try SnapshotReplacement.commit(replacement, expected: lastPersisted, fileURL: fileURL)
        snapshotGeneration += 1
        completionUndoDeadlines.removeAll()
        appState = replacement
        lastPersisted = replacement
        backgroundSaveRequested = false
        deferredSaveRequested = false
        // No webhooks, wake requests, retention pass, or screenshot-directory
        // setting changes: this is an explicit restore, not newly created work.
    }

    /// An annotation can replace image bytes without changing the comment's path.
    package func recordImageContentChange() {
        scheduleSave()
    }


}
