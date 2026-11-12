import CorePlatform
import FeatureCapture
import Foundation
import Combine
import AppKit

extension CommentStore {
    // MARK: - Prepared-capture leases

    /// True when any comment (including soft-deleted ones), attachment, or
    /// retained orphan still points at `relativePath`.
    ///
    /// Soft-deleted comments count: their images are retained on purpose until
    /// their history retention period expires.
    public func referencesImage(_ relativePath: String) -> Bool {
        for comment in appState.comments {
            if case .screenshot(let imagePath) = comment.type, imagePath == relativePath { return true }
            if comment.attachments.contains(relativePath) { return true }
        }
        return appState.orphanedImages.contains { $0.path == relativePath }
    }

    /// Delete prepared PNGs left behind by a process that is confirmed gone.
    /// Never enumerates the images directory.
    func reconcilePreparedCaptureLeases() {
        let result = PreparedCaptureLeaseRegistry.reconcile { [weak self] path in
            guard let self else { return true }   // cannot prove unreferenced: keep
            return self.referencesImage(path)
        }
        guard !result.deleted.isEmpty || !result.keptReferenced.isEmpty
                || !result.keptFailed.isEmpty || !result.rejectedPath.isEmpty else { return }
        debugLog("CommentStore: Lease reconcile - deleted \(result.deleted.count), "
                 + "kept referenced \(result.keptReferenced.count), "
                 + "kept failed \(result.keptFailed.count), "
                 + "kept live \(result.keptLive.count), rejected path \(result.rejectedPath.count)")
    }


}
