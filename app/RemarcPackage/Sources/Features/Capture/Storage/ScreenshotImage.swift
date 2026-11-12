import AppKit

/// Loads an NSImage from a stored image path.
public func loadScreenshotImage(_ storedPath: String) -> NSImage? {
    NSImage(contentsOf: resolveImagePath(storedPath))
}
