import AppKit
import XCTest
@testable import RemarcFeature

@MainActor
final class AnnotationTextInputTests: XCTestCase {
    private let insertion = NSRange(location: NSNotFound, length: 0)

    private func withCanvas(_ body: (AnnotationSession, AnnotationCanvasNSView, NSWindow) throws -> Void) throws {
        let session = AnnotationSession(source: TestImages.solid(width: 320, height: 200,
                                                                 red: 1, green: 1, blue: 1))
        session.tool = .text
        let canvas = AnnotationCanvasNSView(pixelSize: session.pixelSize, session: session)
        let window = NSWindow(contentRect: CGRect(x: 120, y: 140, width: 800, height: 600),
                              styleMask: .titled, backing: .buffered, defer: false)
        let host = NSView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        window.contentView = host
        host.addSubview(canvas)
        defer { window.contentView = nil; window.orderOut(nil) }
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown, location: canvas.convert(CGPoint(x: 40, y: 50), to: nil),
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        canvas.mouseDown(with: event)
        try body(session, canvas, window)
    }

    func testPinyinCompositionIsReplacedByChineseBeforeTheLabelCommits() throws {
        try withCanvas { session, canvas, _ in
            XCTAssertNotNil(canvas.inputContext, "the system needs a real text input context")
            canvas.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: insertion)
            canvas.setMarkedText("nihao", selectedRange: NSRange(location: 5, length: 0), replacementRange: insertion)
            XCTAssertEqual(session.pendingText?.string, "nihao")
            XCTAssertEqual(canvas.markedRange(), NSRange(location: 0, length: 5))
            XCTAssertTrue(session.items.isEmpty, "intermediate composition is not an annotation history step")

            canvas.insertText(NSAttributedString(string: "你好"), replacementRange: insertion)
            XCTAssertEqual(session.pendingText?.string, "你好")
            XCTAssertFalse(canvas.hasMarkedText())
            XCTAssertEqual(canvas.selectedRange(), NSRange(location: 2, length: 0))
            XCTAssertTrue(session.items.isEmpty, "confirming an IME candidate must keep the label editable")

            canvas.doCommand(by: #selector(NSResponder.insertNewline(_:)))
            XCTAssertFalse(canvas.hasActiveTextEdit)
            XCTAssertEqual(session.items.count, 1)
            guard case .text(let text, _, _) = session.items.first?.payload else {
                return XCTFail("the label must commit as editable text")
            }
            XCTAssertEqual(text, "你好")
            session.undo()
            XCTAssertTrue(session.items.isEmpty, "the complete label is one undo step")
        }
    }

    func testReturnAndEscapeResolveCompositionBeforeTheWholeLabel() throws {
        try withCanvas { session, canvas, _ in
            canvas.insertText("前缀", replacementRange: insertion)
            canvas.setMarkedText("zhong", selectedRange: NSRange(location: 5, length: 0), replacementRange: insertion)
            canvas.cancelOperation(nil)
            XCTAssertEqual(session.pendingText?.string, "前缀")
            XCTAssertTrue(canvas.hasActiveTextEdit)
            XCTAssertFalse(canvas.hasMarkedText())

            canvas.setMarkedText("wen", selectedRange: NSRange(location: 3, length: 0), replacementRange: insertion)
            canvas.doCommand(by: #selector(NSResponder.insertNewline(_:)))
            XCTAssertTrue(canvas.hasActiveTextEdit, "a forwarded composition Return cannot save the label")
            XCTAssertFalse(canvas.hasMarkedText())
            XCTAssertTrue(session.items.isEmpty)
            canvas.cancelOperation(nil)
            XCTAssertFalse(canvas.hasActiveTextEdit)
            XCTAssertNil(session.pendingText)
            XCTAssertTrue(session.items.isEmpty)
        }
    }

    func testDeletionUsesUTF16RangesAndWholeEmojiGraphemes() throws {
        try withCanvas { session, canvas, _ in
            let prefix = "前🧑🏽‍💻"
            canvas.insertText(prefix, replacementRange: insertion)
            canvas.setMarkedText("zhongwen", selectedRange: NSRange(location: 8, length: 0), replacementRange: insertion)
            XCTAssertEqual(canvas.markedRange().location, (prefix as NSString).length)
            canvas.insertText("中文", replacementRange: insertion)
            canvas.doCommand(by: #selector(NSResponder.deleteBackward(_:)))
            XCTAssertEqual(session.pendingText?.string, prefix + "中")
            canvas.doCommand(by: #selector(NSResponder.deleteBackward(_:)))
            canvas.doCommand(by: #selector(NSResponder.deleteBackward(_:)))
            XCTAssertEqual(session.pendingText?.string, "前", "delete must remove the entire composed emoji")
            canvas.doCommand(by: #selector(NSResponder.moveToBeginningOfLine(_:)))
            canvas.insertText("中", replacementRange: insertion)
            XCTAssertEqual(session.pendingText?.string, "中前")
        }
    }

    func testCandidateRectTracksZoomAndTheScreenshotWindowLevel() throws {
        try withCanvas { _, canvas, window in
            window.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
            canvas.insertText("中文", replacementRange: insertion)
            var actual = NSRange(location: NSNotFound, length: 0)
            let caret = canvas.selectedRange()
            let normal = canvas.firstRect(forCharacterRange: caret, actualRange: &actual)
            XCTAssertEqual(actual, caret)
            XCTAssertGreaterThan(normal.height, 0)
            XCTAssertEqual(normal.width, 0)
            XCTAssertEqual(canvas.characterIndex(for: normal.origin), caret.location)
            XCTAssertEqual(canvas.windowLevel(), window.level.rawValue)

            canvas.setFrameSize(CGSize(width: 640, height: 400))
            let zoomed = canvas.firstRect(forCharacterRange: caret, actualRange: nil)
            XCTAssertEqual(zoomed.height, normal.height * 2, accuracy: 0.01)
            XCTAssertGreaterThan(zoomed.minX, normal.minX)
        }
    }

    func testOutputEndsTheInputContextAndKeepsTheChosenChineseText() throws {
        try withCanvas { session, canvas, _ in
            canvas.setMarkedText("nihao", selectedRange: NSRange(location: 5, length: 0), replacementRange: insertion)
            canvas.insertText("你好", replacementRange: insertion)
            try session.commitActiveEditForOutput()
            XCTAssertFalse(canvas.hasActiveTextEdit)
            XCTAssertFalse(canvas.hasMarkedText())
            XCTAssertNil(session.liveTextProvider)
            guard case .text(let text, _, _) = session.items.first?.payload else {
                return XCTFail("output must resolve the pending label")
            }
            XCTAssertEqual(text, "你好")
        }
    }
}
