import CorePlatform
import FeatureComments
import Foundation
import Combine
import AppKit

extension CommentStore {
    // MARK: - Transcription Operations

    public var transcriptions: [Transcription] {
        appState.transcriptions
            .filter { !$0.isDeleted }
            .sorted { $0.createdAt > $1.createdAt }
    }

    @discardableResult
    public func addTranscription(text: String, appBundleID: String?, appName: String?) -> Transcription {
        let transcription = Transcription(
            text: text,
            appBundleID: appBundleID,
            appName: appName
        )
        appState.transcriptions.append(transcription)
        scheduleSave()
        debugLog("CommentStore: Added transcription \(transcription.id.uuidString.prefix(8))")
        return transcription
    }

    public func deleteTranscription(_ id: UUID) {
        guard let index = appState.transcriptions.firstIndex(where: { $0.id == id }) else { return }
        appState.transcriptions[index].isDeleted = true
        appState.transcriptions[index].deletedAt = Date()
        scheduleSave()
    }

    public func permanentlyDeleteTranscription(_ id: UUID) {
        appState.transcriptions.removeAll { $0.id == id }
        scheduleSave()
    }


}
