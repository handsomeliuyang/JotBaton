import CorePlatform
import KeyboardShortcuts

package extension KeyboardShortcuts.Name {
    static let commentOnSelection = Self(
        "commentOnSelection",
        initial: .init(.c, modifiers: AppIdentity.current.isDevelopment ? [.control, .option, .shift] : [.control, .option])
    )
    static let quickNote = Self(
        "quickNote",
        initial: .init(.n, modifiers: AppIdentity.current.isDevelopment ? [.control, .option, .shift] : [.control, .option])
    )
    static let screenshotComment = Self(
        "screenshotComment",
        initial: .init(.s, modifiers: AppIdentity.current.isDevelopment ? [.control, .option, .shift] : [.control, .option])
    )
    static let pasteAllComments = Self(
        "pasteAllComments",
        initial: .init(.p, modifiers: AppIdentity.current.isDevelopment ? [.control, .option, .shift] : [.control, .option])
    )
    static let openRemarc = Self(
        "openRemarc",
        initial: .init(.r, modifiers: AppIdentity.current.isDevelopment ? [.control, .option, .shift] : [.control, .option])
    )
}
