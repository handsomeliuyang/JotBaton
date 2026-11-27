import AppKit
import CoreLocalization
import CorePlatform
import CoreUI
import FeatureCapture
import SwiftUI
import UniformTypeIdentifiers

/// Hover scrim, centered expand glyph, tooltip, and VoiceOver button semantics
/// for thumbnails and lead images that open the standalone image preview window.
public struct ImagePreviewAffordance: ViewModifier {
    @ObservedObject private var localization = LocalizationManager.shared
    @State private var isHovered = false

    public init() {}

    public func body(content: Content) -> some View {
        content
            .overlay {
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.black.opacity(0.15))

                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 26, height: 26)
                        .background(Color.black.opacity(0.55), in: Circle())
                }
                .opacity(isHovered ? 1 : 0)
                .animation(.easeInOut(duration: 0.15), value: isHovered)
                .allowsHitTesting(false)
            }
            .onHover { hovering in
                isHovered = hovering
            }
            .help(L10n.tr("Preview image"))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(L10n.tr("Preview image"))
            .accessibilityAddTraits(.isButton)
    }
}

/// Shared Copy / Save Image As context menu used by card thumbnails, history
/// screenshots, attachment strips, and the comment editor lead image.
struct ImageContextMenuModifier: ViewModifier {
    @ObservedObject private var localization = LocalizationManager.shared
    let imagePath: String

    func body(content: Content) -> some View {
        content.contextMenu {
            Button {
                ImageFileActions.copyImage(imagePath: imagePath)
            } label: {
                Label(L10n.tr("Copy Image"), systemImage: "doc.on.doc")
            }

            Button {
                ImageFileActions.saveImageAs(imagePath: imagePath)
            } label: {
                Label(L10n.tr("Save Image As\u{2026}"), systemImage: "square.and.arrow.down")
            }
        }
    }
}

extension View {
    func imageContextMenu(imagePath: String) -> some View {
        modifier(ImageContextMenuModifier(imagePath: imagePath))
    }
}

@MainActor
enum ImageFileActions {
    static func copyImage(imagePath: String) {
        if let nsImage = loadScreenshotImage(imagePath) {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.writeObjects([nsImage])
            ToastManager.shared.show(L10n.tr("Image copied"))
        }
    }

    static func saveImageAs(imagePath: String) {
        let sourceURL = resolveImagePath(imagePath)
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.png]
        savePanel.nameFieldStringValue = sourceURL.lastPathComponent
        savePanel.canCreateDirectories = true
        savePanel.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 4)

        let editor = FloatingEditorController.shared
        let popover = MenuBarPopoverController.shared
        let previousEditorSuppression = editor.suppressClickOutside
        let previousPopoverPreventDismiss = popover.preventDismiss
        if editor.isVisible {
            editor.suppressClickOutside = true
        }
        popover.preventDismiss = true

        savePanel.begin { response in
            Task { @MainActor in
                editor.suppressClickOutside = previousEditorSuppression
                popover.preventDismiss = previousPopoverPreventDismiss

                guard response == .OK, let destinationURL = savePanel.url else { return }
                do {
                    try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
                    ToastManager.shared.show(L10n.tr("Image saved"))
                } catch {
                    debugLog("Failed to save image: \(error.localizedDescription)")
                    ToastManager.shared.show(L10n.tr("Failed to save image"))
                }
            }
        }
    }
}
