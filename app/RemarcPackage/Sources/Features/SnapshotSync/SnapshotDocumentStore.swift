import FeatureComments
import Combine

/// The snapshot feature needs a coherent document, never the application UI or
/// a concrete persistence singleton. The application supplies this transaction port.
@MainActor
package protocol SnapshotDocumentStore: AnyObject {
    var appState: AppState { get }
    var statePublisher: AnyPublisher<AppState, Never> { get }
    var snapshotReceipt: SnapshotReceipt? { get }
    var snapshotUndo: SnapshotVersion? { get }
    var snapshotContentStamp: SnapshotContentStamp? { get }
    func stateForSnapshot() async throws -> AppState
    func recordSnapshotReceipt(_ receipt: SnapshotReceipt) async throws
    func applySnapshot(_ prepared: SnapshotArchive.Prepared, version: SnapshotVersion,
                       expected: AppState, undo: SnapshotVersion?, undoing: Bool) async throws
}
