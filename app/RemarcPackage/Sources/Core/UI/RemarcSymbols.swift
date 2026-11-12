import AppKit

/// SF Symbols added after Ventura keep an equivalent icon on older systems.
@MainActor
package enum RemarcSymbols {
    package static let quickNote = name("bubble.and.pencil", fallback: "square.and.pencil")
    package static let moveToSession = name("arrow.forward.folder", fallback: "folder")
    package static let history = name("clock.arrow.trianglehead.counterclockwise.rotate.90", fallback: "clock.arrow.circlepath")

    package static func syncToolbar(_ preferred: String) -> String {
        name(preferred, fallback: "icloud")
    }

    private static func name(_ preferred: String, fallback: String) -> String {
        NSImage(systemSymbolName: preferred, accessibilityDescription: nil) == nil ? fallback : preferred
    }
}
