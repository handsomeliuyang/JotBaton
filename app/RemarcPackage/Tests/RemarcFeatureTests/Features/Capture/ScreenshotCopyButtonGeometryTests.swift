@testable import RemarcFeature
import Foundation
import Testing

@Suite("Screenshot copy button placement")
struct ScreenshotCopyButtonGeometryTests {
    @Test("The icon sits outside the composer, above its right edge")
    func aboveComposer() {
        let composer = CGRect(x: 100, y: 200, width: 340, height: 180)
        let icon = ScreenshotCopyButtonGeometry.frame(
            for: composer, visibleFrame: CGRect(x: 0, y: 0, width: 1200, height: 800))
        #expect(icon.maxX == composer.maxX)
        #expect(icon.minY == composer.maxY + 8)
        #expect(icon.size == CGSize(width: 30, height: 30))
        #expect(!icon.intersects(composer))
    }

    @Test("At the top of a display the icon falls below the composer")
    func topEdgeFallback() {
        let composer = CGRect(x: 100, y: 600, width: 340, height: 180)
        let visible = CGRect(x: 0, y: 0, width: 1200, height: 800)
        let icon = ScreenshotCopyButtonGeometry.frame(for: composer, visibleFrame: visible)
        #expect(icon.maxY == composer.minY - 8)
        #expect(icon.maxX == composer.maxX)
        #expect(visible.contains(icon))
    }

    @Test("Clamping uses the actual display origin, including negative coordinates")
    func secondaryDisplay() {
        let visible = CGRect(x: -1440, y: -100, width: 1440, height: 900)
        let composer = CGRect(x: -100, y: 10, width: 340, height: 180)
        let icon = ScreenshotCopyButtonGeometry.frame(for: composer, visibleFrame: visible)
        #expect(visible.contains(icon))
        #expect(icon.maxX == visible.maxX - 4)
        #expect(icon.minY == composer.maxY + 8)
    }
}
