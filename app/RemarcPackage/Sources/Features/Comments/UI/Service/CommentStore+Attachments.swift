import CorePlatform
import CoreUI
import FeatureCapture
import Foundation
import Combine
import AppKit

extension CommentStore {
    // MARK: - Attachment Image Saving

    /// Save an image as a PNG attachment, downsampling if larger than 2048px.
    /// Returns the relative path (e.g. "images/UUID.png") or nil on failure.
    public func saveAttachmentImage(_ image: NSImage) -> String? {
        let maxDimension: CGFloat = 2048
        var targetImage = image

        // Downsample if needed
        let size = image.size
        if max(size.width, size.height) > maxDimension {
            let scale = maxDimension / max(size.width, size.height)
            let newSize = NSSize(width: size.width * scale, height: size.height * scale)
            let resized = NSImage(size: newSize)
            resized.lockFocus()
            image.draw(in: NSRect(origin: .zero, size: newSize),
                       from: NSRect(origin: .zero, size: size),
                       operation: .copy, fraction: 1.0)
            resized.unlockFocus()
            targetImage = resized
        }

        guard let pngData = targetImage.pngData() else {
            debugLog("CommentStore: Failed to create PNG data for attachment")
            return nil
        }

        do {
            let stored = try writeNewScreenshotData(pngData)
            debugLog("CommentStore: Saved attachment image \(stored)")
            return stored
        } catch {
            debugLog("CommentStore: Failed to save attachment image - \(error)")
            return nil
        }
    }


}
