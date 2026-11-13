@testable import RemarcFeature
import XCTest

@MainActor
final class QuickNoteDraftTests: XCTestCase {
    func testRepeatedQuickNoteKeepsExistingDraftAndSession() {
        let controller = FloatingEditorController()
        let sessionID = UUID()
        controller.isVisible = true
        controller.currentText = "Keep this draft"
        controller.currentAttachments = ["attachment.png"]
        controller.targetSessionID = sessionID
        let generation = controller.currentPresentationGeneration

        controller.showForQuickNote()

        XCTAssertTrue(controller.isVisible)
        XCTAssertEqual(controller.currentText, "Keep this draft")
        XCTAssertEqual(controller.currentAttachments, ["attachment.png"])
        XCTAssertEqual(controller.targetSessionID, sessionID)
        XCTAssertEqual(controller.currentPresentationGeneration, generation)
    }

    func testQuickNoteDoesNotReplaceOpenCommentComposer() {
        let composer = CommentInputController.shared
        let wasVisible = composer.isVisible
        let oldText = composer.currentText
        let oldAttachments = composer.currentAttachments
        defer {
            composer.isVisible = wasVisible
            composer.currentText = oldText
            composer.currentAttachments = oldAttachments
        }
        composer.isVisible = true
        composer.currentText = "Unfinished contextual comment"
        composer.currentAttachments = ["existing.png"]
        let generation = composer.currentDraftGeneration
        let controller = FloatingEditorController()

        controller.showForQuickNote()

        XCTAssertFalse(controller.isVisible)
        XCTAssertTrue(composer.isVisible)
        XCTAssertEqual(composer.currentText, "Unfinished contextual comment")
        XCTAssertEqual(composer.currentAttachments, ["existing.png"])
        XCTAssertEqual(composer.currentDraftGeneration, generation)
    }
}
