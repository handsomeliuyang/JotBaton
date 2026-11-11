import AppKit
import SwiftUI

/// Own the native popover so its measured size and anchor are set before show.
struct SnapshotSyncPopoverAnchor: NSViewRepresentable {
    @Binding var isPresented: Bool
    let colorScheme: ColorScheme

    func makeCoordinator() -> SnapshotSyncPopoverController { SnapshotSyncPopoverController() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 26, height: 26))
        view.autoresizingMask = [.width, .height]
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        let binding = $isPresented
        context.coordinator.onClose = {
            if binding.wrappedValue { binding.wrappedValue = false }
        }
        if isPresented {
            context.coordinator.show(relativeTo: view, colorScheme: colorScheme)
        } else {
            context.coordinator.close()
        }
    }

    static func dismantleNSView(_ view: NSView, coordinator: SnapshotSyncPopoverController) {
        coordinator.onClose = nil
        coordinator.close()
    }
}

@MainActor
final class SnapshotSyncPopoverController: NSObject, NSPopoverDelegate {
    let popover = NSPopover()
    private(set) var documentSize: CGSize = .zero
    private var hostingView: NSHostingView<AnyView>?
    private var scrollView: NSScrollView?
    private var width: CGFloat = 340
    private var maxHeight: CGFloat = 600
    private weak var anchorView: NSView?
    private var outsideClickMonitor: Any?
    var onClose: (() -> Void)?

    override init() {
        super.init()
        popover.delegate = self
        popover.behavior = .semitransient
        // AppKit otherwise animates contentSize changes after the first paint.
        popover.animates = false
    }

    func show(relativeTo anchor: NSView, colorScheme: ColorScheme) {
        guard !popover.isShown, anchor.window != nil else { return }
        let screen = NSScreen.bestScreen(for: anchor.window)
        prepare(screenSize: screen.visibleFrame.size, colorScheme: colorScheme) {
            SnapshotSyncControls(compact: true)
                .accessibilityIdentifier("sync.popover")
        }
        anchor.window?.contentView?.layoutSubtreeIfNeeded()
        anchorView = anchor
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        outsideClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, self.popover.isShown else { return event }
            let window = self.scrollView?.window
            if event.window === window || window?.attachedSheet != nil { return event }
            if let anchor = self.anchorView, event.window === anchor.window {
                let point = anchor.convert(event.locationInWindow, from: nil)
                if anchor.bounds.contains(point) { return event }
            }
            self.close()
            return event
        }
    }

    /// Also exercised without showing a window: the first native frame must
    /// already fit the content, rather than using a provisional height of 180.
    func prepare<Content: View>(screenSize: CGSize, colorScheme: ColorScheme, @ViewBuilder content: () -> Content) {
        width = min(340, max(1, screenSize.width - 32))
        maxHeight = max(1, screenSize.height * 0.8)
        let root = content()
            .environment(\.colorScheme, colorScheme)
            .frame(width: max(1, width - 32), alignment: .leading)
            .padding(16)
            .fixedSize(horizontal: false, vertical: true)
            .background {
                GeometryReader { geometry in
                    Color.clear.onRemarcChange(of: geometry.size) { [weak self] size in
                        self?.resize(to: size)
                    }
                }
            }
        let hosting = NSHostingView(rootView: AnyView(root))
        hosting.sizingOptions = [.intrinsicContentSize]
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: 1)
        hosting.layoutSubtreeIfNeeded()
        let measured = hosting.fittingSize
        hostingView = hosting

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = false
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        scroll.automaticallyAdjustsContentInsets = false
        scroll.documentView = hosting
        scrollView = scroll

        let controller = NSViewController()
        controller.view = scroll
        popover.contentViewController = controller
        resize(to: measured, force: true)
    }

    func resize(to size: CGSize, force: Bool = false) {
        guard size.height.isFinite, size.height > 0 else { return }
        let document = CGSize(width: width, height: ceil(size.height))
        let viewport = CGSize(width: width, height: min(document.height, maxHeight))
        guard force || documentSize != document else { return }
        documentSize = document
        hostingView?.setFrameSize(document)
        scrollView?.hasVerticalScroller = document.height > viewport.height
        scrollView?.setFrameSize(viewport)
        popover.contentSize = viewport
    }

    func close() { popover.performClose(nil) }

    func popoverDidClose(_ notification: Notification) {
        // A fresh hosted view is measured on the next click, including any
        // cloud/source/status changes made since this presentation.
        hostingView = nil
        scrollView = nil
        anchorView = nil
        if let monitor = outsideClickMonitor {
            NSEvent.removeMonitor(monitor)
            outsideClickMonitor = nil
        }
        popover.contentViewController = nil
        onClose?()
    }
}
