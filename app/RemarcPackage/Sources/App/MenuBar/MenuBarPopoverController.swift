import CorePlatform
import CoreTheme
import CoreUI
import AppKit
import SwiftUI
import Combine

private class KeyablePopoverPanel: NSPanel {
    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        Task { @MainActor in
            MenuBarPopoverController.shared.dismiss()
        }
    }
}

@MainActor
public final class MenuBarPopoverController: NSObject, ObservableObject {
    public static let shared = MenuBarPopoverController()

    @Published public var isVisible: Bool = false
    @Published public var isDetached: Bool = false
    /// When true, prevents click-outside dismissal while another app workflow is active.
    public var preventDismiss: Bool = false

    /// Makes the panel the key window (needed for TextField caret in non-activating panels).
    public func makeKey() {
        panel?.makeKey()
    }

    /// Set by AppController so we can position below the status item.
    public var statusItemButton: NSStatusBarButton?

    private var panel: NSPanel?
    private let clickOutsideMonitor = ClickOutsideMonitor()

    private override init() {
        super.init()
    }

    // MARK: - Public API

    public func toggle() {
        if isDetached {
            DetachedWindowController.shared.bringToFront()
            return
        }
        if isVisible {
            guard !preventDismiss else { return }
            dismiss()
        } else {
            show()
        }
    }

    public func show() {
        let wasVisible = isVisible || DetachedWindowController.shared.isVisible
        if panel == nil {
            createPanel()
        }
        positionBelowStatusItem()

        guard let panel = panel else { return }

        // Animate in: start slightly above and transparent, slide down + fade in
        let finalFrame = panel.frame
        panel.setFrame(finalFrame.offsetBy(dx: 0, dy: 6), display: false)
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(finalFrame, display: true)
            panel.animator().alphaValue = 1
        }

        isVisible = true
        Task { await AppServices.shared.snapshots.mainInterfaceDidShow(wasVisible: wasVisible) }
        clickOutsideMonitor.install(for: panel, shouldDismiss: { [weak self] in !(self?.preventDismiss ?? false) }, dismiss: { [weak self] in self?.dismiss() })
        // Comment/history lists suppress their own scrollers. Keep navigation
        // scrollers available so long session lists follow system preferences.
        debugLog("MenuBarPopoverController: shown")
    }

    public func dismiss() {
        guard let panel = panel else { return }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
            panel.animator().setFrame(panel.frame.offsetBy(dx: 0, dy: 6), display: true)
        } completionHandler: { [weak self] in
            panel.orderOut(nil)
            panel.alphaValue = 1  // Reset for next show
            self?.clickOutsideMonitor.remove()
            self?.isVisible = false
            debugLog("MenuBarPopoverController: dismissed")
        }
    }

    // MARK: - Panel Creation

    private func createPanel() {
        let panel = KeyablePopoverPanel(
            contentRect: NSRect(x: 0, y: 0, width: WorkspaceMetrics.popoverWidth, height: WorkspaceMetrics.popoverHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .popUpMenu
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true  // shadow follows VEV mask shape
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.animationBehavior = .utilityWindow
        panel.identifier = NSUserInterfaceItemIdentifier("remarc.popover")
        // Do NOT set panel.appearance — causes vibrancy mismatch on material backgrounds

        // NSVisualEffectView as contentView with maskImage.
        // This communicates the rounded shape to the window server so backdrop blur
        // is composited in the correct shape — eliminating corner artifacts.
        let visualEffectView = NSVisualEffectView()
        visualEffectView.material = .popover
        visualEffectView.blendingMode = .behindWindow
        visualEffectView.state = .active  // prevents dimming on focus loss
        panel.contentView = visualEffectView

        // NSHostingView as subview of VEV — NOT as panel.contentView.
        // The SwiftUI content must have NO .background(.regularMaterial) since VEV provides it.
        // topInset pushes the content below the arrow strip while the SwiftUI background
        // gradient fills the full panel — otherwise the arrow renders bare VEV material
        // and visibly differs in color from the gradient-tinted body.
        let arrowH = WorkspaceMetrics.popoverArrowHeight
        let contentView = PopoverContentView(topInset: arrowH)
        let hostingView = NSHostingView(rootView: contentView)
        // The panel owns its size. Content changes update the scroll views,
        // without adding intrinsic size constraints that could resize the window.
        hostingView.sizingOptions = []

        // Pin hosting view to VEV edges with Auto Layout — full panel, including the arrow strip.
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        visualEffectView.addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.topAnchor.constraint(equalTo: visualEffectView.topAnchor),
            hostingView.leadingAnchor.constraint(equalTo: visualEffectView.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: visualEffectView.trailingAnchor),
            hostingView.bottomAnchor.constraint(equalTo: visualEffectView.bottomAnchor),
        ])

        // Apply a placeholder mask with centered arrow — real mask set in positionBelowStatusItem()
        let placeholderSize = panel.frame.size
        visualEffectView.maskImage = Self.maskImage(
            size: placeholderSize,
            cornerRadius: ThemeMetrics.panelCornerRadius,
            arrowWidth: WorkspaceMetrics.popoverArrowWidth,
            arrowHeight: arrowH,
            arrowCenterX: placeholderSize.width / 2
        )

        self.panel = panel
    }

    /// Creates a full-size mask image with a rounded-rect body and an upward-pointing arrow.
    /// Rendered at exact panel size (no stretchable caps) so the arrow position is pixel-accurate.
    /// The window server uses this to composite backdrop blur in the correct shape.
    private static func maskImage(
        size: NSSize,
        cornerRadius: CGFloat,
        arrowWidth: CGFloat,
        arrowHeight: CGFloat,
        arrowCenterX: CGFloat
    ) -> NSImage {
        // flipped: true so y=0 is at top (arrow tip at top, body below)
        let img = NSImage(size: size, flipped: true) { rect in
            let bodyTop = arrowHeight

            let path = NSBezierPath()
            let cr = cornerRadius
            let halfArrow = arrowWidth / 2
            let tipRadius: CGFloat = 2  // slight rounding at the arrow tip

            // Start at top-left corner of body (after corner arc)
            path.move(to: NSPoint(x: 0, y: bodyTop + cr))

            // Top-left corner
            path.appendArc(
                from: NSPoint(x: 0, y: bodyTop),
                to: NSPoint(x: cr, y: bodyTop),
                radius: cr
            )

            // Top edge to arrow left base
            path.line(to: NSPoint(x: arrowCenterX - halfArrow, y: bodyTop))

            // Arrow: left side up to tip, then right side down — cubic curves for smooth shape
            let tipY: CGFloat = tipRadius  // tip nearly at top, offset by tip radius
            path.curve(
                to: NSPoint(x: arrowCenterX, y: tipY),
                controlPoint1: NSPoint(x: arrowCenterX - halfArrow * 0.3, y: bodyTop),
                controlPoint2: NSPoint(x: arrowCenterX - tipRadius, y: tipY)
            )
            path.curve(
                to: NSPoint(x: arrowCenterX + halfArrow, y: bodyTop),
                controlPoint1: NSPoint(x: arrowCenterX + tipRadius, y: tipY),
                controlPoint2: NSPoint(x: arrowCenterX + halfArrow * 0.3, y: bodyTop)
            )

            // Top edge from arrow right base to top-right corner
            path.line(to: NSPoint(x: rect.width - cr, y: bodyTop))

            // Top-right corner
            path.appendArc(
                from: NSPoint(x: rect.width, y: bodyTop),
                to: NSPoint(x: rect.width, y: bodyTop + cr),
                radius: cr
            )

            // Right edge
            path.line(to: NSPoint(x: rect.width, y: rect.height - cr))

            // Bottom-right corner
            path.appendArc(
                from: NSPoint(x: rect.width, y: rect.height),
                to: NSPoint(x: rect.width - cr, y: rect.height),
                radius: cr
            )

            // Bottom edge
            path.line(to: NSPoint(x: cr, y: rect.height))

            // Bottom-left corner
            path.appendArc(
                from: NSPoint(x: 0, y: rect.height),
                to: NSPoint(x: 0, y: rect.height - cr),
                radius: cr
            )

            // Left edge back to start
            path.close()

            NSColor.black.set()
            path.fill()
            return true
        }
        // No capInsets or stretch — rendered at exact panel size
        return img
    }

    // MARK: - Positioning

    private func positionBelowStatusItem() {
        guard let panel = panel else { return }

        let button = statusItemButton
        let buttonWindow = button?.window
        let screen = NSScreen.bestScreen(for: buttonWindow ?? panel)
        let visibleFrame = screen.visibleFrame
        let buttonFrame = button.flatMap { button -> NSRect? in
            guard let window = button.window else { return nil }
            return window.convertToScreen(button.convert(button.bounds, to: nil))
        }
        let anchorX = buttonFrame?.midX ?? visibleFrame.midX
        let anchorY = min(buttonFrame?.minY ?? visibleFrame.maxY, visibleFrame.maxY)
        let bottomMargin: CGFloat = 8
        let availableHeight = max(1, anchorY - WorkspaceMetrics.popoverGap - visibleFrame.minY - bottomMargin)
        let height = min(WorkspaceMetrics.popoverHeight, availableHeight)
        panel.setContentSize(NSSize(width: WorkspaceMetrics.popoverWidth, height: height))

        let x = max(visibleFrame.minX + 8,
                    min(anchorX - panel.frame.width / 2, visibleFrame.maxX - panel.frame.width - 8))
        let y = max(anchorY - height - WorkspaceMetrics.popoverGap, visibleFrame.minY + bottomMargin)
        panel.setFrameOrigin(NSPoint(x: x, y: y))
        applyMask(arrowCenterX: anchorX - panel.frame.minX)
    }

    /// Applies the arrow mask to the VEV at the given arrow X position, clamped to stay within the body.
    private func applyMask(arrowCenterX: CGFloat) {
        guard let panel = panel,
              let vev = panel.contentView as? NSVisualEffectView else { return }

        let cr = ThemeMetrics.panelCornerRadius
        let arrowW = WorkspaceMetrics.popoverArrowWidth
        let arrowH = WorkspaceMetrics.popoverArrowHeight
        let panelSize = panel.frame.size

        // Clamp arrow to stay within body (at least cornerRadius + halfArrow + 2 from edges)
        let minX = cr + arrowW / 2 + 2
        let maxX = panelSize.width - cr - arrowW / 2 - 2
        let clampedX = max(minX, min(arrowCenterX, maxX))

        vev.maskImage = Self.maskImage(
            size: panelSize,
            cornerRadius: cr,
            arrowWidth: arrowW,
            arrowHeight: arrowH,
            arrowCenterX: clampedX
        )
        panel.invalidateShadow()
    }

}
