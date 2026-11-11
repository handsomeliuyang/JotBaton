import AppKit
import SwiftUI

/// The menu-bar popover's toast is not visible after a capture closes. This
/// nonactivating panel acknowledges image-only copy without taking app focus.
@MainActor
final class ScreenshotCopyFeedbackController {
    static let shared = ScreenshotCopyFeedbackController()
    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?

    func show(on screen: NSScreen?) {
        hideTask?.cancel()
        panel?.orderOut(nil)
        guard let screen = screen ?? NSScreen.main else { return }

        let content = NSHostingView(rootView: ScreenshotCopyFeedbackView())
        let size = content.fittingSize
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = content
        panel.setFrameOrigin(NSPoint(
            x: screen.visibleFrame.midX - size.width / 2,
            y: screen.visibleFrame.minY + 60))
        panel.orderFrontRegardless()
        self.panel = panel
        hideTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(1.5)) }
            catch { return }
            self?.panel?.orderOut(nil)
            self?.panel = nil
        }
    }
}

private struct ScreenshotCopyFeedbackView: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 8) {
            if AppIdentity.current.isDevelopment { DevelopmentIdentityBadge() }
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Color.remarcSuccess(for: colorScheme))
            Text(L10n.tr("Image copied"))
                .font(.system(size: 12))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.thinMaterial, in: Capsule())
        .padding(12)
        .fixedSize()
    }
}
