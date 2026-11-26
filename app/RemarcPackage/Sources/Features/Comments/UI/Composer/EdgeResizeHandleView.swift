import AppKit

/// Transparent AppKit resize strip placed along the leading and trailing edges of the
/// borderless floating editor panel. Tracks drags in screen coordinates so moving the
/// leading edge never jitters due to window origin shifts.
final class EdgeResizeHandleView: NSView {
    let edge: EditorResizeEdge
    var onDragChanged: (@MainActor (_ initialFrame: NSRect, _ deltaX: CGFloat) -> Void)?
    var onDragEnded: (@MainActor () -> Void)?
    var onDoubleClick: (@MainActor () -> Void)?

    private var dragStartMouseLocation: NSPoint?
    private var dragStartWindowFrame: NSRect?
    private var didDrag = false
    private var didPushResizeCursor = false
    private var isPointerInside = false
    private var activeTrackingArea: NSTrackingArea?

    init(edge: EditorResizeEdge) {
        self.edge = edge
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var mouseDownCanMoveWindow: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        discardCursorRects()
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let activeTrackingArea {
            removeTrackingArea(activeTrackingArea)
        }
        // `.cursorUpdate` does not fire when combined with `.activeAlways` on macOS,
        // so track enter/exit/move explicitly for reliable cursor updates on a
        // `.nonactivatingPanel`.
        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        activeTrackingArea = trackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        isPointerInside = true
        NSCursor.resizeLeftRight.set()
    }

    override func mouseMoved(with event: NSEvent) {
        isPointerInside = true
        NSCursor.resizeLeftRight.set()
    }

    override func mouseExited(with event: NSEvent) {
        isPointerInside = false
        if dragStartMouseLocation == nil {
            NSCursor.arrow.set()
        }
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            endDragSessionIfNeeded()
            onDoubleClick?()
            return
        }
        guard let window else { return }
        dragStartMouseLocation = NSEvent.mouseLocation
        dragStartWindowFrame = window.frame
        didDrag = false
        if !didPushResizeCursor {
            NSCursor.resizeLeftRight.push()
            didPushResizeCursor = true
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let startMouse = dragStartMouseLocation,
              let startFrame = dragStartWindowFrame else { return }
        didDrag = true
        let deltaX = NSEvent.mouseLocation.x - startMouse.x
        onDragChanged?(startFrame, deltaX)
    }

    override func mouseUp(with event: NSEvent) {
        let shouldFinishDrag = didDrag
        endDragSessionIfNeeded()
        if shouldFinishDrag {
            onDragEnded?()
        }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil {
            endDragSessionIfNeeded()
        }
    }

    private func endDragSessionIfNeeded() {
        dragStartMouseLocation = nil
        dragStartWindowFrame = nil
        didDrag = false
        if didPushResizeCursor {
            NSCursor.pop()
            didPushResizeCursor = false
        }
        if isPointerInside {
            NSCursor.resizeLeftRight.set()
        }
    }
}
