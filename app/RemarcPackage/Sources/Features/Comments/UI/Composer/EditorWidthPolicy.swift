import CoreGraphics
import Foundation

enum EditorResizeEdge: Sendable {
    case leading
    case trailing
}

enum EditorWidthPolicy {
    static let userDefaultsKey = "floatingEditorWidth"
    static let screenMargin: CGFloat = 8

    /// Clamps a desired editor width into `[minWidth, visibleScreenWidth - 16]`.
    /// When the screen itself is narrower than `minWidth`, falls back to the
    /// available screen width so the editor still fits onscreen.
    static func clamp(
        _ width: CGFloat,
        visibleScreenWidth: CGFloat,
        minWidth: CGFloat = WorkspaceMetrics.editorMinWidth
    ) -> CGFloat {
        guard visibleScreenWidth.isFinite, visibleScreenWidth > 0 else {
            return minWidth
        }
        let availableWidth = visibleScreenWidth - screenMargin * 2
        let effectiveMax = availableWidth > 0 ? availableWidth : visibleScreenWidth
        guard effectiveMax >= minWidth else {
            return effectiveMax
        }
        guard width.isFinite else {
            return min(WorkspaceMetrics.editorDefaultWidth, effectiveMax)
        }
        return min(max(width, minWidth), effectiveMax)
    }

    static func loadWidth(
        from defaults: UserDefaults = .standard,
        visibleScreenWidth: CGFloat
    ) -> CGFloat {
        let stored = (defaults.object(forKey: userDefaultsKey) as? NSNumber)?.doubleValue
        let desired: CGFloat
        if let stored, stored.isFinite, stored > 0 {
            desired = CGFloat(stored)
        } else {
            desired = WorkspaceMetrics.editorDefaultWidth
        }
        return clamp(desired, visibleScreenWidth: visibleScreenWidth)
    }

    static func saveWidth(_ width: CGFloat, to defaults: UserDefaults = .standard) {
        guard width.isFinite, width > 0 else { return }
        defaults.set(Double(width), forKey: userDefaultsKey)
    }

    /// Computes the horizontal frame `(x, width)` while dragging the leading or trailing
    /// edge, keeping the opposite edge anchored and preventing the dragged edge from
    /// crossing the visible screen margin.
    static func resizedHorizontalFrame(
        edge: EditorResizeEdge,
        initialFrame: CGRect,
        deltaX: CGFloat,
        visibleScreenFrame: CGRect,
        minWidth: CGFloat = WorkspaceMetrics.editorMinWidth
    ) -> (x: CGFloat, width: CGFloat) {
        let minAllowedX = visibleScreenFrame.minX + screenMargin
        let maxAllowedX = visibleScreenFrame.maxX - screenMargin
        let screenMaxWidth = clamp(
            visibleScreenFrame.width,
            visibleScreenWidth: visibleScreenFrame.width,
            minWidth: minWidth
        )
        let effectiveMin = min(minWidth, screenMaxWidth)

        switch edge {
        case .trailing:
            let anchorLeft = initialFrame.minX
            let proposedWidth = initialFrame.width + deltaX
            let availableFromAnchor = maxAllowedX - anchorLeft
            let upperBound = min(screenMaxWidth, max(availableFromAnchor, effectiveMin))
            let lowerBound = min(effectiveMin, upperBound)
            let clampedWidth = min(max(proposedWidth, lowerBound), upperBound)
            return (x: anchorLeft, width: clampedWidth)

        case .leading:
            let anchorRight = initialFrame.maxX
            let proposedWidth = initialFrame.width - deltaX
            let availableFromAnchor = anchorRight - minAllowedX
            let upperBound = min(screenMaxWidth, max(availableFromAnchor, effectiveMin))
            let lowerBound = min(effectiveMin, upperBound)
            let clampedWidth = min(max(proposedWidth, lowerBound), upperBound)
            return (x: anchorRight - clampedWidth, width: clampedWidth)
        }
    }

    /// Computes a centered horizontal frame `(x, width)` around `midX`, clamped within
    /// `visibleScreenFrame` with `screenMargin`.
    static func centeredHorizontalFrame(
        targetWidth: CGFloat = WorkspaceMetrics.editorDefaultWidth,
        aroundMidX midX: CGFloat,
        visibleScreenFrame: CGRect,
        minWidth: CGFloat = WorkspaceMetrics.editorMinWidth
    ) -> (x: CGFloat, width: CGFloat) {
        let width = clamp(targetWidth, visibleScreenWidth: visibleScreenFrame.width, minWidth: minWidth)
        let minX = visibleScreenFrame.minX + screenMargin
        let maxX = visibleScreenFrame.maxX - width - screenMargin
        let desiredX = midX - width / 2
        let clampedX = minX <= maxX ? min(max(desiredX, minX), maxX) : visibleScreenFrame.minX
        return (x: clampedX, width: width)
    }

    /// Clamps a vertical height to `visibleScreenFrame.height - 16` and centers it around
    /// `midY` while staying inside the visible screen margins.
    static func verticalFrame(
        fittingHeight: CGFloat,
        aroundMidY midY: CGFloat,
        visibleScreenFrame: CGRect
    ) -> (y: CGFloat, height: CGFloat) {
        let availableHeight = visibleScreenFrame.height - screenMargin * 2
        let maxHeight = availableHeight > 0 ? availableHeight : visibleScreenFrame.height
        let height = maxHeight > 0 ? min(fittingHeight, maxHeight) : fittingHeight
        let minY = visibleScreenFrame.minY + screenMargin
        let maxY = visibleScreenFrame.maxY - height - screenMargin
        let desiredY = midY - height / 2
        let clampedY = minY <= maxY ? min(max(desiredY, minY), maxY) : visibleScreenFrame.minY
        return (y: clampedY, height: height)
    }
}
