import AppKit
import SwiftUI

/// A toolbar click must operate its control even while the canvas or another
/// window is key. This also supports the Ventura preview, before SwiftUI's
/// newer window-activation modifiers became available.
final class AnnotationHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
