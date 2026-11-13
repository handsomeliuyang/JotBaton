import AppKit
import CoreLocalization

/// All app-owned workflows must be safe before Sparkle may send a quit event.
@MainActor
enum AppUpdatePreparation {
    static func prepareForRestart() -> String? {
        if #available(macOS 26, *) {
            if DictationService.shared.state != .idle || VoiceInputService.shared.state != .idle || CritModeService.shared.state != .idle {
                return L10n.tr("Finish recording or transcription, then click Upgrade and Restart again.")
            }
        }
        if FloatingEditorController.shared.isVisible || FloatingEditorController.shared.hasUnsavedChanges
            || CommentInputController.shared.isVisible
            || !CommentInputController.shared.currentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !CommentInputController.shared.currentAttachments.isEmpty
            || AppServices.shared.capture.hasActiveCapture
            || ScreenshotPreviewController.shared.isVisible {
            return L10n.tr("Save or close the comment editor and screenshot preview, then click Upgrade and Restart again.")
        }
        guard AppServices.shared.comments.prepareForUpdate() else {
            return L10n.tr("Could not save current changes. Finish the current operation and try upgrading again.")
        }
        return nil
    }
}
