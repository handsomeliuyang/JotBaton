import CoreLocalization
import FeatureCapture
import SwiftUI
import AppKit

struct ScreenshotThumbnailView: View {
    @ObservedObject private var localization = LocalizationManager.shared
    let imagePath: String
    var maxWidth: CGFloat = 280
    var maxHeight: CGFloat = 200

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale
    @State private var thumbnail: ScreenshotThumbnailCache.Thumbnail?
    @State private var loadedURL: URL?
    /// Annotation and cloud updates replace bytes at the same path. Including
    /// their revision in the cache key ensures the new pixels are decoded.
    @ObservedObject private var revisions = StoredImageRevisionCenter.shared

    var body: some View {
        let url = resolveImagePath(imagePath)
        let request = ScreenshotThumbnailCache.Request(
            url: url, revision: revisions.revision(for: imagePath),
            maxPixelSize: Int(ceil(max(maxWidth, maxHeight) * displayScale))
        )
        Group {
            if loadedURL == url, let thumbnail {
                let imageSize = thumbnail.sourceSize
                let scale = imageSize.width > 0 && imageSize.height > 0
                    ? min(maxWidth / imageSize.width, maxHeight / imageSize.height, 1.0)
                    : 1.0
                Image(decorative: thumbnail.image, scale: displayScale)
                    .resizable()
                    .frame(width: imageSize.width * scale, height: imageSize.height * scale)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .inset(by: 0.5)
                            .stroke(
                                colorScheme == .dark
                                    ? Color.white.opacity(0.15)
                                    : Color.black.opacity(0.1),
                                lineWidth: 0.5
                            )
                    )
            } else {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
                    .frame(maxWidth: maxWidth)
                    .frame(height: 60)
                    .overlay(
                        Image(systemName: "photo")
                            .font(.system(size: 18))
                            .foregroundStyle(.primary.opacity(0.25))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .inset(by: 0.5)
                            .stroke(
                                colorScheme == .dark
                                    ? Color.white.opacity(0.15)
                                    : Color.black.opacity(0.1),
                                lineWidth: 0.5
                            )
                    )
            }
        }
        .task(id: request) {
            let result = await ScreenshotThumbnailCache.shared.thumbnail(for: request)
            guard !Task.isCancelled else { return }
            // Retain the previous thumbnail while reloading an annotated image;
            // replacing pixels should not collapse the card to a placeholder.
            thumbnail = result
            loadedURL = url
        }
        .transaction { $0.animation = nil }
    }
}
