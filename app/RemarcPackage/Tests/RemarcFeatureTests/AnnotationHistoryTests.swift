import AppKit
import SwiftUI
import XCTest
@testable import RemarcFeature

private final class AnnotationHistoryTestPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class AnnotationHistoryTests: XCTestCase {
    private func makeSession() -> AnnotationSession {
        AnnotationSession(source: TestImages.solid(width: 120, height: 80, red: 1, green: 1, blue: 1))
    }

    private func key(_ modifiers: NSEvent.ModifierFlags, window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers,
            timestamp: 0, windowNumber: window.windowNumber, context: nil,
            characters: modifiers.contains(.shift) ? "Z" : "z",
            charactersIgnoringModifiers: modifiers.contains(.shift) ? "Z" : "z",
            isARepeat: false, keyCode: 6))
    }

    func testThreeDefaultRectangleGesturesUndoAndRedoOneAtATime() throws {
        let session = makeSession()
        let canvas = AnnotationCanvasNSView(pixelSize: session.pixelSize, session: session)
        let window = NSWindow(contentRect: canvas.frame, styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.contentView = canvas
        defer { window.contentView = nil; window.orderOut(nil) }
        XCTAssertTrue(window.makeFirstResponder(canvas))

        func mouse(_ type: NSEvent.EventType, _ point: CGPoint) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(
                with: type, location: canvas.convert(point, to: nil), modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 1))
        }
        for x in [10, 45, 80] {
            canvas.mouseDown(with: try mouse(.leftMouseDown, CGPoint(x: x, y: 10)))
            canvas.mouseUp(with: try mouse(.leftMouseUp, CGPoint(x: x + 20, y: 40)))
        }
        let drawn = session.items
        XCTAssertEqual(drawn.count, 3)
        for item in drawn {
            guard case .rect = item.payload else { return XCTFail("the default gesture must draw a rectangle") }
        }

        let undo = try key(.command, window: window)
        let redo = try key([.command, .shift], window: window)
        for remaining in stride(from: 2, through: 0, by: -1) {
            XCTAssertTrue(canvas.performKeyEquivalent(with: undo))
            XCTAssertEqual(session.items, Array(drawn.prefix(remaining)))
        }
        XCTAssertFalse(session.canUndo)
        XCTAssertFalse(session.isDirty)
        for restored in 1...3 {
            XCTAssertTrue(canvas.performKeyEquivalent(with: redo))
            XCTAssertEqual(session.items, Array(drawn.prefix(restored)))
        }
        XCTAssertFalse(session.canRedo)

        // A new mark after undo starts a new history branch.
        canvas.keyDown(with: undo)
        session.add(AnnotationItem(payload: .rect(CGRect(x: 20, y: 45, width: 30, height: 20)),
                                   ink: .presets[0], strokeWidth: 3))
        XCTAssertFalse(session.canRedo)
        XCTAssertEqual(session.items.count, 3)
    }

    func testToolbarShortcutsWorkWithoutCanvasFocus() throws {
        let session = makeSession()
        let mark = AnnotationItem(payload: .rect(CGRect(x: 10, y: 10, width: 30, height: 20)),
                                  ink: .presets[0], strokeWidth: 3)
        session.add(mark)
        let toolbar = AnnotationToolbarView(session: session, zoomState: nil,
                                            showsDiscardControls: false,
                                            onUndo: { session.undo() },
                                            onRedo: { session.redo() })
        let host = NSHostingView(rootView: toolbar)
        let window = AnnotationHistoryTestPanel(
            contentRect: CGRect(x: 0, y: 0, width: 620, height: 42),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil; window.orderOut(nil) }
        // SwiftUI defers updates for an off-screen hosting view. Show the same
        // keyable, nonactivating panel used by the real toolbar so undo updates
        // the Redo button and its key equivalent before the next command.
        window.makeKeyAndOrderFront(nil)
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))

        XCTAssertTrue(host.performKeyEquivalent(with: try key(.command, window: window)))
        XCTAssertTrue(session.items.isEmpty)
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        XCTAssertTrue(host.performKeyEquivalent(with: try key([.command, .shift], window: window)))
        XCTAssertEqual(session.items, [mark])
    }

    func testCanvasDoesNotTakeHistoryShortcutsFromAnotherResponder() throws {
        let session = makeSession()
        session.add(AnnotationItem(payload: .rect(CGRect(x: 10, y: 10, width: 30, height: 20)),
                                   ink: .presets[0], strokeWidth: 3))
        let canvas = AnnotationCanvasNSView(pixelSize: session.pixelSize, session: session)
        let window = NSWindow(contentRect: canvas.frame, styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.contentView = canvas
        defer { window.contentView = nil; window.orderOut(nil) }
        window.makeFirstResponder(nil)
        XCTAssertFalse(canvas.performKeyEquivalent(with: try key(.command, window: window)))
        XCTAssertEqual(session.items.count, 1)
        window.makeFirstResponder(canvas)
        XCTAssertFalse(canvas.performKeyEquivalent(with: try key([.command, .option], window: window)))
        XCTAssertEqual(session.items.count, 1)
    }
}
