import AppKit

/// History belongs to the active annotation session even after a toolbar button
/// takes focus from the canvas. Handle key equivalents before SwiftUI dispatch.
@MainActor
package class AnnotationHistoryPanel: NSPanel {
    package var acceptsKey = false
    package var cancelHandler: (@MainActor () -> Void)?
    package override var canBecomeKey: Bool { acceptsKey }

    package override func cancelOperation(_ sender: Any?) {
        guard let cancelHandler else { super.cancelOperation(sender); return }
        Task { @MainActor in cancelHandler() }
    }

    package weak var annotationSession: AnnotationSession?

    package override func performKeyEquivalent(with event: NSEvent) -> Bool {
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
