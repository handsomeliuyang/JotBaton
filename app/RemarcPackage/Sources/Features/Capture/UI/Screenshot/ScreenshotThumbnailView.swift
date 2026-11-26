import CoreLocalization
import FeatureCapture
import SwiftUI
import AppKit

struct ScreenshotThumbnailView: View {
    @ObservedObject private var localization = LocalizationManager.shared
    let imagePath: String
    var maxWidth: CGFloat = 280
    var maxHeight: CGFloat = 200
    var cardFrame: ScreenshotThumbnailCache.CardFrame? = nil

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale
    @State private var thumbnail: ScreenshotThumbnailCache.Thumbnail?
    @State private var loadedURL: URL?
    /// Annotation and cloud updates replace bytes at the same path. Including
    /// their revision in the cache key ensures the new pixels are decoded.
    @ObservedObject private var revisions = StoredImageRevisionCenter.shared

    var body: some View {
        let url = resolveImagePath(imagePath)
        let request = makeRequest(url: url)
        Group {
            if loadedURL == url, let thumbnail {
                if let cardFrame {
                    let renderedSize = cardFrame.renderedSize(for: thumbnail.sourceSize)
                    Image(decorative: thumbnail.image, scale: displayScale)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: renderedSize.width, height: renderedSize.height, alignment: .top)
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .overlay(thumbnailBorder)
                } else {
                    let imageSize = thumbnail.sourceSize
                    let scale = imageSize.width > 0 && imageSize.height > 0
                        ? min(maxWidth / imageSize.width, maxHeight / imageSize.height, 1.0)
                        : 1.0
                    Image(decorative: thumbnail.image, scale: displayScale)
                        .resizable()
                        .frame(width: imageSize.width * scale, height: imageSize.height * scale)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .overlay(thumbnailBorder)
                }
            } else {
                placeholderView
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

    private func makeRequest(url: URL) -> ScreenshotThumbnailCache.Request {
        let revision = revisions.revision(for: imagePath)
        if let cardFrame {
            return ScreenshotThumbnailCache.Request(
                url: url,
                revision: revision,
                maxPixelSize: Int(ceil(max(cardFrame.width, cardFrame.maxHeight) * displayScale)),
                cardFrame: cardFrame,
                displayScale: displayScale
            )
        }
        return ScreenshotThumbnailCache.Request(
            url: url,
            revision: revision,
            maxPixelSize: Int(ceil(max(maxWidth, maxHeight) * displayScale))
        )
    }

    @ViewBuilder
    private var placeholderView: some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(Color.primary.opacity(0.06))
        Group {
            if let cardFrame {
                let placeholderHeight = min(max(60, cardFrame.minHeight), cardFrame.maxHeight)
                shape.frame(width: cardFrame.width, height: placeholderHeight)
            } else {
                shape
                    .frame(maxWidth: maxWidth)
                    .frame(height: 60)
            }
        }
        .overlay(
            Image(systemName: "photo")
                .font(.system(size: 18))
                .foregroundStyle(.primary.opacity(0.25))
        )
        .overlay(thumbnailBorder)
    }

    private var thumbnailBorder: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .inset(by: 0.5)
            .stroke(
                colorScheme == .dark
                    ? Color.white.opacity(0.15)
                    : Color.black.opacity(0.1),
                lineWidth: 0.5
            )
    }
}
