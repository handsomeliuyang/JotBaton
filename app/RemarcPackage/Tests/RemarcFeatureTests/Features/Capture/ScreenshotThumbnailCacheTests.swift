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

    @Test("CardFrame clamps height between minHeight and maxHeight for wide, normal, and tall images")
    func cardFrameRenderedSize() {
        let frame = ScreenshotThumbnailCache.CardFrame(width: 120, minHeight: 56, maxHeight: 90)
        #expect(frame.renderedSize(for: CGSize(width: 2400, height: 400)) == CGSize(width: 120, height: 56))
        #expect(frame.renderedSize(for: CGSize(width: 1200, height: 750)) == CGSize(width: 120, height: 75))
        #expect(frame.renderedSize(for: CGSize(width: 600, height: 2400)) == CGSize(width: 120, height: 90))
    }

    @Test("CardFrame crops tall images from the top and isolates its cache entry from standard thumbnails")
    func cardFrameTopCropAndCacheIsolation() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("card-tall-\(UUID()).png")
        defer { try? FileManager.default.removeItem(at: url) }

        // Top half red, bottom half blue (600x1800 tall page screenshot).
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = try #require(CGContext(
            data: nil, width: 600, height: 1800,
            bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ))
        // CGContext origin is bottom-left: y [0, 900) is bottom (blue), y [900, 1800) is top (red).
        ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 600, height: 900))
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 900, width: 600, height: 900))
        let tallImage = try #require(ctx.makeImage())
        try AnnotationExporter.pngData(from: tallImage).write(to: url)

        let cache = ScreenshotThumbnailCache()
        let frame = ScreenshotThumbnailCache.CardFrame(width: 120, minHeight: 56, maxHeight: 90)
        let cardReq = ScreenshotThumbnailCache.Request(
            url: url, revision: 0, maxPixelSize: 240, cardFrame: frame, displayScale: 2
        )
        let standardReq = ScreenshotThumbnailCache.Request(url: url, revision: 0, maxPixelSize: 240)

        let cardThumb = try #require(await cache.thumbnail(for: cardReq))
        let standardThumb = try #require(await cache.thumbnail(for: standardReq))

        // Card thumbnail fills 120x90 @2x = 240x180 and keeps the top (red) portion.
        #expect(cardThumb.image.width == 240)
        #expect(cardThumb.image.height == 180)
        #expect(TestImages.pixel(cardThumb.image, x: 120, y: 10)[0] > 240)
        #expect(TestImages.pixel(cardThumb.image, x: 120, y: 170)[0] > 240)
        #expect(TestImages.pixel(cardThumb.image, x: 120, y: 170)[2] < 20)

        // Standard thumbnail stays aspect-fit (80x240) and does not collide in cache.
        #expect(standardThumb.image.width == 80)
        #expect(standardThumb.image.height == 240)
        #expect(cardThumb.image !== standardThumb.image)
    }

    @Test("CardFrame fills wide images cleanly to clamped minHeight")
    func cardFrameWideImageFill() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("card-wide-\(UUID()).png")
        defer { try? FileManager.default.removeItem(at: url) }

        let wide = TestImages.solid(width: 2400, height: 400, red: 0, green: 1, blue: 0)
        try AnnotationExporter.pngData(from: wide).write(to: url)

        let cache = ScreenshotThumbnailCache()
        let frame = ScreenshotThumbnailCache.CardFrame(width: 120, minHeight: 56, maxHeight: 90)
        let req = ScreenshotThumbnailCache.Request(
            url: url, revision: 0, maxPixelSize: 240, cardFrame: frame, displayScale: 2
        )
        let thumb = try #require(await cache.thumbnail(for: req))
        #expect(thumb.image.width == 240)
        #expect(thumb.image.height == 112)
        #expect(thumb.sourceSize == CGSize(width: 2400, height: 400))
    }
}
