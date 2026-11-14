import CoreLocalization
import CorePlatform
import CoreTheme
import CoreUI
import FeatureCloudSync
import FeatureComments
import FeatureIntegrations
import FeatureOnboarding
import FeatureSettings
import FeatureUpdates
import AppKit
import SwiftUI
import ServiceManagement
import Combine
@MainActor
public final class AppController: NSObject, ObservableObject {
    public static let shared = AppController()

    private(set) var statusItem: NSStatusItem?

    /// Exposed for save animation targeting
    public var statusItemButton: NSStatusBarButton? { statusItem?.button }
    private var cancellables = Set<AnyCancellable>()
    private let accessibilityPermissionMonitor = AccessibilityPermissionMonitor()

    @Published public private(set) var isOnboardingComplete: Bool = false

    public override init() {
        super.init()
    }

    public func setup() {
        prepareDebugLogFile()
        debugLog("AppController setup started")
        let activationPolicy = ActivationPolicyManager.shared
        activationPolicy.showInDock = SettingsManager.shared.showInDock
        SettingsManager.shared.$showInDock
            .receive(on: DispatchQueue.main)
            .sink { activationPolicy.showInDock = $0 }
            .store(in: &cancellables)
        setupMenuBar()
        debugLog("Menu bar setup complete")

        UpdateManager.shared.configure(prepareForRestart: AppUpdatePreparation.prepareForRestart)
        _ = AppServices.shared.cloudSync // Sync from launch, before the panel opens.
        debugLog("UpdateManager initialized")

        // Check if onboarding is needed
        if SettingsManager.shared.hasCompletedOnboarding {
            completeSetup(withHotkey: OnboardingWindowController.shared.checkAccessibilityPermission())
        } else {
            OnboardingWindowController.shared.onComplete = { [weak self] hasPermission in
                SettingsManager.shared.hasCompletedOnboarding = true
                self?.completeSetup(withHotkey: hasPermission)
            }
            OnboardingWindowController.shared.show()
        }
    }

    private func completeSetup(withHotkey: Bool) {
        debugLog("Completing app setup (withHotkey: \(withHotkey))")

        // Start event-driven selection monitoring
        SelectionMonitor.shared.startMonitoring()
        debugLog("SelectionMonitor started (event-driven)")

        // Start WebSocket server only if the extension has connected before (lazy start)
        if SettingsManager.shared.hasExtensionEverConnected {
            WebSocketService.shared.start()
            debugLog("WebSocketService started (extension previously connected)")
        } else {
            debugLog("WebSocketService deferred (extension never connected)")
        }

        // Initialize tooltip observer (subscribes to SelectionMonitor changes)
        _ = SelectionTooltipWindowController.shared
        debugLog("SelectionTooltipWindowController initialized")

        GlobalHotkey.shared.register()
        debugLog("GlobalHotkey registered")

        RemarcURLHandler.shared.markReady()
        debugLog("RemarcURLHandler ready")

        enableLoginItem()
        setupObservers()
        accessibilityPermissionMonitor.start { [weak self] granted in
            self?.handleAccessibilityPermissionChange(granted)
        }
        if !withHotkey {
            // Updates and local re-signing can invalidate TCC even after onboarding.
            // Register this binary with macOS instead of silently failing every read.
            debugLog("Accessibility: access missing; requesting permission for this installation")
            OnboardingWindowController.shared.requestAccessibility()
        }
        isOnboardingComplete = true
        debugLog("AppController setup complete")
    }

    private func handleAccessibilityPermissionChange(_ granted: Bool) {
        debugLog("Accessibility: permission changed (granted: \(granted)); reconnecting listeners")
        SelectionTooltipWindowController.shared.dismiss()
        SelectionMonitor.shared.stopMonitoring()
        if !SettingsManager.shared.isPaused {
            SelectionMonitor.shared.startMonitoring()
        }
    }

    private func setupObservers() {
        SettingsManager.shared.$isPaused
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshMenuBarIcon(animated: false, force: true) }
            .store(in: &cancellables)

        // Resolving a retained comment must remove it from the indicator even
        // though the total number of stored comments does not change.
        AppServices.shared.comments.$appState
            .map { CommentCountPolicy.unresolvedCount(in: $0.comments) }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshMenuBarIcon() }
            .store(in: &cancellables)

        // `receive(on:)` always defers, so the willSet-driven emission lands
        // after the property has its new value. Not animated: changing the
        // style is the user looking at Settings, not a task arriving.
        SettingsManager.shared.$menuBarIndicatorStyle
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshMenuBarIcon(animated: false) }
            .store(in: &cancellables)

        AppServices.shared.cloudSync.objectWillChange
            .debounce(for: .milliseconds(200), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshMenuBarIcon() }
            .store(in: &cancellables)
    }

    // MARK: - Menu Bar Icon

    private lazy var menuBarGlyph: NSImage? = NSImage(named: AppIdentity.current.menuBarIconName)
    private var paintedIconState: MenuBarIconState?
    private var indicatorLandingPending = false
    private var popTimer: DispatchSourceTimer?
    private var appearanceObservation: NSKeyValueObservation?

    private var currentIconState: MenuBarIconState {
        MenuBarIconState(style: SettingsManager.shared.menuBarIndicatorStyle,
                         unresolvedCount: AppServices.shared.comments.unresolvedCommentCount,
                         needsSyncAttention: AppServices.shared.cloudSync.health.needsAttention)
    }

    /// Repaints the icon from live state. A newly arrived task or sync problem
    /// pops its badge once, unless the user asked for reduced motion.
    private func refreshMenuBarIcon(animated: Bool = true, force: Bool = false) {
        guard let button = statusItem?.button, let glyph = menuBarGlyph, !indicatorLandingPending else { return }
        button.appearsDisabled = SettingsManager.shared.isPaused
        let state = currentIconState
        button.toolTip = menuBarToolTip(for: state)
        let previous = paintedIconState
        guard force || state != previous else { return }
        paintedIconState = state
        popTimer?.cancel()
        popTimer = nil
        let announces = previous.map { state.announcesChange(since: $0) } ?? false
        guard animated, announces, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            button.image = MenuBarIconRenderer.image(glyph: glyph, state: state)
            return
        }
        let frames = MenuBarIconRenderer.popScales.map { MenuBarIconRenderer.image(glyph: glyph, state: state, badgeScale: $0) }
        var index = 0
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .milliseconds(40))
        timer.setEventHandler { [weak self, weak button] in
            guard index < frames.count else {
                self?.popTimer?.cancel()
                self?.popTimer = nil
                return
            }
            button?.image = frames[index]
            index += 1
        }
        popTimer = timer
        timer.resume()
    }

    private func menuBarToolTip(for state: MenuBarIconState) -> String {
        var parts = [AppIdentity.current.displayName]
        if state.unresolvedCount > 0 { parts.append(L10n.tr("\(state.unresolvedCount) unresolved tasks")) }
        if state.needsSyncAttention { parts.append(AppServices.shared.cloudSync.health.title) }
        return parts.joined(separator: " · ")
    }

    /// The composer's envelope flies into the menu bar. Hold the icon until it
    /// lands so the new task appears on impact rather than before.
    public func prepareIndicatorLanding() {
        indicatorLandingPending = true
    }

    /// The save failed: show the real state without a pop.
    public func cancelIndicatorLanding() {
        indicatorLandingPending = false
        refreshMenuBarIcon(animated: false)
    }

    public func landIndicator() {
        indicatorLandingPending = false
        refreshMenuBarIcon()
    }

    // MARK: - Menu Bar Setup

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem?.button {
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            // The sync warning is drawn in color, not as a template, so it must
            // be redrawn when the menu bar switches between light and dark.
            appearanceObservation = button.observe(\.effectiveAppearance) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.refreshMenuBarIcon(animated: false, force: true) }
            }
        }
        refreshMenuBarIcon(animated: false, force: true)

        // Store reference so popover can position below the button
        MenuBarPopoverController.shared.statusItemButton = statusItem?.button
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }

        // If onboarding is pending and window was hidden, bring it back
        if !SettingsManager.shared.hasCompletedOnboarding {
            OnboardingWindowController.shared.bringBack()
            return
        }

        if event.type == .rightMouseUp {
            showRightClickMenu()
        } else {
            MenuBarPopoverController.shared.toggle()
        }
    }

    // MARK: - Right-Click Utility Menu

    private func showRightClickMenu() {
        let menu = NSMenu()

        let copyAllItem = NSMenuItem(title: L10n.tr("Copy All"), action: #selector(copyAllAsMarkdown), keyEquivalent: "")
        copyAllItem.target = self
        copyAllItem.isEnabled = !AppServices.shared.comments.activeComments.isEmpty
        menu.addItem(copyAllItem)

        let quickNoteItem = NSMenuItem(title: L10n.tr("New Quick Note"), action: #selector(newQuickNote), keyEquivalent: "")
        quickNoteItem.target = self
        menu.addItem(quickNoteItem)

        menu.addItem(NSMenuItem.separator())

        let detachItem = NSMenuItem(
            title: MenuBarPopoverController.shared.isDetached ? L10n.tr("Re-attach Window") : L10n.tr("Detach Window"),
            action: MenuBarPopoverController.shared.isDetached ? #selector(reattachWindow) : #selector(detachWindow),
            keyEquivalent: ""
        )
        detachItem.target = self
        menu.addItem(detachItem)

        menu.addItem(NSMenuItem.separator())

        let pauseItem = NSMenuItem(
            title: SettingsManager.shared.isPaused ? L10n.tr("Resume") : L10n.tr("Pause"),
            action: #selector(togglePause),
            keyEquivalent: ""
        )
        pauseItem.target = self
        menu.addItem(pauseItem)

        let prefsItem = NSMenuItem(title: L10n.tr("Preferences..."), action: #selector(showPreferences), keyEquivalent: "")
        prefsItem.target = self
        menu.addItem(prefsItem)

        menu.addItem(NSMenuItem.separator())

        if UpdateManager.shared.canCheckForUpdates {
            let updateItem = NSMenuItem(title: L10n.tr("Check for Updates\u{2026}"), action: #selector(checkForUpdates), keyEquivalent: "")
            updateItem.target = self
            updateItem.isEnabled = !UpdateManager.shared.isChecking
            menu.addItem(updateItem)
            menu.addItem(NSMenuItem.separator())
        }

        let quitItem = NSMenuItem(title: L10n.tr("Quit"), action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        // Use the status-item menu trick for right-click: set, click, clear
        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        statusItem?.menu = nil
    }

    // MARK: - Actions

    @objc private func openViewer() {
        MenuBarPopoverController.shared.show()
    }

    @objc private func newQuickNote() {
        CommentInputController.shared.showStandaloneNote()
    }

    @objc private func togglePause() {
        SettingsManager.shared.isPaused.toggle()
        if SettingsManager.shared.isPaused {
            SelectionMonitor.shared.stopMonitoring()
            SelectionTooltipWindowController.shared.dismiss()
        } else {
            SelectionMonitor.shared.startMonitoring()
        }
    }

    @objc private func showPreferences() {
        PreferencesWindowController.shared.show()
    }

    @objc private func detachWindow() {
        MenuBarPopoverController.shared.dismiss()
        DetachedWindowController.shared.show()
    }

    @objc private func reattachWindow() {
        DetachedWindowController.shared.dismiss()
    }

    // MARK: - Export Actions

    @objc private func copyAllAsMarkdown() {
        guard let session = AppServices.shared.comments.activeSession else { return }
        let comments = AppServices.shared.comments.activeComments
        ExportManager.shared.copySessionToClipboard(session, comments: comments, format: .markdown)
    }

    @objc private func copyAllAsJSON() {
        guard let session = AppServices.shared.comments.activeSession else { return }
        let comments = AppServices.shared.comments.activeComments
        ExportManager.shared.copySessionToClipboard(session, comments: comments, format: .json)
    }

    @objc private func saveAllToFile() {
        guard let session = AppServices.shared.comments.activeSession else { return }
        let comments = AppServices.shared.comments.activeComments
        ExportManager.shared.saveSessionToFile(session, comments: comments, format: SettingsManager.shared.outputFormat)
    }

    @objc private func checkForUpdates() {
        UpdateManager.shared.checkForUpdates()
    }

    // MARK: - App Info

    @objc private func showAbout() {
        let credits = NSMutableAttributedString()

        let footerFont = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)

        let contactLink = NSAttributedString(
            string: "Contact",
            attributes: [
                .link: URL(string: "mailto:mete@metedata.com")!,
                .font: footerFont
            ]
        )
        credits.append(contactLink)

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center
        credits.addAttribute(
            .paragraphStyle,
            value: paragraphStyle,
            range: NSRange(location: 0, length: credits.length)
        )

        let options: [NSApplication.AboutPanelOptionKey: Any] = [
            .applicationIcon: NSApp.applicationIconImage as Any,
            .credits: credits
        ]
        NSApp.orderFrontStandardAboutPanel(options: options)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func quitApp() {
        AppServices.shared.comments.saveImmediately()
        NSApp.terminate(nil)
    }

    private func enableLoginItem() {
        if #available(macOS 13.0, *) {
            do {
                try SMAppService.mainApp.register()
            } catch {
                print("Failed to register login item: \(error)")
            }
        }
    }

    // MARK: - Dock Icon Click Handler

    public func handleDockIconClick() {
        if !SettingsManager.shared.hasCompletedOnboarding {
            OnboardingWindowController.shared.bringBack()
            return
        }

        // Bring back settings if it's open or minimized, otherwise toggle the popover
        if PreferencesWindowController.shared.isVisible || PreferencesWindowController.shared.isMiniaturized {
            PreferencesWindowController.shared.bringBack()
        } else {
            MenuBarPopoverController.shared.toggle()
        }
    }
}
