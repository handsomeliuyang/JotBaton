import AppKit
import CoreLocalization
import CorePlatform
import CoreTheme
import CoreUI
import SwiftUI

private final class ReferenceTextWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) {
        performClose(sender)
    }
}

/// A resizable reader kept with its editor presentation, without changing the draft.
@MainActor
final class ReferenceTextWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var currentReference: String?

    var isVisible: Bool { window?.isVisible == true }

    func show(reference: String, over editor: NSWindow) {
        if let window, currentReference == reference {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        dismiss()

        let screenFrame = NSScreen.bestScreen(for: editor).visibleFrame.insetBy(dx: 24, dy: 24)
        let size = NSSize(width: min(760, screenFrame.width), height: min(600, screenFrame.height))
        let window = ReferenceTextWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier("remarc.commentEditor.fullQuoteWindow")
        window.setLocalizedTitle("Quoted text")
        // The editor and its dim overlay sit above ordinary application windows.
        window.level = NSWindow.Level(rawValue: editor.level.rawValue + 1)
        window.collectionBehavior = [.fullScreenAuxiliary]
        window.tabbingMode = .disallowed
        window.contentMinSize = NSSize(width: min(480, size.width), height: min(320, size.height))
        window.backgroundColor = .windowBackgroundColor
        window.isOpaque = true
        window.delegate = self

        let hostingView = NSHostingView(rootView: ReferenceTextWindowContent(reference: reference))
        // Window resizing controls the viewport; the full text only sizes the scroll content.
        hostingView.sizingOptions = []
        window.contentView = hostingView
        window.setFrameOrigin(NSPoint(
            x: screenFrame.midX - window.frame.width / 2,
            y: screenFrame.midY - window.frame.height / 2
        ))
        self.window = window
        currentReference = reference
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func dismiss() {
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        guard let closingWindow = notification.object as? NSWindow, closingWindow === window else { return }
        window = nil
        currentReference = nil
    }
}

private struct ReferenceTextWindowContent: View {
    @ObservedObject private var localization = LocalizationManager.shared
    @Environment(\.colorScheme) private var colorScheme
    let reference: String

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                if AppIdentity.current.isDevelopment {
                    DevelopmentIdentityBadge()
                }
                Text(L10n.tr("Quoted text"))
                    .font(.system(size: 17, weight: .semibold))
                Spacer()
                Button(action: {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(reference, forType: .string)
                }) {
                    Label(L10n.tr("Copy"), systemImage: "doc.on.doc")
                }
                .accessibilityIdentifier("remarc.commentEditor.copyFullQuote")
            }
            .padding(20)

            Divider()

            ScrollView(.vertical) {
                Text(verbatim: reference)
                    .font(.system(size: 14))
                    .lineSpacing(5)
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 12)
                    .quoteBorder()
                    .padding(24)
                    .accessibilityIdentifier("remarc.commentEditor.fullQuoteText")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color.remarcDropdownBackground(for: colorScheme))
    }
}
