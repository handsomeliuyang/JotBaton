import CorePlatform
import CoreTheme
import CoreUI
import AppKit

// MARK: - Region Selection NSView

/// Full-screen overlay that lets the user drag-select a rectangular region.
/// Draws a semi-transparent dark background with a clear cutout for the selection,
/// a white border around the selection, and a size label (W x H).
@MainActor
package final class RegionSelectionView: NSView {
    package var onRegionSelected: ((_ rect: NSRect) -> Void)?
    /// Fired during drag (live) — reposition panel without refocusing
    package var onRegionAdjusting: ((_ rect: NSRect) -> Void)?
    /// Fired on mouseUp — reposition panel and refocus text field
    package var onRegionUpdated: ((_ rect: NSRect) -> Void)?
    package var onCancel: (() -> Void)?

    private enum InteractionMode {
        case idle
        case drawing
        case resizing(Corner)
        case resizingEdge(RectEdge)
    }

    private enum Corner: CaseIterable {
        case topLeft, topRight, bottomLeft, bottomRight
    }

    private enum RectEdge: CaseIterable {
        case top, bottom, left, right
    }

    private var interactionMode: InteractionMode = .idle
    private var selectionRect: NSRect?
    private var dragStart: NSPoint?
    private var dragEnd: NSPoint?
    private var resizeAnchor: NSPoint?
    /// Snapshot of selection rect at drag start, for edge resize
    private var resizeOriginalRect: NSRect?
    /// Whether a completed selection has been reported via onRegionSelected
    private var hasReportedInitialSelection = false

    private let minimumSize: CGFloat = 10
    private let handleHitRadius: CGFloat = 12
    private let edgeHitThreshold: CGFloat = 8
    private let handleOffset: CGFloat = 4      // gap from selection border
    private let handleStrokeWidth: CGFloat = 2.5
    private let edgeSegmentLength: CGFloat = 24

    // MARK: - Annotation host

    /// The annotation canvas, when a frozen session exists. This is the first
    /// subview this view has ever had; AppKit draws parents before subviews, so the
    /// canvas covers the region and draws its own selection border.
    package private(set) var annotationCanvas: AnnotationCanvasNSView?

    /// The magnified display rect `D`, in this view's local (unflipped, 0-based)
    /// points. Never the capture rect: `pendingQuartzRect` is derived from `S`
    /// alone and must never see this.
    private var annotationDisplayRect: NSRect?

    /// `S`, frozen at annotate-entry. The size label reports this, not `D`.
    private var frozenSelectionRect: NSRect?
    private var effectiveZoom: Int = 1

    package var isAnnotating: Bool { annotationCanvas != nil }

    /// `startFrame` is where the canvas begins the entry animation; `displayRect`
    /// is where the parent's chrome should already be. Splitting them keeps the
    /// size label at its final position for the whole 0.18s enlargement instead of
    /// snapping at the end.
    package func installAnnotationCanvas(_ canvas: AnnotationCanvasNSView,
                                 selection: NSRect,
                                 displayRect: NSRect,
                                 startFrame: NSRect,
                                 zoom: Int) {
        frozenSelectionRect = selection
        annotationDisplayRect = displayRect
        effectiveZoom = zoom
        annotationCanvas = canvas
        canvas.frame = startFrame
        addSubview(canvas)
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    package func updateAnnotationStage(displayRect: NSRect, zoom: Int) {
        annotationDisplayRect = displayRect
        effectiveZoom = zoom
        annotationCanvas?.frame = displayRect
        // A frame change marks neither view dirty on its own, and ChromeMetrics has
        // changed on both.
        annotationCanvas?.needsDisplay = true
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
        annotationCanvas.map { window?.invalidateCursorRects(for: $0) }
    }

    package func removeAnnotationCanvas() {
        annotationCanvas?.removeFromSuperview()
        annotationCanvas = nil
        annotationDisplayRect = nil
        frozenSelectionRect = nil
        effectiveZoom = 1
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    package override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Drawing

    package override func draw(_ dirtyRect: NSRect) {
        // Semi-transparent dark overlay. Unchanged while annotating: the dim
        // backdrop stays exactly as it is.
        NSColor.black.withAlphaComponent(0.5).setFill()
        NSBezierPath(rect: bounds).fill()
        defer { drawDevelopmentIdentity() }

        // While a frozen session exists the geometry that drives chrome is the
        // DISPLAY rect, not the live selection.
        guard let rect = isAnnotating ? annotationDisplayRect : currentSelectionRect else { return }

        let cr = min(ThemeMetrics.panelCornerRadius, min(rect.width, rect.height) / 4)

        if !isAnnotating {
            // Clear cutout for selected region (rounded corners, scaled for small selections)
            NSGraphicsContext.current?.compositingOperation = .clear
            NSBezierPath(roundedRect: rect, xRadius: cr, yRadius: cr).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver

            // White border around selection (rounded corners)
            NSColor.white.setStroke()
            let borderPath = NSBezierPath(roundedRect: rect, xRadius: cr, yRadius: cr)
            borderPath.lineWidth = 1.5
            borderPath.stroke()
        }
        // Annotating: the cutout is SKIPPED because a clamped `D` need not cover
        // `S`, and a cleared sliver outside the canvas would show undimmed desktop.
        // The border is skipped too - the canvas draws it after its own rasters, or
        // the parent's stroke would have its inner half covered.

        // Size label: text always reports the TRUE capture size; position, flip,
        // and clamp derive from the display rect.
        drawSizeLabel(for: rect, reporting: isAnnotating ? frozenSelectionRect : rect)

        // Handles — only when idle with a finalized selection. Resize is locked
        // while annotating, so the chrome constants need no zoom compensation.
        if !isAnnotating, case .idle = interactionMode, selectionRect != nil {
            drawHandles(for: rect)
        }
    }

    private func drawDevelopmentIdentity() {
        guard AppIdentity.current.isDevelopment else { return }
        let badge = NSRect(x: bounds.minX + 16, y: bounds.maxY - 54, width: 142, height: 36)
        NSColor.black.withAlphaComponent(0.82).setFill()
        NSBezierPath(roundedRect: badge, xRadius: 10, yRadius: 10).fill()
        RemarcBrandAssets.applicationIcon.draw(in: NSRect(x: badge.minX + 6, y: badge.minY + 4, width: 28, height: 28))
        (AppIdentity.current.displayName as NSString).draw(at: NSPoint(x: badge.minX + 40, y: badge.minY + 11),
            withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.white])
    }

    private func drawHandles(for rect: NSRect) {
        // Must match the dynamic corner radius used in draw()
        let cr = min(ThemeMetrics.panelCornerRadius, min(rect.width, rect.height) / 4)
        let arcRadius = cr + handleOffset
        let handleColor = NSColor.white.withAlphaComponent(0.7)
        handleColor.setStroke()

        // Trim arc sweep when same-side arcs would crowd each other
        let verticalSpace = rect.height - 2 * cr
        let horizontalSpace = rect.width - 2 * cr
        let maxTrim: CGFloat = 25
        let trimV = max(0, min(maxTrim, maxTrim * (1 - verticalSpace / (2 * arcRadius))))
        let trimH = max(0, min(maxTrim, maxTrim * (1 - horizontalSpace / (2 * arcRadius))))

        // Corner arcs — strokes parallel to the selection's rounded corners
        let cornerArcs: [(center: NSPoint, startAngle: CGFloat, endAngle: CGFloat)] = [
            (NSPoint(x: rect.maxX - cr, y: rect.maxY - cr), 0 + trimV, 90 - trimH),     // topRight
            (NSPoint(x: rect.minX + cr, y: rect.maxY - cr), 90 + trimH, 180 - trimV),   // topLeft
            (NSPoint(x: rect.minX + cr, y: rect.minY + cr), 180 + trimV, 270 - trimH),  // bottomLeft
            (NSPoint(x: rect.maxX - cr, y: rect.minY + cr), 270 + trimH, 360 - trimV),  // bottomRight
        ]
        for (center, startAngle, endAngle) in cornerArcs {
            let path = NSBezierPath()
            path.appendArc(withCenter: center, radius: arcRadius,
                           startAngle: startAngle, endAngle: endAngle)
            path.lineWidth = handleStrokeWidth
            path.lineCapStyle = .round
            path.stroke()
        }

        // Edge midpoint segments — dynamically sized, hidden if they'd overlap corner arcs
        let gapFromArc: CGFloat = 8
        let minSegment: CGFloat = 10
        let availableH = rect.width - 2 * cr - 2 * gapFromArc
        let availableV = rect.height - 2 * cr - 2 * gapFromArc

        var edgeLines: [(from: NSPoint, to: NSPoint)] = []

        if availableH >= minSegment {
            let halfSeg = min(edgeSegmentLength, availableH) / 2
            // top
            edgeLines.append((NSPoint(x: rect.midX - halfSeg, y: rect.maxY + handleOffset),
                              NSPoint(x: rect.midX + halfSeg, y: rect.maxY + handleOffset)))
            // bottom
            edgeLines.append((NSPoint(x: rect.midX - halfSeg, y: rect.minY - handleOffset),
                              NSPoint(x: rect.midX + halfSeg, y: rect.minY - handleOffset)))
        }

        if availableV >= minSegment {
            let halfSeg = min(edgeSegmentLength, availableV) / 2
            // left
            edgeLines.append((NSPoint(x: rect.minX - handleOffset, y: rect.midY - halfSeg),
                              NSPoint(x: rect.minX - handleOffset, y: rect.midY + halfSeg)))
            // right
            edgeLines.append((NSPoint(x: rect.maxX + handleOffset, y: rect.midY - halfSeg),
                              NSPoint(x: rect.maxX + handleOffset, y: rect.midY + halfSeg)))
        }

        for (from, to) in edgeLines {
            let path = NSBezierPath()
            path.move(to: from)
            path.line(to: to)
            path.lineWidth = handleStrokeWidth
            path.lineCapStyle = .round
            path.stroke()
        }
    }

    /// `rect` positions the label; `sizeSource` supplies the numbers. They differ
    /// while magnified: the user is told what they will capture, not how big it
    /// currently looks.
    private func drawSizeLabel(for rect: NSRect, reporting sizeSource: NSRect? = nil) {
        let measured = sizeSource ?? rect
        let w = Int(measured.width)
        let h = Int(measured.height)
        // The suffix carries the EFFECTIVE zoom, never a requested one.
        let suffix = (isAnnotating && effectiveZoom > 1) ? " · \(effectiveZoom)x" : ""
        let text = "\(w) x \(h)\(suffix)"

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white,
        ]

        let attrString = NSAttributedString(string: text, attributes: attributes)
        let textSize = attrString.size()

        // Position label below the selection, or above if not enough room
        let padding: CGFloat = 6
        let labelWidth = textSize.width + padding * 2
        let labelHeight = textSize.height + padding
        var labelX = rect.midX - labelWidth / 2
        var labelY = rect.minY - labelHeight - 6

        if labelY < bounds.minY + 4 {
            labelY = rect.maxY + 6
        }

        // Clamp horizontally
        labelX = max(bounds.minX + 4, min(labelX, bounds.maxX - labelWidth - 4))

        let bgRect = NSRect(x: labelX, y: labelY, width: labelWidth, height: labelHeight)
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: bgRect, xRadius: 4, yRadius: 4).fill()

        let textPoint = NSPoint(
            x: bgRect.midX - textSize.width / 2,
            y: bgRect.midY - textSize.height / 2
        )
        attrString.draw(at: textPoint)
    }

    // MARK: - Mouse Events

    package override func mouseDown(with event: NSEvent) {
        // Region geometry is locked while a frozen annotation session exists; the
        // canvas subview owns every event inside the stage.
        guard !isAnnotating else { return }
        let point = convert(event.locationInWindow, from: nil)

        if let rect = selectionRect {
            // 1. Check corners (highest priority)
            if let corner = cornerHitTest(point: point, rect: rect) {
                interactionMode = .resizing(corner)
                resizeAnchor = oppositeCorner(of: corner, in: rect)
                return
            }

            // 2. Check edges
            if let edge = edgeHitTest(point: point, rect: rect) {
                interactionMode = .resizingEdge(edge)
                resizeOriginalRect = rect
                return
            }
        }

        // 3. Click outside handles → start a new draw
        dragStart = point
        dragEnd = point
        interactionMode = .drawing
        needsDisplay = true
    }

    package override func mouseDragged(with event: NSEvent) {
        guard !isAnnotating else { return }
        let point = convert(event.locationInWindow, from: nil)

        switch interactionMode {
        case .drawing:
            dragEnd = point
            needsDisplay = true

        case .resizing:
            guard let anchor = resizeAnchor else { return }
            selectionRect = rectFromCorners(anchor, point)
            needsDisplay = true
            if let rect = selectionRect { onRegionAdjusting?(rect) }

        case .resizingEdge(let edge):
            guard let orig = resizeOriginalRect else { return }
            selectionRect = computeEdgeResize(edge: edge, original: orig, mouse: point)
            needsDisplay = true
            if let rect = selectionRect { onRegionAdjusting?(rect) }

        case .idle:
            break
        }
    }

    package override func mouseUp(with event: NSEvent) {
        guard !isAnnotating else { return }
        let point = convert(event.locationInWindow, from: nil)

        switch interactionMode {
        case .drawing:
            dragEnd = point
            guard let rect = rectFromDrag,
                  rect.width >= minimumSize,
                  rect.height >= minimumSize
            else {
                // Too small — reset draw state, keep existing selection if any
                dragStart = nil
                dragEnd = nil
                interactionMode = .idle
                needsDisplay = true
                return
            }

            let previouslyHadSelection = hasReportedInitialSelection
            selectionRect = rect
            dragStart = nil
            dragEnd = nil
            interactionMode = .idle

            if previouslyHadSelection {
                onRegionUpdated?(rect)
            } else {
                hasReportedInitialSelection = true
                onRegionSelected?(rect)
            }
            needsDisplay = true

        case .resizing:
            guard let anchor = resizeAnchor else {
                interactionMode = .idle
                return
            }
            let rect = rectFromCorners(anchor, point)

            if rect.width >= minimumSize, rect.height >= minimumSize {
                selectionRect = rect
            }

            resizeAnchor = nil
            interactionMode = .idle
            needsDisplay = true

            if let final = selectionRect {
                onRegionUpdated?(final)
            }

        case .resizingEdge(let edge):
            guard let orig = resizeOriginalRect else {
                interactionMode = .idle
                return
            }
            let rect = computeEdgeResize(edge: edge, original: orig, mouse: point)

            if rect.width >= minimumSize, rect.height >= minimumSize {
                selectionRect = rect
            }

            resizeOriginalRect = nil
            interactionMode = .idle
            needsDisplay = true

            if let final = selectionRect {
                onRegionUpdated?(final)
            }

        case .idle:
            break
        }

        window?.invalidateCursorRects(for: self)
    }

    // MARK: - Keyboard

    package override var acceptsFirstResponder: Bool { true }

    package override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Escape
            onCancel?()
        }
    }

    // MARK: - Cursor & Tracking

    package override func resetCursorRects() {
        // The canvas installs its own cursor over the stage, and resize is locked,
        // so the parent contributes nothing while annotating.
        guard !isAnnotating else { return }

        if let rect = selectionRect, case .idle = interactionMode {
            let hr = handleHitRadius

            // Corner handle cursors — crosshair
            let cornerPoints: [NSPoint] = [
                NSPoint(x: rect.minX, y: rect.maxY),
                NSPoint(x: rect.maxX, y: rect.maxY),
                NSPoint(x: rect.minX, y: rect.minY),
                NSPoint(x: rect.maxX, y: rect.minY),
            ]
            for pt in cornerPoints {
                addCursorRect(NSRect(x: pt.x - hr, y: pt.y - hr, width: hr * 2, height: hr * 2),
                              cursor: .crosshair)
            }

            // Edge cursors — resize arrows
            let et = edgeHitThreshold
            // Top edge
            addCursorRect(NSRect(x: rect.minX + hr, y: rect.maxY - et, width: rect.width - hr * 2, height: et * 2),
                          cursor: .resizeUpDown)
            // Bottom edge
            addCursorRect(NSRect(x: rect.minX + hr, y: rect.minY - et, width: rect.width - hr * 2, height: et * 2),
                          cursor: .resizeUpDown)
            // Left edge
            addCursorRect(NSRect(x: rect.minX - et, y: rect.minY + hr, width: et * 2, height: rect.height - hr * 2),
                          cursor: .resizeLeftRight)
            // Right edge
            addCursorRect(NSRect(x: rect.maxX - et, y: rect.minY + hr, width: et * 2, height: rect.height - hr * 2),
                          cursor: .resizeLeftRight)
        }

        // Everything else — crosshair for drawing
        addCursorRect(bounds, cursor: .crosshair)
    }

    package override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas {
            removeTrackingArea(area)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
    }

    package override func mouseMoved(with event: NSEvent) {
        window?.invalidateCursorRects(for: self)
    }

    // MARK: - Helpers

    private var currentSelectionRect: NSRect? {
        switch interactionMode {
        case .drawing:
            return rectFromDrag
        case .resizing, .resizingEdge, .idle:
            return selectionRect
        }
    }

    /// Rect computed from the current drag points (used during drawing)
    private var rectFromDrag: NSRect? {
        guard let start = dragStart, let end = dragEnd else { return nil }
        return NSRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(end.x - start.x),
            height: abs(end.y - start.y)
        )
    }

    /// Rect from two corner points
    private func rectFromCorners(_ a: NSPoint, _ b: NSPoint) -> NSRect {
        NSRect(
            x: min(a.x, b.x),
            y: min(a.y, b.y),
            width: abs(b.x - a.x),
            height: abs(b.y - a.y)
        )
    }

    /// Returns which corner handle the point is near, if any
    private func cornerHitTest(point: NSPoint, rect: NSRect) -> Corner? {
        let corners: [(Corner, NSPoint)] = [
            (.topLeft, NSPoint(x: rect.minX, y: rect.maxY)),
            (.topRight, NSPoint(x: rect.maxX, y: rect.maxY)),
            (.bottomLeft, NSPoint(x: rect.minX, y: rect.minY)),
            (.bottomRight, NSPoint(x: rect.maxX, y: rect.minY)),
        ]
        for (corner, cornerPoint) in corners {
            let dx = point.x - cornerPoint.x
            let dy = point.y - cornerPoint.y
            if hypot(dx, dy) <= handleHitRadius {
                return corner
            }
        }
        return nil
    }

    /// Returns which edge the point is near (excluding corner zones)
    private func edgeHitTest(point: NSPoint, rect: NSRect) -> RectEdge? {
        let t = edgeHitThreshold
        let cz = handleHitRadius  // corner exclusion zone

        // Top edge
        if abs(point.y - rect.maxY) < t &&
           point.x > rect.minX + cz && point.x < rect.maxX - cz {
            return .top
        }
        // Bottom edge
        if abs(point.y - rect.minY) < t &&
           point.x > rect.minX + cz && point.x < rect.maxX - cz {
            return .bottom
        }
        // Left edge
        if abs(point.x - rect.minX) < t &&
           point.y > rect.minY + cz && point.y < rect.maxY - cz {
            return .left
        }
        // Right edge
        if abs(point.x - rect.maxX) < t &&
           point.y > rect.minY + cz && point.y < rect.maxY - cz {
            return .right
        }
        return nil
    }

    /// Compute new rect from an edge resize drag
    private func computeEdgeResize(edge: RectEdge, original: NSRect, mouse: NSPoint) -> NSRect {
        switch edge {
        case .top:
            let bottom = original.minY
            return NSRect(x: original.minX, y: min(bottom, mouse.y),
                          width: original.width, height: abs(mouse.y - bottom))
        case .bottom:
            let top = original.maxY
            return NSRect(x: original.minX, y: min(top, mouse.y),
                          width: original.width, height: abs(mouse.y - top))
        case .left:
            let right = original.maxX
            return NSRect(x: min(right, mouse.x), y: original.minY,
                          width: abs(mouse.x - right), height: original.height)
        case .right:
            let left = original.minX
            return NSRect(x: min(left, mouse.x), y: original.minY,
                          width: abs(mouse.x - left), height: original.height)
        }
    }

    /// Returns the point of the corner opposite to the given one
    private func oppositeCorner(of corner: Corner, in rect: NSRect) -> NSPoint {
        switch corner {
        case .topLeft: return NSPoint(x: rect.maxX, y: rect.minY)
        case .topRight: return NSPoint(x: rect.minX, y: rect.minY)
        case .bottomLeft: return NSPoint(x: rect.maxX, y: rect.maxY)
        case .bottomRight: return NSPoint(x: rect.minX, y: rect.maxY)
        }
    }
}

/// The capture overlay's window.
///
/// A borderless `NSPanel` returns false from `canBecomeKey`, so the existing
/// `makeKeyAndOrderFront` in `showOverlay` never actually made it key - which was
/// invisible while the overlay only needed mouse events. Annotation needs the
/// keyboard: without this the canvas can be first responder in a non-key window
/// and every tool shortcut goes to the comment text view instead. Measured before
/// the fix: pressing T and typing "hello" produced the comment "thello" and no
/// text annotation.
