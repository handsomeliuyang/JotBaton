import CoreLocalization
import CorePlatform
import CoreUI
import FeatureCapture
import FeatureSettings
import AppKit

@MainActor
private final class KeyableOverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - ScreenCaptureService

@MainActor
public final class ScreenCaptureCoordinator {
    private let resolveComposer: () -> any ScreenshotComposer
    private var composer: any ScreenshotComposer { resolveComposer() }

    var overlayPanel: NSPanel?
    private var selectionView: RegionSelectionView?
    private var escapeMonitor: Any?
    private var globalEscapeMonitor: Any?
    private var onRegionSelectedCallback: ((_ captureRect: CGRect, _ sourceBundleID: String?) -> Void)?
    private var onCancelCallback: (() -> Void)?

    // Pending capture rect in global Quartz coordinates (origin top-left of primary display, Y down)
    private var pendingQuartzRect: CGRect?
    private var pendingSourceBundleID: String?

    // MARK: - Annotation state
    //
    // Owned here rather than in the controller because the canvas is a subview of
    // the overlay's region view and the stage math is expressed in that view's
    // local coordinates.

    /// The live capture session, if any. Also the re-entry guard: `startCapture`
    /// refuses while this is set, so a second hotkey press cannot overwrite the
    /// callbacks and pending state of an in-flight transaction. The guard lives
    /// here and not only in a controller wrapper because both real call sites
    /// reach the service directly, and the planned wake-screenshot hotkey would
    /// add a third on day one.
    private var captureIsLive = false

    private(set) var annotationSession: AnnotationSession?
    private let toolbarController = AnnotationToolbarPanelController()
    private let entryPillController = AnnotationEntryPillController()

    /// Selection `S` in region-view-local points, frozen at annotate-entry.
    private var pendingSelectionLocal: NSRect?
    private var overlayScreenFrame: NSRect?
    private var overlayScreen: NSScreen?

    private var stageAllowance: CGRect?
    private var stageMaxZoom = 1
    private(set) var stageEffectiveZoom = 1
    private var stageDisplayRectLocal: NSRect?
    private var isStageAnimating = false
    private var showsDiscardControls = false

    /// A prepared PNG plus the lease that owns it, handed to exactly one of
    /// `finalize` or `restore`.
    struct PreparedCapture {
        let token: UUID
        let relativePath: String
        let cgImage: CGImage
        let pointSize: CGSize
    }

    /// What a failed prepare may have left behind: no file, a lease with no file,
    /// or a file with a lease. A thrown error cannot carry this, which is why
    /// prepare returns an outcome rather than throwing.
    struct PreparedPartial {
        let relativePath: String?
        let leaseRecorded: Bool
    }

    enum PrepareOutcome {
        case success(PreparedCapture)
        case failure(Error, cleanup: PreparedPartial?)
    }

    enum ConcludeResult: Equatable {
        case finalized, restored, staleToken
    }

    private var activeToken: UUID?

    init(composer: @escaping () -> any ScreenshotComposer) { resolveComposer = composer }

    var isAnnotating: Bool { annotationSession != nil }
    var hasActiveCapture: Bool { captureIsLive || overlayPanel != nil || annotationSession != nil }

    var annotationCanvasHasCopyFocus: Bool {
        guard let canvas = selectionView?.annotationCanvas else { return false }
        return canvas.window?.isKeyWindow == true
            && canvas.window?.firstResponder === canvas
            && !canvas.hasActiveTextEdit
    }

    // MARK: - Public API

    /// Start a region capture flow.
    /// 1. Checks screen recording permission (shows panel if needed)
    /// 2. Shows full-screen overlay for region selection
    /// 3. Calls onRegionSelected immediately when user finishes selecting
    ///    (overlay stays visible — show comment input here)
    /// 4. Call `commitCapture()` later to dismiss overlay, capture, and save
    public func startCapture(
        onRegionSelected: @escaping (_ captureRect: CGRect, _ sourceBundleID: String?) -> Void,
        onCancel: @escaping () -> Void
    ) {
        // Both real call sites reach the service directly (GlobalHotkey,
        // PopoverContentView), so the guard has to be here. Overwriting callbacks
        // and pending state mid-transaction strands the first save.
        guard !captureIsLive else {
            debugLog("ScreenCaptureService: startCapture refused - a capture is already live")
            return
        }
        captureIsLive = true
        pendingSourceBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        self.onRegionSelectedCallback = onRegionSelected
        self.onCancelCallback = onCancel

        let permissionController = ScreenRecordingPermissionController.shared

        if permissionController.hasPermission() {
            showOverlay()
            return
        }

        permissionController.requestPermission { [weak self] granted in
            guard let self = self else { return }
            if granted {
                self.showOverlay()
            } else {
                debugLog("ScreenCaptureService: Permission denied - cancelling capture")
                self.cancel()
            }
        }
    }

    // MARK: - Overlay

    private func showOverlay() {
        // Use the screen under the mouse cursor (supports multi-monitor)
        let mouseLocation = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }) ?? NSScreen.main else {
            debugLog("ScreenCaptureService: No screen found")
            cancel()
            return
        }

        let screenFrame = screen.frame

        let panel = KeyableOverlayPanel(
            contentRect: screenFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .screenSaver
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.ignoresMouseEvents = false

        let regionView = RegionSelectionView(frame: screenFrame)
        regionView.onRegionSelected = { [weak self] rect in
            self?.handleRegionSelected(rect, screenFrame: screenFrame, screen: screen)
        }
        regionView.onRegionAdjusting = { [weak self] rect in
            self?.handleRegionMoved(rect, screenFrame: screenFrame, screen: screen, restoreFocus: false)
        }
        regionView.onRegionUpdated = { [weak self] rect in
            self?.handleRegionMoved(rect, screenFrame: screenFrame, screen: screen, restoreFocus: true)
        }
        regionView.onCancel = { [weak self] in
            self?.cancel()
        }

        panel.contentView = regionView
        panel.setFrame(screenFrame, display: true)
        panel.alphaValue = 0

        // Activate the app so key events (Escape) reach our panel and
        // the comment input panel renders at full fidelity. The overlay
        // sits at .screenSaver level; CGWindowListCreateImage captures
        // everything BELOW it, so activation's window reorder is invisible
        // to the final capture.
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(regionView)

        self.overlayPanel = panel
        self.selectionView = regionView
        self.overlayScreenFrame = screenFrame
        self.overlayScreen = screen

        // Local monitor consumes Escape when the app IS active (prevents beep).
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { // Escape
                self?.cancel()
                return nil // consume — no beep
            }
            return event
        }
        // Global monitor catches Escape when the app ISN'T active
        // (e.g., screenshot triggered via hotkey while another app has focus).
        globalEscapeMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { // Escape
                self?.cancel()
            }
        }

        // Fade in
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
    }

    private func removeEscapeMonitor() {
        if let monitor = escapeMonitor {
            NSEvent.removeMonitor(monitor)
            escapeMonitor = nil
        }
        if let monitor = globalEscapeMonitor {
            NSEvent.removeMonitor(monitor)
            globalEscapeMonitor = nil
        }
    }

    private func dismissOverlay() {
        removeEscapeMonitor()
        teardownAnnotation()
        entryPillController.teardown()
        overlayPanel?.orderOut(nil)
        overlayPanel = nil
        selectionView = nil
        overlayScreenFrame = nil
        overlayScreen = nil
        pendingSelectionLocal = nil
        captureIsLive = false
    }

    private func cancel() {
        dismissOverlay()
        captureIsLive = false
        let callback = onCancelCallback
        onCancelCallback = nil
        onRegionSelectedCallback = nil
        pendingQuartzRect = nil
        pendingSourceBundleID = nil
        callback?()
    }

    // MARK: - Capture

    private func updatePendingCapture(_ selectionRect: NSRect, screenFrame: NSRect, screen: NSScreen) {
        // Convert from view-local AppKit coordinates to global Quartz coordinates.
        // AppKit: origin bottom-left of primary screen, Y up.
        // Quartz: origin top-left of primary screen, Y down.
        // On multi-monitor, screenFrame.origin offsets the screen in AppKit global space.
        let primaryScreenHeight = NSScreen.screens.first?.frame.height ?? screenFrame.height
        pendingQuartzRect = CGRect(
            x: selectionRect.origin.x + screenFrame.origin.x,
            y: primaryScreenHeight - selectionRect.origin.y - screenFrame.origin.y - selectionRect.height,
            width: selectionRect.width,
            height: selectionRect.height
        )
    }

    private func handleRegionSelected(_ selectionRect: NSRect, screenFrame: NSRect, screen: NSScreen) {
        removeEscapeMonitor()
        pendingSelectionLocal = selectionRect
        updatePendingCapture(selectionRect, screenFrame: screenFrame, screen: screen)
        let callback = onRegionSelectedCallback
        onRegionSelectedCallback = nil
        let sourceBundleID = pendingSourceBundleID
        // Convert from overlay-local to screen-global coordinates
        let screenRect = selectionRect.offsetBy(dx: screenFrame.origin.x, dy: screenFrame.origin.y)
        callback?(screenRect, sourceBundleID)
        showEntryPill(selectionScreenRect: screenRect, screen: screen)
    }

    /// The Annotate pill, docked opposite the comment panel.
    ///
    /// Disabled until `panelLayoutReady`: `show()` schedules the panel's height
    /// work asynchronously and first-responder work later still, and the stage
    /// allowance reserves the panel's footprint, so entering earlier would size the
    /// stage from a stale frame.
    private func showEntryPill(selectionScreenRect rect: CGRect, screen: NSScreen) {
        entryPillController.onActivate = { [weak self] in self?.beginAnnotation() }
        entryPillController.show(
            selectionRectScreen: rect,
            panelEdge: composer.frozenStageEdge,
            on: screen,
            isEnabled: composer.panelLayoutReady)
        // Readiness arrives from the panel's deferred height pass, so subscribe
        // rather than poll: the poll and the height pass share one queue and the
        // poll wins, which left the pill permanently disabled.
        composer.onPanelLayoutReady = { [weak self] in
            guard let self, self.annotationSession == nil,
                  self.pendingSelectionLocal != nil else { return }
            self.entryPillController.show(
                selectionRectScreen: rect,
                panelEdge: composer.frozenStageEdge,
                on: screen,
                isEnabled: true)
        }
    }

    private func handleRegionMoved(_ selectionRect: NSRect, screenFrame: NSRect, screen: NSScreen, restoreFocus: Bool) {
        // Region geometry is locked while a frozen session exists. The parent view
        // already early-returns from its mouse machine, so this is belt and braces
        // against a queued callback.
        guard !isAnnotating else {
            debugLog("ScreenCaptureService: handleRegionMoved ignored - annotation session is live")
            return
        }
        pendingSelectionLocal = selectionRect
        updatePendingCapture(selectionRect, screenFrame: screenFrame, screen: screen)
        // Convert from overlay-local to screen-global coordinates
        let screenRect = selectionRect.offsetBy(dx: screenFrame.origin.x, dy: screenFrame.origin.y)
        composer.repositionForScreenshot(captureRect: screenRect, restoreFocus: restoreFocus)
        // The pill follows too. It used to stay wherever the first selection put
        // it, so resizing or moving the region left it stranded over the desktop.
        showEntryPill(selectionScreenRect: screenRect, screen: screen)
    }

    /// Capture the previously selected region, then dismiss the overlay and save.
    /// Uses CGWindowListCreateImage to grab everything below the overlay — this
    /// avoids SCKit's pixel-vs-point sourceRect ambiguity and timing races.
    public func commitCapture(onComplete: @escaping (_ imagePath: String) -> Void) {
        guard let quartzRect = pendingQuartzRect else {
            debugLog("ScreenCaptureService: commitCapture called with no pending capture")
            return
        }

        let overlayWID: CGWindowID
        if let wn = overlayPanel?.windowNumber, wn > 0 {
            overlayWID = CGWindowID(wn)
        } else {
            overlayWID = kCGNullWindowID
        }

        // Hide comment panel so it doesn't appear in the capture
        composer.orderOutForSystemDialog()

        pendingQuartzRect = nil
        onCancelCallback = nil

        do {
            let image = try captureRegion(quartzRect, belowWindowID: overlayWID)
            dismissOverlay()
            let relativePath = try saveImage(image)

            if SettingsManager.shared.copyScreenshotToClipboard {
                copyImageToPasteboard(image)
            }

            debugLog("ScreenCaptureService: Capture saved to \(relativePath)")
            pendingSourceBundleID = nil
            onComplete(relativePath)
        } catch {
            dismissOverlay()
            pendingSourceBundleID = nil
            debugLog("ScreenCaptureService: Capture failed - \(error)")
        }
    }

    /// Cancel the capture — dismiss overlay without capturing.
    public func cancelCapture() {
        pendingQuartzRect = nil
        cancel()
    }

    /// Capture a region of the screen using CGWindowListCreateImage.
    /// Grabs everything on-screen below the given window (our overlay), using
    /// Quartz global coordinates (points, origin top-left of main display).
    private func captureRegion(_ quartzRect: CGRect, belowWindowID: CGWindowID) throws -> NSImage {
        let cgImage = try captureRegionCGImage(quartzRect, belowWindowID: belowWindowID)
        return NSImage(
            cgImage: cgImage,
            size: NSSize(width: quartzRect.width, height: quartzRect.height)
        )
    }

    /// The single `CGWindowListCreateImage` seam.
    ///
    /// `CGWindowListCreateImage` is **unavailable**, not merely deprecated, from
    /// macOS 15 onward; this compiles only because the package pins
    /// `.macOS(.v14)` (`Package.swift:7`). The freeze grab is a second call site,
    /// so both go through here and a future ScreenCaptureKit migration has exactly
    /// one place to change. Treat a deployment-target bump as blocked on that
    /// migration rather than as a routine change.
    private func captureRegionCGImage(_ quartzRect: CGRect,
                                      belowWindowID: CGWindowID) throws -> CGImage {
        debugLog("ScreenCaptureService: captureRegion quartzRect=\(quartzRect) belowWID=\(belowWindowID)")
        guard let cgImage = CGWindowListCreateImage(
            quartzRect,
            .optionOnScreenBelowWindow,
            belowWindowID,
            [.bestResolution]
        ) else {
            throw CaptureError.noDisplay
        }
        return cgImage
    }

    // MARK: - Save

    /// Save the captured image as a PNG in the current screenshot directory.
    /// Returns the stored path (`images/{uuid}.png` or an absolute path).
    private func saveImage(_ image: NSImage) throws -> String {
        guard let pngData = image.pngData()
        else {
            throw CaptureError.imageConversionFailed
        }
        return try writeNewScreenshotData(pngData)
    }

    // MARK: - Clipboard

    /// Copies the final pixels entirely in memory. A failure keeps the capture
    /// and annotation session alive so the user can retry or save a comment.
    func copyCaptureToClipboard() async throws {
        guard pendingQuartzRect != nil else { throw CaptureError.noPendingRegion }
        if let session = annotationSession {
            try await ScreenshotClipboard.copy(session)
        } else {
            try ScreenshotClipboard.write(capturePendingRegionImage())
        }
        finishCapture()
    }

    private func capturePendingRegionImage() throws -> CGImage {
        guard let quartzRect = pendingQuartzRect else { throw CaptureError.noPendingRegion }
        let overlayWID: CGWindowID = (overlayPanel?.windowNumber).map {
            $0 > 0 ? CGWindowID($0) : kCGNullWindowID
        } ?? kCGNullWindowID
        return try captureRegionCGImage(quartzRect, belowWindowID: overlayWID)
    }

    private func finishCapture() {
        pendingQuartzRect = nil
        pendingSourceBundleID = nil
        onCancelCallback = nil
        onRegionSelectedCallback = nil
        dismissOverlay()
    }

    private func copyImageToPasteboard(_ image: NSImage) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([image])
        debugLog("ScreenCaptureService: Copied screenshot to clipboard")
    }

    // MARK: - Errors

    // MARK: - Annotation lifecycle

    /// Whether the Annotate control should be offered.
    var canBeginAnnotation: Bool {
        pendingQuartzRect != nil && pendingSelectionLocal != nil && annotationSession == nil
    }

    /// Freeze the selected pixels and enter annotation.
    ///
    /// The freeze grabs with the same `.optionOnScreenBelowWindow` semantics as the
    /// final capture, while the overlay is at full alpha. Verified on device: the
    /// grab ignores the overlay entirely, so the frozen bitmap is the undimmed
    /// content the user will actually capture.
    @discardableResult
    func beginAnnotation() -> Bool {
        guard annotationSession == nil,
              let quartzRect = pendingQuartzRect,
              let selection = pendingSelectionLocal,
              let regionView = selectionView,
              let screen = overlayScreen,
              let screenFrame = overlayScreenFrame else { return false }

        let overlayWID: CGWindowID = (overlayPanel?.windowNumber).map {
            $0 > 0 ? CGWindowID($0) : kCGNullWindowID
        } ?? kCGNullWindowID

        let frozen: CGImage
        do {
            frozen = try captureRegionCGImage(quartzRect, belowWindowID: overlayWID)
        } catch {
            // Remain in live selection with the typed comment intact.
            debugLog("ScreenCaptureService: Freeze grab failed - \(error)")
            ToastManager.shared.show(L10n.tr("Could not freeze the region. Try again."))
            return false
        }

        let session = AnnotationSession(source: frozen)
        annotationSession = session

        let canvas = AnnotationCanvasNSView(pixelSize: session.pixelSize, session: session)
        canvas.onEscape = { [weak self] in self?.handleCanvasEscape() }
        // Deliberately NOT wired to refreshToolbar: AnnotationToolbarView observes
        // the session directly, so tool, colour, and undo state update themselves.
        // Re-showing the panel here relaid out the whole row on every mouse event -
        // 16 full relayouts in one second, measured during a drag.
        canvas.onStateChange = nil

        // Stage, computed in the same synchronous pass as the mode transition, so
        // there is no stable "before" frame the enlargement contradicts.
        resolveStage(selection: selection, screen: screen)
        let zoom = AnnotationStageGeometry.autoZoom(
            selection: selection.size, maxZoom: stageMaxZoom,
            comfortEdge: AnnotationStageGeometry.comfortEdgeDefault)
        let resolved = displayRect(for: selection, requestedZoom: zoom)
        stageEffectiveZoom = resolved.effectiveZoom
        stageDisplayRectLocal = resolved.rect

        regionView.installAnnotationCanvas(canvas, selection: selection,
                                           displayRect: resolved.rect,
                                           startFrame: selection,
                                           zoom: resolved.effectiveZoom)
        composer.beginAnnotationAnchoring(
            displayRectScreen: resolved.rect.offsetBy(dx: screenFrame.origin.x,
                                                      dy: screenFrame.origin.y))

        animateStage(to: resolved.rect, zoom: resolved.effectiveZoom, duration: 0.18) {
            [weak self] in
            guard let self, let canvas = self.selectionView?.annotationCanvas else { return }
            // The overlay has to become KEY, not just first responder. The comment
            // panel sits a level above at .screenSaver + 1 and holds key status, so
            // making the canvas first responder in a non-key window left every tool
            // shortcut going to the comment text view - measured: pressing T then
            // typing produced the comment "thello" and no text annotation at all.
            //
            // Clicking the comment field hands focus back, which is how a user
            // types their comment; the two surfaces simply take turns.
            self.overlayPanel?.makeKeyAndOrderFront(nil)
            canvas.window?.makeFirstResponder(canvas)
        }

        entryPillController.hide()
        showToolbar()
        debugLog("ScreenCaptureService: Annotation began, \(Int(session.pixelSize.width))x\(Int(session.pixelSize.height)) px, z=\(resolved.effectiveZoom)")
        return true
    }

    /// Allowance box and the achievable zoom ceiling, for the frozen dock edge.
    private func resolveStage(selection: NSRect, screen: NSScreen) {
        let screenFrame = overlayScreenFrame ?? screen.frame
        // Local, 0-based: `panel.contentView = regionView` discards the screen
        // origin passed at construction.
        let visibleLocal = screen.visibleFrame.offsetBy(dx: -screenFrame.origin.x,
                                                        dy: -screenFrame.origin.y)
        let edge = composer.frozenStageEdge

        guard let edge,
              let allowance = AnnotationStageGeometry.allowance(
                visible: visibleLocal, edge: edge,
                panelReserve: composer.annotationPanelReserve,
                toolbarReserveBelow: AnnotationToolbarPanelController.reserve)
        else {
            // Vertical docks and a missing edge both disable magnification.
            stageAllowance = nil
            stageMaxZoom = 1
            return
        }
        stageAllowance = allowance
        stageMaxZoom = AnnotationStageGeometry.resolvedMaxZoom(
            selection: selection, allowance: allowance,
            backingScale: screen.backingScaleFactor)
    }

    private func displayRect(for selection: NSRect,
                             requestedZoom: Int) -> (effectiveZoom: Int, rect: CGRect) {
        guard let allowance = stageAllowance, let screen = overlayScreen else {
            return (1, selection)
        }
        return AnnotationStageGeometry.displayRect(
            selection: selection, requestedZoom: requestedZoom,
            allowance: allowance, backingScale: screen.backingScaleFactor)
    }

    var stageMaximumZoom: Int { stageMaxZoom }

    /// Step or set the zoom. Every consumer reads the ACHIEVED zoom, never the
    /// requested one.
    func setZoom(_ requested: Int) {
        guard annotationSession != nil, !isStageAnimating,
              let selection = pendingSelectionLocal,
              let screenFrame = overlayScreenFrame else { return }
        let clamped = min(max(requested, 1), stageMaxZoom)
        let resolved = displayRect(for: selection, requestedZoom: clamped)
        guard resolved.rect != stageDisplayRectLocal || resolved.effectiveZoom != stageEffectiveZoom
        else { return }

        stageEffectiveZoom = resolved.effectiveZoom
        stageDisplayRectLocal = resolved.rect

        // Manual steps are instant; only entry and exit animate.
        selectionView?.updateAnnotationStage(displayRect: resolved.rect,
                                             zoom: resolved.effectiveZoom)
        composer.setAnnotationDisplayRect(
            resolved.rect.offsetBy(dx: screenFrame.origin.x, dy: screenFrame.origin.y))
        refreshToolbar()
    }

    func stepZoom(_ delta: Int) { setZoom(stageEffectiveZoom + delta) }

    private func animateStage(to rect: CGRect, zoom: Int, duration: TimeInterval,
                              completion: @escaping () -> Void) {
        guard let regionView = selectionView, let canvas = regionView.annotationCanvas else {
            completion(); return
        }
        // Input and editor chrome are disabled for the duration: intermediate
        // frames traverse fractional scales where ChromeMetrics does not hold.
        isStageAnimating = true
        canvas.isInputEnabled = false

        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            canvas.animator().frame = rect
        } completionHandler: { [weak self] in
            guard let self else { return }
            self.isStageAnimating = false
            canvas.isInputEnabled = true
            regionView.updateAnnotationStage(displayRect: rect, zoom: zoom)
            completion()
        }
    }

    // MARK: - Toolbar

    private func showToolbar() {
        guard let session = annotationSession,
              let screen = overlayScreen,
              let local = stageDisplayRectLocal,
              let screenFrame = overlayScreenFrame else { return }

        toolbarController.onCancel = { [weak self] in self?.handleToolbarEscape() }
        toolbarController.onZoomStep = { [weak self] in self?.stepZoom($0) }
        // Done KEEPS the marks. Discard is the only thing that drops them.
        toolbarController.onDone = { [weak self] in self?.finishAnnotating() }
        toolbarController.onRequestDiscard = { [weak self] in
            self?.showsDiscardControls = true
            self?.refreshToolbar()
        }
        toolbarController.onCancelDiscard = { [weak self] in
            self?.showsDiscardControls = false
            self?.refreshToolbar()
        }
        toolbarController.onConfirmDiscard = { [weak self] in
            self?.showsDiscardControls = false
            self?.exitAnnotation(discardingItems: true)
        }

        toolbarController.show(
            session: session,
            anchoredBelow: local.offsetBy(dx: screenFrame.origin.x, dy: screenFrame.origin.y),
            on: screen,
            zoomState: stageMaxZoom > 1
                ? .init(effectiveZoom: stageEffectiveZoom, maxZoom: stageMaxZoom)
                : nil,
            showsDiscardControls: showsDiscardControls)
    }

    /// Ordered out before the fly panel is created, so the two never contend for
    /// `.screenSaver + 2`. The session stays alive: a failed durable write has to
    /// be able to bring the toolbar straight back.
    func orderOutToolbarForCommit() {
        toolbarController.orderOut()
        entryPillController.hide()
    }

    func restoreToolbarAfterFailedCommit() {
        if annotationSession != nil {
            showToolbar()
            return
        }
        // Not annotating: the pill is what has to come back.
        guard let selection = pendingSelectionLocal,
              let screen = overlayScreen,
              let screenFrame = overlayScreenFrame else { return }
        showEntryPill(
            selectionScreenRect: selection.offsetBy(dx: screenFrame.origin.x,
                                                    dy: screenFrame.origin.y),
            screen: screen)
    }

    private func refreshToolbar() {
        guard annotationSession != nil, toolbarController.isVisible else { return }
        showToolbar()
    }

    // MARK: - Dismissal coordination

    /// Resolves exactly ONE layer per invocation and stops.
    func resolveDismissal(intent: DismissalIntent) -> Bool {
        guard let session = annotationSession else { return false }
        let canvas = selectionView?.annotationCanvas

        // 1. An inline text edit consumes the event and returns focus to the canvas.
        if canvas?.hasActiveTextEdit == true {
            _ = canvas?.resolveTextEdit(for: intent)
            return true
        }
        // 2. Toolbar focus returns to the canvas.
        if toolbarController.isVisible, let canvas, canvas.window?.firstResponder !== canvas {
            canvas.window?.makeFirstResponder(canvas)
            canvas.window?.makeKeyAndOrderFront(nil)
            return true
        }
        // 3. A dirty session reveals the discard controls.
        if session.isDirty && !showsDiscardControls {
            showsDiscardControls = true
            refreshToolbar()
            return true
        }
        // 4. Discard controls showing: hide them, stay in annotation.
        if showsDiscardControls {
            showsDiscardControls = false
            refreshToolbar()
            return true
        }
        // Nothing of ours left. A clean session has nothing to lose, so it exits
        // fully; a session with marks only leaves editing mode.
        if session.isDirty { finishAnnotating() } else { exitAnnotation(discardingItems: false) }
        return true
    }

    private func handleCanvasEscape() { _ = resolveDismissal(intent: .escape) }
    private func handleToolbarEscape() { _ = resolveDismissal(intent: .escape) }

    /// Finish editing but KEEP the marks.
    ///
    /// This is the "Done" checkmark. It used to tear the session down, which meant
    /// the following save fell back to a fresh below-overlay grab and shipped a
    /// screenshot with none of the user's annotations on it - the single worst
    /// outcome the feature can produce. The session, the canvas, and the stage all
    /// stay; only the toolbar goes away and focus returns to the comment field so
    /// the user can type and save.
    func finishAnnotating() {
        guard annotationSession != nil else { return }
        showsDiscardControls = false
        toolbarController.orderOut()
        // The Annotate pill comes back as the way to reopen the toolbar.
        if let screen = overlayScreen, let screenFrame = overlayScreenFrame,
           let local = stageDisplayRectLocal {
            entryPillController.onActivate = { [weak self] in self?.reopenToolbar() }
            entryPillController.show(
                selectionRectScreen: local.offsetBy(dx: screenFrame.origin.x,
                                                    dy: screenFrame.origin.y),
                panelEdge: composer.frozenStageEdge,
                on: screen, isEnabled: true)
        }
        composer.focusCommentField()
    }

    private func reopenToolbar() {
        guard annotationSession != nil else { return }
        entryPillController.hide()
        showToolbar()
        if let canvas = selectionView?.annotationCanvas {
            overlayPanel?.makeKeyAndOrderFront(nil)
            canvas.window?.makeFirstResponder(canvas)
        }
    }

    /// Leave annotation entirely, discarding every mark and restoring live region
    /// selection.
    ///
    /// Teardown happens at exactly one point: the completion handler of the exit
    /// animation. The canvas stays installed and the anchor stays set for the
    /// collapse, with input disabled. Nothing is cleared synchronously.
    func exitAnnotation(discardingItems: Bool) {
        guard annotationSession != nil, let selection = pendingSelectionLocal else { return }
        guard !isStageAnimating else { return }
        showsDiscardControls = false
        toolbarController.orderOut()

        animateStage(to: selection, zoom: 1, duration: 0.14) { [weak self] in
            guard let self else { return }
            self.teardownAnnotation()
            composer.endAnnotationAnchoring()
            if let screen = self.overlayScreen, let screenFrame = self.overlayScreenFrame {
                self.showEntryPill(
                    selectionScreenRect: selection.offsetBy(dx: screenFrame.origin.x,
                                                            dy: screenFrame.origin.y),
                    screen: screen)
            }
            if let screenFrame = self.overlayScreenFrame {
                composer.repositionForScreenshot(
                    captureRect: selection.offsetBy(dx: screenFrame.origin.x,
                                                    dy: screenFrame.origin.y),
                    restoreFocus: true)
            }
        }
        _ = discardingItems
    }

    private func teardownAnnotation() {
        toolbarController.teardown()
        selectionView?.removeAnnotationCanvas()
        annotationSession?.teardown()
        annotationSession = nil
        stageAllowance = nil
        stageDisplayRectLocal = nil
        stageEffectiveZoom = 1
        stageMaxZoom = 1
        showsDiscardControls = false
        isStageAnimating = false
    }

    // MARK: - Capture transaction

    /// Produce the final PNG without disturbing the overlay, the draft, or the
    /// session, so a failure here is fully recoverable.
    func prepareCommit() async -> PrepareOutcome {
        guard let quartzRect = pendingQuartzRect else {
            return .failure(CaptureError.noPendingRegion, cleanup: nil)
        }

        let image: CGImage
        /// Set when the marks made during capture can be re-edited later.
        var editable: (base: CGImage, items: [AnnotationItem])?

        if let session = annotationSession {
            do {
                // Commits a pending label or throws; it never silently cancels, and
                // a half-typed label must not be dropped by a save.
                try session.commitActiveEditForOutput()
            } catch {
                return .failure(CaptureError.pendingLabelUnresolved, cleanup: nil)
            }
            do {
                // The SAME split the preview panel's Apply performs, so a mark
                // made while capturing is as editable later as one added
                // afterwards. This used to render a single flat composite, which
                // meant annotating during capture - the most common way to do it -
                // produced an image whose marks were pixels forever, and reopening
                // Annotate on it offered nothing to select.
                let split = try await session.withAppliedSplit {
                    ($0.flattened, $0.base, $0.editableItems)
                }
                image = split.0
                editable = split.2.isEmpty ? nil : (split.1, split.2)
            } catch {
                return .failure(CaptureError.renderFailed("\(error)"), cleanup: nil)
            }
        } else {
            do {
                image = try capturePendingRegionImage()
            } catch {
                report(error, operation: "prepareCommit.capture")
                return .failure(error, cleanup: nil)
            }
        }

        let relativePath: String
        do {
            relativePath = try remarcNewScreenshotStoredPath()
        } catch {
            report(error, operation: "prepareCommit.write")
            return .failure(error, cleanup: nil)
        }
        var leaseRecorded = false
        do {
            // Off the main actor: the registry is guarded by DocumentLock, which
            // polls with Thread.sleep for up to 2s, and this sits on the capture
            // save's critical path.
            try await Task.detached(priority: .userInitiated) {
                // Recorded BEFORE the write, so a crash mid-write still leaves an
                // owned path the startup sweep can reclaim.
                try PreparedCaptureLeaseRegistry.record(path: relativePath)
            }.value
            leaseRecorded = true

            let data = try AnnotationExporter.pngData(from: image)
            let url = resolveImagePath(relativePath)
            try data.write(to: url, options: .atomic)

            // After the PNG, and deliberately not fatal. The capture is complete
            // and correct without this; all it buys is re-editability, so a
            // failure here must not lose the user their screenshot.
            if let editable {
                do {
                    try AnnotationMarkStore.write(base: editable.base, items: editable.items,
                                                  flattenedPNG: data, for: relativePath)
                } catch {
                    debugLog("ScreenCaptureService: marks not stored, capture kept - \(error)")
                }
            }
        } catch {
            report(error, operation: "prepareCommit.write")
            return .failure(error, cleanup: PreparedPartial(
                relativePath: leaseRecorded ? relativePath : nil, leaseRecorded: leaseRecorded))
        }

        let token = UUID()
        activeToken = token
        return .success(PreparedCapture(
            token: token, relativePath: relativePath, cgImage: image,
            pointSize: CGSize(width: quartzRect.width, height: quartzRect.height)))
    }

    /// The comment is durably on disk. Release everything.
    ///
    /// A failed lease removal here does NOT trigger restore: the comment is written
    /// and the file is referenced, so a stale lease entry is harmless and the next
    /// startup sweep finds the file referenced and drops the entry.
    @discardableResult
    func finalize(token: UUID, prepared: PreparedCapture) -> ConcludeResult {
        guard activeToken == token else {
            debugLog("ScreenCaptureService: finalize with a stale token")
            return .staleToken
        }
        activeToken = nil

        if SettingsManager.shared.copyScreenshotToClipboard {
            copyImageToPasteboard(NSImage(cgImage: prepared.cgImage,
                                          size: prepared.pointSize))
        }

        try? PreparedCaptureLeaseRegistry.release(path: prepared.relativePath)
        finishCapture()
        return .finalized
    }

    /// The durable write failed. Undo the prepared resource and leave every editor
    /// usable.
    ///
    /// Ordering matters: the PNG is deleted BEFORE the lease is removed, and the
    /// lease is retained if the deletion fails, so a file that could not be removed
    /// stays owned and reclaimable rather than becoming an untracked orphan.
    @discardableResult
    func restore(token: UUID?, partial: PreparedPartial?) -> ConcludeResult {
        if let token, activeToken != token {
            debugLog("ScreenCaptureService: restore with a stale token")
            return .staleToken
        }
        activeToken = nil

        guard let partial, let path = partial.relativePath else { return .restored }

        // The whole family. The commit may have written a base and marks after
        // the PNG, and rolling back only the PNG would strand them - for a
        // capture annotated with vectors only, that base is a copy of the
        // screenshot the user just decided not to keep.
        var deleted = true
        do { try AnnotationMarkStore.deleteImageFamily(path) }
        catch {
            deleted = false
            debugLog("ScreenCaptureService: could not delete prepared capture - \(error)")
        }
        if deleted && partial.leaseRecorded {
            try? PreparedCaptureLeaseRegistry.release(path: path)
        }
        return .restored
    }

    func restore(token: UUID, prepared: PreparedCapture) -> ConcludeResult {
        restore(token: token, partial: PreparedPartial(relativePath: prepared.relativePath,
                                                       leaseRecorded: true))
    }

    private func report(_ error: Error, operation: String) {
        debugLog("ScreenCaptureService: \(operation) failed - \(error)")
    }

    enum CaptureError: LocalizedError {
        case noDisplay
        case imageConversionFailed
        case noPendingRegion
        case pendingLabelUnresolved
        case renderFailed(String)

        var errorDescription: String? {
            switch self {
            case .noDisplay: return L10n.tr("No display found for screen capture")
            case .imageConversionFailed: return L10n.tr("Failed to convert captured image to PNG")
            case .noPendingRegion: return L10n.tr("No region is selected")
            case .pendingLabelUnresolved: return L10n.tr("Finish the text label first")
            case .renderFailed(let detail): return L10n.tr("Could not render annotations - \(detail)")
            }
        }
    }
}
