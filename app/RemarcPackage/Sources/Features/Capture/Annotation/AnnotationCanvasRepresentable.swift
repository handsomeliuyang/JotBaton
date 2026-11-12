import SwiftUI
import AppKit

/// Hosts the AppKit canvas inside SwiftUI, for the preview panel.
///
/// The capture surface adds the canvas to `RegionSelectionView` directly instead:
/// it needs to sit inside an existing AppKit view hierarchy at a specific place in
/// the panel ladder, which a `NSViewRepresentable` cannot express.
package struct AnnotationCanvasRepresentable: NSViewRepresentable {
    package init(session: AnnotationSession, drawsSelectionBorder: Bool = false, onEscape: @escaping () -> Void = {}) {
        self.session = session
        self.drawsSelectionBorder = drawsSelectionBorder
        self.onEscape = onEscape
    }
    @ObservedObject var session: AnnotationSession
    /// The preview draws no selection border - the panel provides its own chrome.
    package var drawsSelectionBorder: Bool = false
    package var onEscape: () -> Void = {}

    package func makeNSView(context: Context) -> AnnotationCanvasNSView {
        let canvas = AnnotationCanvasNSView(pixelSize: session.pixelSize, session: session)
        canvas.drawsSelectionBorder = drawsSelectionBorder
        canvas.onEscape = onEscape
        context.coordinator.canvas = canvas
        DispatchQueue.main.async {
            canvas.window?.makeFirstResponder(canvas)
        }
        return canvas
    }

    package func updateNSView(_ canvas: AnnotationCanvasNSView, context: Context) {
        canvas.drawsSelectionBorder = drawsSelectionBorder
        canvas.onEscape = onEscape
        canvas.needsDisplay = true
    }

    package func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    package final class Coordinator {
        weak var canvas: AnnotationCanvasNSView?
    }
}

/// Aspect-fit rect for the preview canvas.
///
/// `imageDisplaySize` in `ScreenshotPreviewController` is dead code with the wrong
/// constants, so this computes fresh: the outermost `.padding(.horizontal, 16)`
/// removes 32pt before the flexible frame expands, and the letterbox is centred.
package enum AnnotationPreviewLayout {
    package static func fittedSize(pixelSize: CGSize, available: CGSize) -> CGSize {
        guard pixelSize.width > 0, pixelSize.height > 0,
              available.width > 0, available.height > 0 else { return .zero }
        let scale = min(available.width / pixelSize.width, available.height / pixelSize.height)
        // Never upscale a small image to fill the panel: the canvas coordinate
        // system is source pixels, and blowing it up would make every chrome
        // measurement a fraction of a source pixel.
        let bounded = min(scale, 1)
        return CGSize(width: (pixelSize.width * bounded).rounded(),
                      height: (pixelSize.height * bounded).rounded())
    }
}
