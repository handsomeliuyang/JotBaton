import CoreLocalization
import CorePlatform
import CoreTheme
import AppKit
import SwiftUI

enum ScreenshotCopyButtonGeometry {
    static let size = CGSize(width: 30, height: 30)

    static func frame(for parent: CGRect, visibleFrame: CGRect) -> CGRect {
        let inset: CGFloat = 4
        let gap: CGFloat = 8
        let x = min(max(parent.maxX - size.width, visibleFrame.minX + inset),
                    visibleFrame.maxX - size.width - inset)
        let above = parent.maxY + gap
        let y = above + size.height <= visibleFrame.maxY - inset
            ? above : parent.minY - gap - size.height
        return CGRect(x: x, y: min(max(y, visibleFrame.minY + inset),
                                  visibleFrame.maxY - size.height - inset),
                      width: size.width, height: size.height)
    }
}

/// A child panel keeps the image-only action outside the comment layout and
/// makes it travel and disappear with the composer. It never takes text focus.
@MainActor
final class ScreenshotCopyButtonController {
    private var panel: NSPanel?
    private weak var parent: NSPanel?
    private var observers: [NSObjectProtocol] = []

    func show(for parent: NSPanel, controller: CommentInputController) {
        if self.parent !== parent || panel == nil {
            teardown()
            self.parent = parent
            let panel = NSPanel(
                contentRect: CGRect(origin: .zero, size: ScreenshotCopyButtonGeometry.size),
                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.hidesOnDeactivate = false
            panel.level = NSWindow.Level(rawValue: parent.level.rawValue + 1)
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            let material = NSVisualEffectView()
            material.material = .popover
            material.blendingMode = .behindWindow
            material.state = .active
            material.wantsLayer = true
            material.layer?.cornerRadius = 7
            material.layer?.masksToBounds = true
            panel.contentView = material
            let hosting = NSHostingView(rootView: ScreenshotCopyButton(controller: controller))
            hosting.translatesAutoresizingMaskIntoConstraints = false
            material.addSubview(hosting)
            NSLayoutConstraint.activate([
                hosting.leadingAnchor.constraint(equalTo: material.leadingAnchor),
                hosting.trailingAnchor.constraint(equalTo: material.trailingAnchor),
                hosting.topAnchor.constraint(equalTo: material.topAnchor),
                hosting.bottomAnchor.constraint(equalTo: material.bottomAnchor),
            ])
            self.panel = panel
            parent.addChildWindow(panel, ordered: .above)
            for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
                observers.append(NotificationCenter.default.addObserver(
                    forName: name, object: parent, queue: .main
                ) { [weak self] _ in
                    Task { @MainActor in self?.reposition() }
                })
            }
        }
        reposition()
        panel?.orderFrontRegardless()
    }

    private func reposition() {
        guard let panel, let parent,
              let screen = parent.screen ?? NSScreen.screens.first(where: {
                  $0.frame.contains(NSPoint(x: parent.frame.midX, y: parent.frame.midY))
              }) else { return }
        panel.setFrame(ScreenshotCopyButtonGeometry.frame(
            for: parent.frame, visibleFrame: screen.visibleFrame), display: true)
    }

    func hide() { panel?.orderOut(nil) }

    func teardown() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        if let panel { parent?.removeChildWindow(panel) }
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
        parent = nil
    }
}

private struct ScreenshotCopyButton: View {
    @ObservedObject var controller: CommentInputController
    @ObservedObject private var localization = LocalizationManager.shared
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false

    var body: some View {
        Button(action: { controller.copyScreenshot() }) {
            Group {
                if controller.captureTransaction == .copying {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: controller.screenshotCopyError == nil
                          ? "doc.on.doc" : "exclamationmark.circle")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(controller.screenshotCopyError == nil
                            ? Color.remarcPrimary(for: colorScheme)
                            : Color.remarcError(for: colorScheme))
                }
            }
            .frame(width: 30, height: 30)
            .background(Color.remarcPrimary(for: colorScheme).opacity(isHovered ? 0.15 : 0.05))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(controller.captureTransaction != .idle)
        .onHover { isHovered = $0 }
        .help(controller.screenshotCopyError ?? L10n.tr("Copy Image"))
        .accessibilityLabel(AppIdentity.current.displayName + " · " + L10n.tr("Copy Image"))
        .accessibilityValue(controller.screenshotCopyError ?? "")
        .accessibilityIdentifier("remarc.screenshot.copyImageButton")
    }
}
