import FeatureComments
import FeatureIntegrations
import FeatureSnapshotSync
import AppKit
import Combine

/// Application-lifetime dependencies and cross-feature wiring. The comment
/// workflow emits changes without knowing about webhook configuration or delivery.
@MainActor
final class AppServices {
    static let shared = AppServices()
    let comments: CommentStore
    lazy var snapshots = SnapshotSyncManager(documents: comments)
    lazy var capture = ScreenCaptureCoordinator(composer: { CommentInputController.shared })

    private init() {
        comments = CommentStore(onCommentChange: { change, comment in
            let event: WebhookEventType
            switch change {
            case .commentCreated: event = .commentCreated
            case .commentUpdated: event = .commentUpdated
            case .commentDeleted: event = .commentDeleted
            case .commentResolved: event = .commentResolved
            case .commentStatusChanged: event = .commentStatusChanged
            }
            WebhookService.shared.dispatch(event, comment: comment)
        })
    }
}

@MainActor
extension CommentInputController: ScreenshotComposer {
    var annotationPanelReserve: CGFloat { Self.panelReserve }
}

@MainActor
extension CommentStore: SnapshotDocumentStore {
    package var statePublisher: AnyPublisher<AppState, Never> { $appState.eraseToAnyPublisher() }
}
