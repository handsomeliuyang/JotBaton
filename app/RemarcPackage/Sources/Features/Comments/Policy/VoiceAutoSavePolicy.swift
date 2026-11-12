import Foundation

package enum VoiceAutoSavePolicy {
    package static func shouldStartCountdown(
        isVoiceInvoked: Bool,
        autoSaveEnabled: Bool,
        text: String,
        allowsAutoSave: Bool = true
    ) -> Bool {
        isVoiceInvoked
            && autoSaveEnabled
            && allowsAutoSave
            && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
