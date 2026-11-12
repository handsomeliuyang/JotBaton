import FeatureComments
import Foundation
import Combine
import AppKit

extension CommentStore {
    // MARK: - History

    public var deletedComments: [Comment] {
        appState.comments.filter { $0.isDeleted }
    }

    public var deletedSessions: [Session] {
        appState.sessions.filter { $0.isDeleted || $0.isAutoDismissed }
    }


}
