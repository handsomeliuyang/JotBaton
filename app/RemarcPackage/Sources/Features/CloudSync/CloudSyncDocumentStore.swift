import FeatureComments
import Combine

/// The sync feature needs a coherent document, never the application UI or
/// a concrete persistence singleton. The application supplies this transaction port.
@MainActor
package protocol CloudSyncDocumentStore: AnyObject {
    var appState: AppState { get }
    var statePublisher: AnyPublisher<AppState, Never> { get }
    /// Flushes pending edits and returns the saved document.
    func stateForSync() async throws -> AppState
    /// Saves pending edits, applies `transform` to the saved document and writes
    /// the result through the ordinary locked three-way save, so commits from
    /// other processes on this Mac survive. Returns the committed document.
    /// Synced changes are not new work on this Mac: no webhooks.
    func commitSyncedState(_ transform: (AppState) -> AppState) async throws -> AppState
}
