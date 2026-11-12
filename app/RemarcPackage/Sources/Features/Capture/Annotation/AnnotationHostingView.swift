import AppKit
import SwiftUI

/// A toolbar click must operate its control even while the canvas or another
/// window is key. This also supports the Ventura preview, before SwiftUI's
/// newer window-activation modifiers became available.
package final class AnnotationHostingView<Content: View>: NSHostingView<Content> {
    package override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
