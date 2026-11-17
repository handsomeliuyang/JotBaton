@testable import FeatureCapture
import CoreGraphics
import Foundation
import Testing

@Suite("Screenshot thumbnail cache")
struct ScreenshotThumbnailCacheTests {
    @Test("Downsamples images, reuses decoded pixels, and reloads after annotation revision")
    func downsamplingAndRevision() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("thumbnail-\(UUID()).png")
        defer { try? FileManager.default.removeItem(at: url) }
        let red = TestImages.solid(width: 1600, height: 800, red: 1, green: 0, blue: 0)
        try AnnotationExporter.pngData(from: red).write(to: url)
        let cache = ScreenshotThumbnailCache()
        let request = ScreenshotThumbnailCache.Request(url: url, revision: 0, maxPixelSize: 280)
        let first = try #require(await cache.thumbnail(for: request))
        #expect(first.image.width == 280)
        #expect(first.image.height == 140)
        #expect(first.sourceSize == CGSize(width: 1600, height: 800))
        let reused = try #require(await cache.thumbnail(for: request))
        #expect(first.image === reused.image)

        let green = TestImages.solid(width: 1600, height: 800, red: 0, green: 1, blue: 0)
        try AnnotationExporter.pngData(from: green).write(to: url, options: .atomic)
        let updated = try #require(await cache.thumbnail(for: .init(url: url, revision: 1, maxPixelSize: 280)))
        #expect(TestImages.pixel(first.image, x: 0, y: 0)[0] > 240)
        #expect(TestImages.pixel(updated.image, x: 0, y: 0)[1] > 240)
        #expect(first.sourceSize == updated.sourceSize)
    }

    @Test("Missing files can be retried when they become available")
    func retryMissingImage() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("thumbnail-\(UUID()).png")
        defer { try? FileManager.default.removeItem(at: url) }
        let cache = ScreenshotThumbnailCache()
        let request = ScreenshotThumbnailCache.Request(url: url, revision: 0, maxPixelSize: 140)
        #expect(await cache.thumbnail(for: request) == nil)
        let image = TestImages.solid(width: 40, height: 80, red: 0, green: 0, blue: 1)
        try AnnotationExporter.pngData(from: image).write(to: url)
        let thumbnail = try #require(await cache.thumbnail(for: request))
        #expect(thumbnail.image.width <= 140)
        #expect(thumbnail.image.height <= 140)
        #expect(thumbnail.sourceSize == CGSize(width: 40, height: 80))
    }
}
