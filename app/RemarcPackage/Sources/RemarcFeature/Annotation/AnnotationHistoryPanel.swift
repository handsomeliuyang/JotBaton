import AppKit

/// History belongs to the active annotation session even after a toolbar button
/// takes focus from the canvas. Handle key equivalents before SwiftUI dispatch.
@MainActor
class AnnotationHistoryPanel: NSPanel {
    weak var annotationSession: AnnotationSession?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if let canvas = firstResponder as? AnnotationCanvasNSView, canvas.hasMarkedText() {
            return super.performKeyEquivalent(with: event)
        }
        // Preserve native text editing, including a text field's field editor.
        if !(firstResponder is NSTextView),
           annotationSession?.performHistoryKeyEquivalent(with: event) == true {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
