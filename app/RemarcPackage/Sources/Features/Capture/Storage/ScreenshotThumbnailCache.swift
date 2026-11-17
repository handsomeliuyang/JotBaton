import Foundation
import CoreGraphics
import ImageIO

/// Disk reads and decoding run on this actor, away from the UI. Only downsampled
/// pixels are retained; full-resolution images remain exclusive to the editor.
public actor ScreenshotThumbnailCache {
    public static let shared = ScreenshotThumbnailCache()

    public struct Request: Hashable, Sendable {
        public let url: URL
        public let revision: Int
        public let maxPixelSize: Int

        public init(url: URL, revision: Int, maxPixelSize: Int) {
            self.url = url
            self.revision = revision
            self.maxPixelSize = maxPixelSize
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

    public func thumbnail(for request: Request) -> Thumbnail? {
        let key = "\(request.url.absoluteString)|\(request.revision)|\(request.maxPixelSize)" as NSString
        if let entry = cache.object(forKey: key) { return entry.thumbnail }
        guard request.maxPixelSize > 0,
              let source = CGImageSourceCreateWithURL(request.url as CFURL, [
                kCGImageSourceShouldCache: false
              ] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: request.maxPixelSize
              ] as CFDictionary) else { return nil }

        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let rotated = (5...8).contains(orientation)
        let size = CGSize(width: rotated ? height.doubleValue : width.doubleValue,
                          height: rotated ? width.doubleValue : height.doubleValue)
        let thumbnail = Thumbnail(image: image, sourceSize: size)
        cache.setObject(Entry(thumbnail), forKey: key, cost: image.bytesPerRow * image.height)
        return thumbnail
    }
}
