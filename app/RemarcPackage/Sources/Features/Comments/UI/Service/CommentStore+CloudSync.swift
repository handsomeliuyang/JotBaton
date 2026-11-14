import CoreLocalization
import FeatureComments
import FeatureCloudSync
import Foundation

extension CommentStore {
    /// Flush and adopt local document changes before sync reads them. The slot
    /// also drains a routine save's main-actor publication, not just IO.
    package func stateForSync() async throws -> AppState {
        await acquireDocumentSlot()
        defer { releaseDocumentSlot() }
        while backgroundSaveInFlight { try await Task.sleep(for: .milliseconds(10)) }
        guard saveToDiskBlocking() else { throw CloudSyncError.message(L10n.tr("Could not save local changes. Please try again.")) }
        return appState
    }

    package func commitSyncedState(_ transform: (AppState) -> AppState) async throws -> AppState {
        await acquireDocumentSlot()
        defer { releaseDocumentSlot() }
        while backgroundSaveInFlight { try await Task.sleep(for: .milliseconds(10)) }
        guard saveToDiskBlocking() else { throw CloudSyncError.message(L10n.tr("Could not save local changes. Please try again.")) }
        let next = transform(appState)
        guard next != appState else { return appState }
        appState = next
        guard saveToDiskBlocking() else {
            // The merge is already in memory; let the routine save retry the write.
            scheduleSave()
            throw CloudSyncError.message(L10n.tr("Could not save local changes. Please try again."))
        }
        return appState
    }

    /// An annotation can replace image bytes without changing the comment's path.
    package func recordImageContentChange() {
        scheduleSave()
    }
}
