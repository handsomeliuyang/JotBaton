import CorePlatform
import KeyboardShortcuts

package extension KeyboardShortcuts.Name {
    static let commentOnSelection = Self(
        "commentOnSelection",
        initial: .init(.c, modifiers: AppIdentity.current.isDevelopment ? [.control, .option, .shift] : [.control, .option])
    )
    static let screenshotComment = Self(
        "screenshotComment",
        initial: .init(.s, modifiers: AppIdentity.current.isDevelopment ? [.control, .option, .shift] : [.control, .option])
    )
    /// Screenshot capture whose save wakes a running session. No default
    /// binding: waking is opt-in, so this stays unassigned until asked for.
    static let screenshotCommentWake = Self("screenshotCommentWake")
    static let pasteAllComments = Self(
        "pasteAllComments",
        initial: .init(.p, modifiers: AppIdentity.current.isDevelopment ? [.control, .option, .shift] : [.control, .option])
    )
    static let voiceInput = Self(
        "voiceInput",
        initial: .init(.v, modifiers: AppIdentity.current.isDevelopment ? [.control, .option, .shift] : [.control, .option])
    )
    static let dictation = Self(
        "dictation",
        initial: .init(.d, modifiers: AppIdentity.current.isDevelopment ? [.control, .option, .shift] : [.control, .option])
    )
    static let dictationHandsFree = Self(
        "dictationHandsFree",
        initial: .init(.h, modifiers: AppIdentity.current.isDevelopment ? [.control, .option, .shift] : [.control, .option])
    )
    static let pasteLastTranscription = Self(
        "pasteLastTranscription",
        initial: .init(.l, modifiers: AppIdentity.current.isDevelopment ? [.control, .option, .shift] : [.control, .option])
    )
    static let openRemarc = Self(
        "openRemarc",
        initial: .init(.r, modifiers: AppIdentity.current.isDevelopment ? [.control, .option, .shift] : [.control, .option])
    )
    static let startCritMode = Self(
        "startCritMode",
        initial: .init(.m, modifiers: AppIdentity.current.isDevelopment ? [.control, .option, .shift] : [.control, .option])
    )
}
