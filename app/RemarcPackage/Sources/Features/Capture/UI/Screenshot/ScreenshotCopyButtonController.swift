import CoreLocalization
import CorePlatform
import CoreTheme
import AppKit
import Combine
import SwiftUI

enum ScreenshotCopyButtonGeometry {
    static let height: CGFloat = 28
    static let minWidth: CGFloat = 96
    static let fallbackSize = CGSize(width: 124, height: height)

    static func frame(for parent: CGRect, size: CGSize = fallbackSize, visibleFrame: CGRect) -> CGRect {
        let inset: CGFloat = 4
        let gap: CGFloat = 8
        let maxWidth = max(visibleFrame.width - inset * 2, minWidth)
        let resolvedSize = CGSize(
            width: min(max(ceil(size.width), minWidth), maxWidth),
            height: max(ceil(size.height), height)
        )
        let x = min(max(parent.maxX - resolvedSize.width, visibleFrame.minX + inset),
                    visibleFrame.maxX - resolvedSize.width - inset)
        let above = parent.maxY + gap
        let y = above + resolvedSize.height <= visibleFrame.maxY - inset
            ? above : parent.minY - gap - resolvedSize.height
        return CGRect(x: x, y: min(max(y, visibleFrame.minY + inset),
                                  visibleFrame.maxY - resolvedSize.height - inset),
                      width: resolvedSize.width, height: resolvedSize.height)
    }
}

private final class CopyButtonHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// A child panel keeps the image-only action outside the comment layout and
/// makes it travel and disappear with the composer. It never takes text focus.
@MainActor
final class ScreenshotCopyButtonController {
    private var panel: NSPanel?
    private var hosting: CopyButtonHostingView<ScreenshotCopyButton>?
    private weak var parent: NSPanel?
    private var observers: [NSObjectProtocol] = []
    private var cancellables: Set<AnyCancellable> = []

    func show(for parent: NSPanel, controller: CommentInputController) {
        if self.parent !== parent || panel == nil {
            teardown()
            self.parent = parent
            let panel = NSPanel(
                contentRect: CGRect(origin: .zero, size: ScreenshotCopyButtonGeometry.fallbackSize),
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
            material.layer?.cornerRadius = ScreenshotCopyButtonGeometry.height / 2
            material.layer?.masksToBounds = true
            panel.contentView = material
            let hosting = CopyButtonHostingView(rootView: ScreenshotCopyButton(controller: controller))
            hosting.translatesAutoresizingMaskIntoConstraints = false
            material.addSubview(hosting)
            NSLayoutConstraint.activate([
                hosting.leadingAnchor.constraint(equalTo: material.leadingAnchor),
                hosting.trailingAnchor.constraint(equalTo: material.trailingAnchor),
                hosting.topAnchor.constraint(equalTo: material.topAnchor),
                hosting.bottomAnchor.constraint(equalTo: material.bottomAnchor),
            ])
            self.panel = panel
            self.hosting = hosting
            parent.addChildWindow(panel, ordered: .above)
            for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
                observers.append(NotificationCenter.default.addObserver(
                    forName: name, object: parent, queue: .main
                ) { [weak self] _ in
                    Task { @MainActor in self?.reposition() }
                })
            }
            LocalizationManager.shared.$language
                .dropFirst()
                .sink { [weak self] _ in
                    Task { @MainActor in self?.reposition() }
                }
                .store(in: &cancellables)
        }
        reposition()
        panel?.orderFrontRegardless()
    }

    private func reposition() {
        guard let panel, let parent,
              let screen = parent.screen ?? NSScreen.screens.first(where: {
                  $0.frame.contains(NSPoint(x: parent.frame.midX, y: parent.frame.midY))
              }) else { return }
        hosting?.layoutSubtreeIfNeeded()
        let fitting = hosting?.fittingSize ?? ScreenshotCopyButtonGeometry.fallbackSize
        let frame = ScreenshotCopyButtonGeometry.frame(
            for: parent.frame,
            size: CGSize(width: fitting.width, height: ScreenshotCopyButtonGeometry.height),
            visibleFrame: screen.visibleFrame
        )
        panel.contentView?.layer?.cornerRadius = frame.height / 2
        panel.setFrame(frame, display: true)
        panel.invalidateShadow()
    }

    func hide() { panel?.orderOut(nil) }

    func teardown() {
        cancellables.removeAll()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        if let panel { parent?.removeChildWindow(panel) }
        panel?.orderOut(nil)
        panel?.contentView = nil
        hosting = nil
        panel = nil
        parent = nil
    }
}

private struct ScreenshotCopyButton: View {
    @ObservedObject var controller: CommentInputController
    @ObservedObject private var localization = LocalizationManager.shared
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false

    private var hasError: Bool { controller.screenshotCopyError != nil }

    var body: some View {
        Button(action: { controller.copyScreenshot() }) {
            HStack(spacing: 5) {
                if controller.captureTransaction == .copying {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.75)
                        .frame(width: 13, height: 13)
                } else {
                    Image(systemName: hasError ? "exclamationmark.circle" : "doc.on.doc")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(hasError
                            ? Color.remarcError(for: colorScheme)
                            : Color.remarcPrimary(for: colorScheme))
                }
                Text(L10n.tr("Copy Image Only"))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(hasError
                        ? Color.remarcError(for: colorScheme)
                        : Color.primary.opacity(isHovered ? 0.95 : 0.85))
                    .fixedSize()
                Text("⌘C")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Color.secondary.opacity(0.85))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color.primary.opacity(colorScheme == .dark ? 0.1 : 0.06))
                    )
                    .fixedSize()
            }
            .padding(.horizontal, 10)
            .frame(height: ScreenshotCopyButtonGeometry.height)
            .background(
                Capsule()
                    .fill(Color.remarcPrimary(for: colorScheme).opacity(isHovered ? 0.14 : 0.05))
            )
            .overlay(
                Capsule()
                    .strokeBorder(
                        hasError
                            ? Color.remarcError(for: colorScheme).opacity(0.45)
                            : Color.primary.opacity(isHovered ? 0.2 : 0.12),
                        lineWidth: 0.75
                    )
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(controller.captureTransaction != .idle)
        .onHover { isHovered = $0 }
        .help(controller.screenshotCopyError
              ?? L10n.tr("Copy the screenshot and annotations without saving a comment"))
        .accessibilityLabel(AppIdentity.current.displayName + " · " + L10n.tr("Copy Image Only"))
        .accessibilityValue(controller.screenshotCopyError ?? "")
        .accessibilityIdentifier("remarc.screenshot.copyImageButton")
    }
}
