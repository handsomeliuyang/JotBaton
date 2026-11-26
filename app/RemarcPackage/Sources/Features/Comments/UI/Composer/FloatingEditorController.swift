import CoreLocalization
import CorePlatform
import CoreTheme
import CoreUI
import FeatureComments
import FeatureSettings
import AppKit
import Combine
import SwiftUI

private class KeyableEditorPanel: NSPanel {
    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        Task { @MainActor in
            FloatingEditorController.shared.dismiss()
        }
    }
}

@MainActor
public final class FloatingEditorController: ObservableObject {
    public static let shared = FloatingEditorController()

    @Published public var isVisible: Bool = false
    @Published public var currentText: String = ""
    @Published public var currentAttachments: [String] = []
    @Published public var targetSessionID: UUID?
    @Published public private(set) var saveFeedbackTrigger: Int = 0
    @Published public private(set) var validationFeedbackTrigger: Int = 0
    @Published public private(set) var editorWidth: CGFloat = WorkspaceMetrics.editorDefaultWidth
    public var suppressClickOutside: Bool = false

    private let userDefaults: UserDefaults
    private var panel: NSPanel?
    private var editorHostingView: NSHostingView<FloatingEditorWrapper>?
    private var dimOverlay: NSPanel?
    private let referenceWindowController = ReferenceTextWindowController()
    private let clickOutsideMonitor = ClickOutsideMonitor()
    private var contentCancellable: AnyCancellable?
    private var initialText: String = ""
    private var initialAttachments: [String] = []
    private var currentCommentType: CommentType?
    private var currentSaveAction: ((String, [String]) -> Bool)?
    private var currentSuccessMessage: String?
    private var presentationGeneration: UInt64 = 0

    public init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    public var currentPresentationGeneration: UInt64 { presentationGeneration }

    var hasUnsavedChanges: Bool {
        currentText.trimmingCharacters(in: .whitespacesAndNewlines)
            != initialText.trimmingCharacters(in: .whitespacesAndNewlines)
            || currentAttachments != initialAttachments
    }

    /// Show editor for editing an existing comment
    public func showForEdit(comment: Comment) {
        show(
            referenceText: comment.type.displayText,
            screenshotImagePath: comment.type.imagePath,
            comment: comment,
            initialText: comment.commentText,
            initialAttachments: comment.attachments,
            commentType: comment.type,
            targetSessionID: comment.sessionID,
            successMessage: L10n.tr("Comment updated"),
            onSave: { newText, newAttachments in
                AppServices.shared.comments.updateComment(
                    comment.id,
                    text: newText,
                    attachments: newAttachments
                )
            }
        )
    }

    /// Show editor for creating a quick note
    public func showForQuickNote() {
        // Repeated shortcuts and menu actions must never replace an open draft.
        if CommentInputController.shared.isVisible {
            CommentInputController.shared.bringToFront()
            return
        }
        if isVisible {
            bringToFront()
            return
        }
        show(
            referenceText: nil,
            screenshotImagePath: nil,
            comment: nil,
            initialText: "",
            initialAttachments: [],
            commentType: .quickNote,
            targetSessionID: AppServices.shared.comments.appState.activeSessionID,
            successMessage: L10n.tr("Quick note saved"),
            onSave: { text, attachments in
                AppServices.shared.comments.createComment(
                    type: .quickNote,
                    commentText: text,
                    source: "Quick Note",
                    appBundleID: nil,
                    attachments: attachments,
                    targetSessionID: self.targetSessionID
                ) != nil
            }
        )
    }

    public func bringToFront() {
        guard isVisible, !suppressClickOutside else { return }
        dimOverlay?.orderFront(nil)
        panel?.makeKeyAndOrderFront(nil)
    }

    /// Temporarily hide editor and dim overlay so system dialogs (NSOpenPanel) appear unobstructed.
    /// NSOpenPanel runs out-of-process and its window level cannot be controlled by the host app.
    public func orderOutForSystemDialog() {
        panel?.orderOut(nil)
        dimOverlay?.orderOut(nil)
    }

    /// Re-show editor and dim overlay after a system dialog is dismissed.
    public func orderFrontAfterSystemDialog() {
        dimOverlay?.orderFront(nil)
        panel?.makeKeyAndOrderFront(nil)
    }

    func isCurrentPresentation(_ generation: UInt64) -> Bool {
        presentationGeneration == generation
    }

    func showFullReference(_ text: String, presentationGeneration generation: UInt64) {
        guard isCurrentPresentation(generation), isVisible, let panel else { return }
        referenceWindowController.show(reference: text, over: panel)
    }

    private func attemptSave(text: String, attachments: [String]) {
        // Button and Command-Return saves converge here.

        guard let type = currentCommentType,
              let saveAction = currentSaveAction
        else {
            debugLog("FloatingEditorController: Save refused - no active draft")
            return
        }

        guard CommentSavePolicy.allowsSave(
            type: type,
            commentText: text,
            attachments: attachments
        ) else {
            triggerSaveFeedback(announcement: L10n.tr("Add text to save this Quick Note"))
            debugLog("FloatingEditorController: Empty Quick Note save refused")
            return
        }

        guard saveAction(text, attachments) else {
            ToastManager.shared.show(L10n.tr("Comment could not be saved"))
            triggerSaveFeedback(announcement: L10n.tr("Comment could not be saved"))
            debugLog("FloatingEditorController: Comment save failed")
            return
        }

        if let currentSuccessMessage {
            ToastManager.shared.show(currentSuccessMessage)
        }
        dismiss()
    }

    private func triggerSaveFeedback(announcement: String? = nil) {
        saveFeedbackTrigger &+= 1
        guard let announcement else { return }
        validationFeedbackTrigger &+= 1
        panel?.makeKeyAndOrderFront(nil)
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [
                .announcement: announcement,
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ]
        )
    }

    private func resetDraftState() {
        currentCommentType = nil
        currentSaveAction = nil
        currentSuccessMessage = nil
        currentText = ""
        initialText = ""
        currentAttachments = []
        initialAttachments = []
        targetSessionID = nil
        saveFeedbackTrigger = 0
        validationFeedbackTrigger = 0
        suppressClickOutside = false
    }

    public func dismiss() {
        referenceWindowController.dismiss()
        presentationGeneration &+= 1
        clickOutsideMonitor.remove()
        contentCancellable?.cancel()
        contentCancellable = nil
        isVisible = false
        resetDraftState()

        let panelRef = panel
        let overlayRef = dimOverlay

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panelRef?.animator().alphaValue = 0
            overlayRef?.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            Task { @MainActor in
                panelRef?.orderOut(nil)
                panelRef?.alphaValue = 1
                overlayRef?.orderOut(nil)
                overlayRef?.alphaValue = 1
                // Only release references if they still point at this dismissed
                // presentation. A replacement editor may already own new panels.
                if self?.panel === panelRef {
                    self?.panel = nil
                    self?.editorHostingView = nil
                }
                if self?.dimOverlay === overlayRef {
                    self?.dimOverlay = nil
                }
            }
        }
    }

    private func show(
        referenceText: String?,
        screenshotImagePath: String?,
        comment: Comment?,
        initialText: String,
        initialAttachments: [String],
        commentType: CommentType,
        targetSessionID: UUID?,
        successMessage: String,
        onSave: @escaping (String, [String]) -> Bool
    ) {
        // Dismiss any previous editor
        dismiss()
        presentationGeneration &+= 1
        let generation = presentationGeneration

        // Track text and attachments for click-outside dismiss behavior
        self.initialText = initialText
        self.currentText = initialText
        self.initialAttachments = initialAttachments
        self.currentAttachments = initialAttachments
        self.currentCommentType = commentType
        self.currentSaveAction = onSave
        self.currentSuccessMessage = successMessage
        self.targetSessionID = targetSessionID
        self.saveFeedbackTrigger = 0
        self.validationFeedbackTrigger = 0

        // Create dim overlay on top of the popover
        installDimOverlay(generation: generation)

        // Load persisted width and clamp to the target screen's visible width
        let targetScreen = NSScreen.bestScreen(for: getPopoverPanel())
        let initialWidth = EditorWidthPolicy.loadWidth(
            from: userDefaults,
            visibleScreenWidth: targetScreen.visibleFrame.width
        )
        self.editorWidth = initialWidth

        // Create editor panel
        let wrapper = FloatingEditorWrapper(
            controller: self,
            presentationGeneration: generation,
            initialText: initialText,
            initialAttachments: initialAttachments,
            screenshotImagePath: screenshotImagePath,
            referenceText: referenceText,
            comment: comment,
            onSave: { [weak self] text, attachments in
                guard let self, self.presentationGeneration == generation else { return }
                self.attemptSave(text: text, attachments: attachments)
            },
            onCancel: { [weak self] in
                guard let self, self.presentationGeneration == generation else { return }
                self.dismiss()
            }
        )

        let panel = KeyableEditorPanel(
            contentRect: NSRect(x: 0, y: 0, width: initialWidth, height: 300),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 2)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.animationBehavior = .none

        // NSVisualEffectView as contentView with maskImage — same pattern as popover.
        // This tells the window server the rounded shape for correct backdrop blur compositing.
        let visualEffectView = NSVisualEffectView()
        visualEffectView.material = .popover
        visualEffectView.blendingMode = .behindWindow
        visualEffectView.state = .active
        visualEffectView.maskImage = .roundedRectMask(cornerRadius: ThemeMetrics.panelCornerRadius)
        panel.contentView = visualEffectView

        // NSHostingView as subview of VEV — NO SwiftUI material backgrounds.
        let hostingView = NSHostingView(rootView: wrapper)
        hostingView.sizingOptions = [.intrinsicContentSize]

        // Measure ideal size first, then size the panel to fit (capped to screen height)
        let fittingSize = hostingView.fittingSize
        let initialHeight = EditorWidthPolicy.verticalFrame(
            fittingHeight: fittingSize.height,
            aroundMidY: targetScreen.visibleFrame.midY,
            visibleScreenFrame: targetScreen.visibleFrame
        ).height
        panel.setContentSize(NSSize(width: initialWidth, height: initialHeight))

        // Pin with Auto Layout
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        visualEffectView.addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.topAnchor.constraint(equalTo: visualEffectView.topAnchor),
            hostingView.leadingAnchor.constraint(equalTo: visualEffectView.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: visualEffectView.trailingAnchor),
            hostingView.bottomAnchor.constraint(equalTo: visualEffectView.bottomAnchor),
        ])

        // Install leading and trailing edge resize handles above the hosting view
        let handleWidth: CGFloat = 6
        let leadingHandle = makeResizeHandle(edge: .leading, generation: generation)
        let trailingHandle = makeResizeHandle(edge: .trailing, generation: generation)
        visualEffectView.addSubview(leadingHandle)
        visualEffectView.addSubview(trailingHandle)
        NSLayoutConstraint.activate([
            leadingHandle.topAnchor.constraint(equalTo: visualEffectView.topAnchor),
            leadingHandle.bottomAnchor.constraint(equalTo: visualEffectView.bottomAnchor),
            leadingHandle.leadingAnchor.constraint(equalTo: visualEffectView.leadingAnchor),
            leadingHandle.widthAnchor.constraint(equalToConstant: handleWidth),

            trailingHandle.topAnchor.constraint(equalTo: visualEffectView.topAnchor),
            trailingHandle.bottomAnchor.constraint(equalTo: visualEffectView.bottomAnchor),
            trailingHandle.trailingAnchor.constraint(equalTo: visualEffectView.trailingAnchor),
            trailingHandle.widthAnchor.constraint(equalToConstant: handleWidth),
        ])

        self.editorHostingView = hostingView

        // Position centered over the popover, fade in
        positionEditorPanel(panel)
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }

        self.panel = panel
        isVisible = true
        clickOutsideMonitor.install(
            for: panel,
            shouldDismiss: { [weak self] in
                guard let self, self.presentationGeneration == generation else { return false }
                return !self.suppressClickOutside && !self.hasUnsavedChanges
                    && !self.referenceWindowController.isVisible
            },
            dismiss: { [weak self] in
                guard let self, self.presentationGeneration == generation else { return }
                self.dismiss()
            }
        )
        installContentObserver()
    }

    private func positionEditorPanel(_ panel: NSPanel) {
        guard let popoverPanel = getPopoverPanel() else {
            panel.center()
            return
        }

        let popoverFrame = popoverPanel.frame

        // Center the editor over the popover panel
        let editorX = popoverFrame.midX - panel.frame.width / 2
        let editorY = popoverFrame.midY - panel.frame.height / 2

        // Clamp to the screen the popover is actually on, not NSScreen.main
        let screen = NSScreen.bestScreen(for: popoverPanel)
        let screenFrame = screen.visibleFrame
        let clampedX = max(screenFrame.minX + 8, min(editorX, screenFrame.maxX - panel.frame.width - 8))
        let clampedY = max(screenFrame.minY + 8, min(editorY, screenFrame.maxY - panel.frame.height - 8))

        panel.setFrameOrigin(NSPoint(x: clampedX, y: clampedY))
    }

    private func installDimOverlay(generation: UInt64) {
        guard let popoverPanel = getPopoverPanel() else { return }

        let overlay = NSPanel(
            contentRect: popoverPanel.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        overlay.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1)
        overlay.backgroundColor = .clear
        overlay.isOpaque = false
        overlay.hasShadow = false
        overlay.ignoresMouseEvents = false  // Receives clicks to block popover interaction
        overlay.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        overlay.animationBehavior = .none

        // Custom NSView that draws a rounded dim and dismisses the editor on click
        let dimView = DimOverlayContentView(cornerRadius: ThemeMetrics.panelCornerRadius)
        dimView.onMouseDown = { [weak self] in
            Task { @MainActor in
                guard let self,
                      self.presentationGeneration == generation,
                      !self.referenceWindowController.isVisible,
                      !self.hasUnsavedChanges
                else { return }
                self.dismiss()
            }
        }
        overlay.contentView = dimView

        // Inset the overlay to cover only the popover body, excluding the arrow area.
        // The arrow occupies the top `popoverArrowHeight` of the frame (highest y in screen coords).
        let arrowH = WorkspaceMetrics.popoverArrowHeight
        let bodyFrame = NSRect(
            x: popoverPanel.frame.origin.x,
            y: popoverPanel.frame.origin.y,
            width: popoverPanel.frame.width,
            height: popoverPanel.frame.height - arrowH
        )
        overlay.setFrame(bodyFrame, display: true)
        overlay.alphaValue = 0
        overlay.orderFront(nil)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            overlay.animator().alphaValue = 1
        }

        self.dimOverlay = overlay
    }

    // MARK: - Content Size Observer

    private func installContentObserver() {
        contentCancellable?.cancel()
        contentCancellable = Publishers.Merge(
            $currentText.map { _ in () },
            $currentAttachments.map { _ in () }
        )
        .debounce(for: .milliseconds(50), scheduler: DispatchQueue.main)
        .sink { [weak self] _ in
            self?.resizePanelToFit()
        }
    }

    private func makeResizeHandle(edge: EditorResizeEdge, generation: UInt64) -> EdgeResizeHandleView {
        let handle = EdgeResizeHandleView(edge: edge)
        handle.onDragChanged = { [weak self] initialFrame, deltaX in
            self?.handleResizeDrag(
                edge: edge,
                initialFrame: initialFrame,
                deltaX: deltaX,
                generation: generation
            )
        }
        handle.onDragEnded = { [weak self] in
            self?.handleResizeDragEnded(generation: generation)
        }
        handle.onDoubleClick = { [weak self] in
            self?.handleResetWidthToDefault(generation: generation)
        }
        return handle
    }

    private func handleResizeDrag(
        edge: EditorResizeEdge,
        initialFrame: NSRect,
        deltaX: CGFloat,
        generation: UInt64
    ) {
        guard presentationGeneration == generation,
              let panel,
              let hostingView = editorHostingView else { return }

        let screen = NSScreen.bestScreen(for: panel)
        let horizontal = EditorWidthPolicy.resizedHorizontalFrame(
            edge: edge,
            initialFrame: initialFrame,
            deltaX: deltaX,
            visibleScreenFrame: screen.visibleFrame
        )

        if abs(editorWidth - horizontal.width) > 0.5 {
            editorWidth = horizontal.width
            hostingView.invalidateIntrinsicContentSize()
            hostingView.layoutSubtreeIfNeeded()
        }

        resizePanelToFit(targetX: horizontal.x, animate: false)
    }

    private func handleResizeDragEnded(generation: UInt64) {
        guard presentationGeneration == generation else { return }
        EditorWidthPolicy.saveWidth(editorWidth, to: userDefaults)
        // Perform one non-animated height check after the run loop settles in case
        // SwiftUI completed an asynchronous text reflow pass on the final drag tick.
        Task { @MainActor [weak self] in
            guard let self, self.presentationGeneration == generation else { return }
            self.editorHostingView?.layoutSubtreeIfNeeded()
            self.resizePanelToFit(animate: false)
        }
    }

    private func handleResetWidthToDefault(generation: UInt64) {
        guard presentationGeneration == generation,
              let panel,
              let hostingView = editorHostingView else { return }

        let screen = NSScreen.bestScreen(for: panel)
        let horizontal = EditorWidthPolicy.centeredHorizontalFrame(
            targetWidth: WorkspaceMetrics.editorDefaultWidth,
            aroundMidX: panel.frame.midX,
            visibleScreenFrame: screen.visibleFrame
        )
        editorWidth = horizontal.width
        EditorWidthPolicy.saveWidth(horizontal.width, to: userDefaults)
        hostingView.invalidateIntrinsicContentSize()
        hostingView.layoutSubtreeIfNeeded()
        resizePanelToFit(targetX: horizontal.x, animate: true)
    }

    private func resizePanelToFit(targetX: CGFloat? = nil, animate: Bool = true) {
        guard let panel = panel, let hostingView = editorHostingView else { return }
        let fittingSize = hostingView.fittingSize
        let currentFrame = panel.frame
        let resolvedX = targetX ?? currentFrame.origin.x
        let targetWidth = editorWidth

        let screen = NSScreen.bestScreen(for: panel)
        let vertical = EditorWidthPolicy.verticalFrame(
            fittingHeight: fittingSize.height,
            aroundMidY: currentFrame.midY,
            visibleScreenFrame: screen.visibleFrame
        )

        let xChanged = abs(currentFrame.origin.x - resolvedX) > 0.5
        let widthChanged = abs(currentFrame.width - targetWidth) > 0.5
        let heightChanged = abs(currentFrame.height - vertical.height) > 1
        let yChanged = abs(currentFrame.origin.y - vertical.y) > 1
        guard xChanged || widthChanged || heightChanged || yChanged else { return }

        let newFrame = NSRect(
            x: resolvedX,
            y: vertical.y,
            width: targetWidth,
            height: vertical.height
        )
        panel.setFrame(newFrame, display: true, animate: animate)
        panel.invalidateShadow()
    }

    private func getPopoverPanel() -> NSPanel? {
        for window in NSApp.windows {
            if let panel = window as? NSPanel,
               panel.identifier == NSUserInterfaceItemIdentifier("remarc.popover"),
               panel.isVisible {
                return panel
            }
        }
        return nil
    }

}

// MARK: - Dim Overlay Content View

/// Custom NSView that draws a rounded dim rectangle and forwards clicks to dismiss the editor.
/// Direct mouseDown handling is more reliable than NSEvent monitors for .nonactivatingPanel windows.
private class DimOverlayContentView: NSView {
    var onMouseDown: (() -> Void)?
    private let cornerRadius: CGFloat

    init(cornerRadius: CGFloat) {
        self.cornerRadius = cornerRadius
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.3).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: cornerRadius, yRadius: cornerRadius).fill()
    }

    override func mouseDown(with event: NSEvent) {
        onMouseDown?()
    }
}

// MARK: - Floating Editor Wrapper

struct FloatingEditorWrapper: View {
    @ObservedObject private var localization = LocalizationManager.shared
    @ObservedObject var controller: FloatingEditorController
    @State private var text: String
    @State private var attachments: [String]

    let presentationGeneration: UInt64
    let screenshotImagePath: String?
    let referenceText: String?
    let comment: Comment?
    let onSave: (String, [String]) -> Void
    let onCancel: () -> Void

    init(controller: FloatingEditorController, presentationGeneration: UInt64, initialText: String, initialAttachments: [String], screenshotImagePath: String?, referenceText: String?, comment: Comment?, onSave: @escaping (String, [String]) -> Void, onCancel: @escaping () -> Void) {
        self.controller = controller
        self.presentationGeneration = presentationGeneration
        _text = State(initialValue: initialText)
        _attachments = State(initialValue: initialAttachments)
        self.screenshotImagePath = screenshotImagePath
        self.referenceText = referenceText
        self.comment = comment
        self.onSave = onSave
        self.onCancel = onCancel
    }

    var body: some View {
        CommentEditorView(
            commentText: $text,
            attachments: $attachments,
            screenshotImagePath: screenshotImagePath,
            referenceText: referenceText,
            comment: comment,
            presentationGeneration: presentationGeneration,
            onSave: onSave,
            onCancel: onCancel
        )
        .frame(width: controller.editorWidth)
        // Material background and shadow provided by NSVisualEffectView + maskImage
        // in FloatingEditorController — no SwiftUI material backgrounds here.
        .onRemarcChange(of: text) { newValue in
            guard controller.isCurrentPresentation(presentationGeneration) else { return }
            controller.currentText = newValue
        }
        .onRemarcChange(of: attachments) { newValue in
            guard controller.isCurrentPresentation(presentationGeneration) else { return }
            controller.currentAttachments = newValue
        }
    }
}
