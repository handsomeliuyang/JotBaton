import AppKit

@MainActor
protocol ScreenshotClipboardDestination {
    @discardableResult func clearContents() -> Int
    func writeObjects(_ objects: [any NSPasteboardWriting]) -> Bool
}

extension NSPasteboard: ScreenshotClipboardDestination {}

/// Image output without creating a stored screenshot or a comment.
@MainActor
enum ScreenshotClipboard {
    enum CopyError: LocalizedError {
        case writeFailed

        var errorDescription: String? {
            L10n.tr("Could not copy the image. Please try again.")
        }
    }

    static func copy(_ session: AnnotationSession, to pasteboard: any ScreenshotClipboardDestination = NSPasteboard.general) async throws {
        // Commits the live label and waits for the latest marks. Never fall back
        // to the unannotated source if rendering fails.
        try await session.withFrozenComposite { image in
            try write(image, to: pasteboard)
        }
    }

    static func write(_ image: CGImage, to pasteboard: any ScreenshotClipboardDestination = NSPasteboard.general) throws {
        // Encode before replacing the clipboard, at source pixel dimensions.
        let png = try AnnotationExporter.pngData(from: image)
        let item = NSPasteboardItem()
        guard item.setData(png, forType: .png) else { throw CopyError.writeFailed }
        let bitmap = NSBitmapImageRep(cgImage: image)
        bitmap.size = NSSize(width: image.width, height: image.height)
        if let tiff = bitmap.tiffRepresentation {
            item.setData(tiff, forType: .tiff)
        }
        pasteboard.clearContents()
        guard pasteboard.writeObjects([item]) else { throw CopyError.writeFailed }
    }
}
