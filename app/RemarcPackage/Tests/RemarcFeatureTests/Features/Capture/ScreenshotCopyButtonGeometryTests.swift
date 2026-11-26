@testable import RemarcFeature
import Foundation
import Testing

@Suite("Screenshot copy button placement")
struct ScreenshotCopyButtonGeometryTests {
    @Test("The capsule sits outside the composer, aligned to its right edge")
    func aboveComposer() {
        let composer = CGRect(x: 100, y: 200, width: 340, height: 180)
        let capsuleSize = CGSize(width: 132, height: 28)
        let capsule = ScreenshotCopyButtonGeometry.frame(
            for: composer, size: capsuleSize, visibleFrame: CGRect(x: 0, y: 0, width: 1200, height: 800))
        #expect(capsule.maxX == composer.maxX)
        #expect(capsule.minY == composer.maxY + 8)
        #expect(capsule.size == capsuleSize)
        #expect(!capsule.intersects(composer))
    }

    @Test("At the top of a display the capsule falls below the composer")
    func topEdgeFallback() {
        let composer = CGRect(x: 100, y: 600, width: 340, height: 180)
        let visible = CGRect(x: 0, y: 0, width: 1200, height: 800)
        let capsule = ScreenshotCopyButtonGeometry.frame(for: composer, visibleFrame: visible)
        #expect(capsule.maxY == composer.minY - 8)
        #expect(capsule.maxX == composer.maxX)
        #expect(visible.contains(capsule))
    }

    @Test("Clamping uses the actual display origin, including negative coordinates")
    func secondaryDisplay() {
        let visible = CGRect(x: -1440, y: -100, width: 1440, height: 900)
        let composer = CGRect(x: -100, y: 10, width: 340, height: 180)
        let capsule = ScreenshotCopyButtonGeometry.frame(for: composer, visibleFrame: visible)
        #expect(visible.contains(capsule))
        #expect(capsule.maxX == visible.maxX - 4)
        #expect(capsule.minY == composer.maxY + 8)
    }

    @Test("Cmd+C copies the screenshot from the composer only when empty with no selection or IME composition")
    @MainActor
    func composerCommandCShortcutPolicy() {
        #expect(CommentInputController.composerAllowsImageCopyShortcut(
            text: "", selectedLength: 0, hasMarkedText: false))
        #expect(!CommentInputController.composerAllowsImageCopyShortcut(
            text: "draft", selectedLength: 0, hasMarkedText: false))
        #expect(!CommentInputController.composerAllowsImageCopyShortcut(
            text: "", selectedLength: 2, hasMarkedText: false))
        #expect(!CommentInputController.composerAllowsImageCopyShortcut(
            text: "", selectedLength: 0, hasMarkedText: true))
    }

    @Test("Annotation dismissal resolves cleanly for composer, canvas, and toolbar focus")
    @MainActor
    func annotationDismissalPolicy() {
        #expect(ScreenCaptureCoordinator.dismissalAction(
            origin: .composer, hasActiveTextEdit: false, showsDiscardControls: false,
            isToolbarKey: false, isDirty: false) == .passThroughToComposer)
        #expect(ScreenCaptureCoordinator.dismissalAction(
            origin: .canvas, hasActiveTextEdit: false, showsDiscardControls: false,
            isToolbarKey: false, isDirty: false) == .exitToSelection)
        #expect(ScreenCaptureCoordinator.dismissalAction(
            origin: .toolbar, hasActiveTextEdit: false, showsDiscardControls: false,
            isToolbarKey: true, isDirty: false) == .focusCanvasFromToolbar)
        #expect(ScreenCaptureCoordinator.dismissalAction(
            origin: .composer, hasActiveTextEdit: false, showsDiscardControls: false,
            isToolbarKey: false, isDirty: true) == .showDiscardControls)
        #expect(ScreenCaptureCoordinator.dismissalAction(
            origin: .canvas, hasActiveTextEdit: false, showsDiscardControls: false,
            isToolbarKey: false, isDirty: true) == .showDiscardControls)
        #expect(ScreenCaptureCoordinator.dismissalAction(
            origin: .toolbar, hasActiveTextEdit: false, showsDiscardControls: true,
            isToolbarKey: true, isDirty: true) == .hideDiscardControls)
        #expect(ScreenCaptureCoordinator.dismissalAction(
            origin: .composer, hasActiveTextEdit: true, showsDiscardControls: false,
            isToolbarKey: false, isDirty: false) == .resolveTextEdit)
    }
}
