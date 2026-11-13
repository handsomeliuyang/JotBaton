import CoreLocalization
import CorePlatform
import CoreUI
import FeatureComments
import FeatureSettings
import AppKit
import KeyboardShortcuts

@MainActor
public final class GlobalHotkey {
    public static let shared = GlobalHotkey()

    private init() {}

    /// Register the configurable global hotkey for comment-on-selection
    public func register() {
        KeyboardShortcuts.onKeyDown(for: .commentOnSelection) { [weak self] in
            Task { @MainActor in
                self?.handleHotkey()
            }
        }
        KeyboardShortcuts.onKeyDown(for: .quickNote) { [weak self] in
            Task { @MainActor in
                self?.handleQuickNoteHotkey()
            }
        }
        KeyboardShortcuts.onKeyDown(for: .screenshotComment) { [weak self] in
            Task { @MainActor in
                self?.handleScreenshotHotkey()
            }
        }
        KeyboardShortcuts.onKeyDown(for: .screenshotCommentWake) { [weak self] in
            Task { @MainActor in
                self?.handleScreenshotHotkey(wakeOnSave: true)
            }
        }
        KeyboardShortcuts.onKeyDown(for: .pasteAllComments) { [weak self] in
            Task { @MainActor in
                self?.handlePasteAllHotkey()
            }
        }
        KeyboardShortcuts.onKeyDown(for: .openRemarc) { [weak self] in
            Task { @MainActor in
                self?.handleOpenRemarc()
            }
        }
        debugLog("GlobalHotkey: Registered (KeyboardShortcuts)")
    }

    public func unregister() {
        KeyboardShortcuts.disable(.commentOnSelection)
        KeyboardShortcuts.disable(.quickNote)
        KeyboardShortcuts.disable(.screenshotComment)
        KeyboardShortcuts.disable(.screenshotCommentWake)
        KeyboardShortcuts.disable(.pasteAllComments)
        KeyboardShortcuts.disable(.openRemarc)
        debugLog("GlobalHotkey: Unregistered")
    }

    private func handleOpenRemarc() {
        debugLog("GlobalHotkey: handleOpenRemarc fired")
        let popover = MenuBarPopoverController.shared
        if popover.isDetached {
            DetachedWindowController.shared.bringToFront()
        } else if !popover.isVisible {
            popover.show()
        }
    }

    private func handleHotkey() {
        debugLog("GlobalHotkey: handleHotkey fired")
        guard !SettingsManager.shared.isPaused else {
            debugLog("GlobalHotkey: paused, ignoring")
            return
        }

        let frontApp = NSWorkspace.shared.frontmostApplication
        debugLog("GlobalHotkey: frontmost app = \(frontApp?.bundleIdentifier ?? "nil") (pid \(frontApp?.processIdentifier ?? -1))")

        if let selection = SelectionMonitor.shared.readCurrentSelection() {
            debugLog("GlobalHotkey: got selection: \"\(selection.text.prefix(40))\"")
            CommentInputController.shared.showForSelection(selection)
        } else {
            debugLog("GlobalHotkey: readCurrentSelection returned nil — opening quick note")
            CommentInputController.shared.showStandaloneNote()
        }
    }

    private func handleQuickNoteHotkey() {
        guard !SettingsManager.shared.isPaused else { return }
        SelectionTooltipWindowController.shared.dismiss()
        FloatingEditorController.shared.showForQuickNote()
    }

    private func handleScreenshotHotkey(wakeOnSave: Bool = false) {
        debugLog("GlobalHotkey: handleScreenshotHotkey fired (wakeOnSave=\(wakeOnSave))")
        guard !SettingsManager.shared.isPaused else {
            debugLog("GlobalHotkey: paused, ignoring screenshot hotkey")
            return
        }
        // Only pre-arm when a wake could actually be honoured; otherwise this
        // behaves as an ordinary screenshot comment. The shortcut files to the
        // active session, so that is the pairing that has to be live - the
        // composer opens on the same session and its button agrees.
        let armWake = wakeOnSave
            && SettingsManager.shared.wakeAvailable(
                for: AppServices.shared.comments.appState.activeSessionID
            )

        AppServices.shared.capture.startCapture(
            onRegionSelected: { captureRect, sourceBundleID in
                Task { @MainActor in
                    CommentInputController.shared.showForScreenshot(
                        captureRect: captureRect,
                        sourceBundleID: sourceBundleID,
                        wakeOnSave: armWake
                    )
                }
            },
            onCancel: {
                Task { @MainActor in
                    debugLog("GlobalHotkey: screenshot capture cancelled")
                }
            }
        )
    }

    private func handlePasteAllHotkey() {
        debugLog("GlobalHotkey: handlePasteAllHotkey fired")
        guard !SettingsManager.shared.isPaused else {
            debugLog("GlobalHotkey: paused, ignoring paste-all hotkey")
            return
        }

        guard let session = AppServices.shared.comments.activeSession else {
            debugLog("GlobalHotkey: no active session, ignoring paste-all")
            return
        }

        let comments = AppServices.shared.comments.activeComments
        guard !comments.isEmpty else {
            debugLog("GlobalHotkey: no comments to paste")
            return
        }

        let format = SettingsManager.shared.outputFormat
        guard let receipt = ExportManager.shared.copySessionToClipboard(
            session,
            comments: comments,
            format: format
        ) else {
            debugLog("GlobalHotkey: clipboard write failed, skipping paste-all")
            ToastManager.shared.show(L10n.tr("Couldn’t copy comments"))
            return
        }
        debugLog("GlobalHotkey: copied \(receipt.count) comments, simulating Cmd+V")

        // Brief delay for clipboard to settle, then simulate Cmd+V
        simulatePaste()

        ToastManager.shared.show(L10n.tr("Pasted \(receipt.count) comment\(receipt.count == 1 ? "" : "s")"))

        if SettingsManager.shared.clearAfterExportBehavior == .delete {
            // Use a delay to allow the paste to complete before clearing
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                switch AppServices.shared.comments.clearExportedComments(receipt) {
                case .success(let clearedIDs):
                    debugLog("GlobalHotkey: auto-cleared \(clearedIDs.count) unchanged exported comments after paste-all")
                case .failure(let error):
                    debugLog("GlobalHotkey: auto-clear after paste-all failed - \(error)")
                    ToastManager.shared.show(L10n.tr("Couldn’t clear exported comments"))
                }
            }
        }
    }

    /// Simulate Cmd+V keystroke after a brief delay for the clipboard to settle.
    private func simulatePaste(ifCurrent: @escaping @MainActor () -> Bool = { true }) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            guard ifCurrent() else {
                debugLog("GlobalHotkey: clipboard changed before paste, skipping")
                return
            }
            let source = CGEventSource(stateID: .combinedSessionState)
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true)
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
            keyDown?.flags = .maskCommand
            keyUp?.flags = .maskCommand
            keyDown?.post(tap: .cghidEventTap)
            keyUp?.post(tap: .cghidEventTap)
            debugLog("GlobalHotkey: Cmd+V simulated")
        }
    }

}
