import Foundation
import CoreGraphics
import ImageIO

/// Disk reads and decoding run on this actor, away from the UI. Only downsampled
/// pixels are retained; full-resolution images remain exclusive to the editor.
public actor ScreenshotThumbnailCache {
    public static let shared = ScreenshotThumbnailCache()

    public struct CardFrame: Hashable, Sendable {
        public let width: CGFloat
        public let minHeight: CGFloat
        public let maxHeight: CGFloat

        public init(width: CGFloat, minHeight: CGFloat, maxHeight: CGFloat) {
            self.width = width
            self.minHeight = minHeight
            self.maxHeight = maxHeight
        }

        /// Computes the rendered point size for a source image of `sourceSize`.
        /// Width stays fixed at `width`; height tracks the aspect ratio clamped to `[minHeight, maxHeight]`.
        public func renderedSize(for sourceSize: CGSize) -> CGSize {
            guard sourceSize.width > 0, sourceSize.height > 0 else {
                return CGSize(width: width, height: minHeight)
            }
            let proportionalHeight = width * (sourceSize.height / sourceSize.width)
            let clampedHeight = min(max(proportionalHeight, minHeight), maxHeight)
            return CGSize(width: width, height: clampedHeight)
        }
    }

    public struct Request: Hashable, Sendable {
        public let url: URL
        public let revision: Int
        public let maxPixelSize: Int
        public let cardFrame: CardFrame?
        public let displayScale: CGFloat

        public init(
            url: URL,
            revision: Int,
            maxPixelSize: Int,
            cardFrame: CardFrame? = nil,
            displayScale: CGFloat = 1
        ) {
            self.url = url
            self.revision = revision
            self.maxPixelSize = maxPixelSize
            self.cardFrame = cardFrame
            self.displayScale = displayScale
        }
    }

    public struct Thumbnail: Sendable {
        public let image: CGImage
        public let sourceSize: CGSize
    }

    private final class Entry {
        let thumbnail: Thumbnail
        init(_ thumbnail: Thumbnail) { self.thumbnail = thumbnail }
    }

    private let cache = NSCache<NSString, Entry>()

    public init() {
        cache.totalCostLimit = 32 * 1024 * 1024
        cache.countLimit = 256
    }

    private static let maxCardDecodePixelSize = 4096

    public func thumbnail(for request: Request) -> Thumbnail? {
        let key = cacheKey(for: request)
        if let entry = cache.object(forKey: key) { return entry.thumbnail }
        guard let source = CGImageSourceCreateWithURL(request.url as CFURL, [
                kCGImageSourceShouldCache: false
              ] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else { return nil }

        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let rotated = (5...8).contains(orientation)
        let sourceSize = CGSize(
            width: rotated ? height.doubleValue : width.doubleValue,
            height: rotated ? width.doubleValue : height.doubleValue
        )
        guard sourceSize.width > 0, sourceSize.height > 0 else { return nil }

        let image: CGImage
        if let cardFrame = request.cardFrame {
            guard cardFrame.width > 0,
                  cardFrame.minHeight > 0,
                  cardFrame.maxHeight >= cardFrame.minHeight,
                  request.displayScale > 0 else { return nil }
            let renderedSize = cardFrame.renderedSize(for: sourceSize)
            let targetWidth = renderedSize.width * request.displayScale
            let targetHeight = renderedSize.height * request.displayScale
            let fillScale = min(1.0, max(targetWidth / sourceSize.width, targetHeight / sourceSize.height))
            let decodeMaxPixel = min(
                Self.maxCardDecodePixelSize,
                max(1, Int(ceil(max(sourceSize.width, sourceSize.height) * fillScale)))
            )
            guard let decoded = decodeThumbnail(from: source, maxPixelSize: decodeMaxPixel) else { return nil }
            let targetAspect = renderedSize.width / renderedSize.height
            let cropRect = Self.topAlignedFillCropRect(
                imageWidth: decoded.width,
                imageHeight: decoded.height,
                targetAspect: targetAspect
            )
            if Int(cropRect.width) < decoded.width || Int(cropRect.height) < decoded.height,
               let cropped = decoded.cropping(to: cropRect) {
                image = cropped
            } else {
                image = decoded
            }
        } else {
            guard request.maxPixelSize > 0,
                  let decoded = decodeThumbnail(from: source, maxPixelSize: request.maxPixelSize) else { return nil }
            image = decoded
        }

        let thumbnail = Thumbnail(image: image, sourceSize: sourceSize)
        cache.setObject(Entry(thumbnail), forKey: key, cost: image.bytesPerRow * image.height)
        return thumbnail
    }

    private func cacheKey(for request: Request) -> NSString {
        if let cardFrame = request.cardFrame {
            let w = Int(cardFrame.width.rounded())
            let minH = Int(cardFrame.minHeight.rounded())
            let maxH = Int(cardFrame.maxHeight.rounded())
            let scale = Int((request.displayScale * 100).rounded())
            return "\(request.url.absoluteString)|\(request.revision)|card:\(w)x\(minH)-\(maxH)@\(scale)" as NSString
        }
        return "\(request.url.absoluteString)|\(request.revision)|\(request.maxPixelSize)" as NSString
    }

    private func decodeThumbnail(from source: CGImageSource, maxPixelSize: Int) -> CGImage? {
        CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ] as CFDictionary)
    }

    /// Returns a top-aligned aspect-fill crop rectangle in CGImage's top-left pixel space.
    /// Wide images are horizontally centered; tall images keep the top region.
    static func topAlignedFillCropRect(imageWidth: Int, imageHeight: Int, targetAspect: CGFloat) -> CGRect {
        guard imageWidth > 0, imageHeight > 0, targetAspect > 0 else {
            return CGRect(x: 0, y: 0, width: max(0, imageWidth), height: max(0, imageHeight))
        }
        let imageAspect = CGFloat(imageWidth) / CGFloat(imageHeight)
        if imageAspect > targetAspect {
            let cropWidth = max(1, min(imageWidth, Int((CGFloat(imageHeight) * targetAspect).rounded())))
            let cropX = max(0, (imageWidth - cropWidth) / 2)
            return CGRect(x: cropX, y: 0, width: cropWidth, height: imageHeight)
        } else {
            let cropHeight = max(1, min(imageHeight, Int((CGFloat(imageWidth) / targetAspect).rounded())))
            return CGRect(x: 0, y: 0, width: imageWidth, height: cropHeight)
        }
    }
}
