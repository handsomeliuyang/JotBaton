import CoreLocalization
import Foundation

public enum CommentType: Codable, Equatable, Sendable {
    case comment(text: String)
    case quickNote
    case screenshot(imagePath: String)
    /// Legacy on-disk type, retained for existing comments and integrations.
    case critMode
    case webElement(componentName: String?, filePath: String?)

    public var displayText: String? {
        switch self {
        case .comment(let text): return text
        case .quickNote: return nil
        case .screenshot: return nil
        case .critMode: return nil
        case .webElement(let name, _): return name
        }
    }

    public var isQuickNote: Bool {
        if case .quickNote = self { return true }
        return false
    }

    public var isScreenshot: Bool {
        if case .screenshot = self { return true }
        return false
    }

    public var isWebElement: Bool {
        if case .webElement = self { return true }
        return false
    }

    public var imagePath: String? {
        if case .screenshot(let path) = self { return path }
        return nil
    }

    // MARK: - Metadata

    public var identifier: String {
        // Keep the stored/exported identifier while grouping retired comments with notes.
        if case .critMode = self { return "critMode" }
        return kind.rawValue
    }

    public var exportDisplayName: String {
        switch self {
        case .critMode: return "Crit Mode"
        default: return kind.exportDisplayName
        }
    }

    public var displayName: String { L10n.lookup(exportDisplayName) }

    public var iconName: String {
        // Aligns with `Kind.iconName` — `.webElement` → "globe" everywhere.
        // (Previously overridden to "chevron.left.forwardslash.chevron.right",
        //  which collided visually with the WebContextBadge's `</>` icon.)
        kind.iconName
    }
}

// MARK: - Kind (Hashable filter key)

package extension CommentType {
    /// A simple, Hashable enum for filtering — strips associated values from CommentType.
    public enum Kind: String, Hashable, CaseIterable, Sendable {
        case comment, screenshot, quickNote, webElement
    }

    public var kind: Kind {
        switch self {
        case .comment: return .comment
        case .screenshot: return .screenshot
        case .quickNote: return .quickNote
        case .critMode: return .quickNote
        case .webElement: return .webElement
        }
    }
}

package extension CommentType.Kind {
    public var exportDisplayName: String {
        switch self {
        case .comment: return "Comment"
        case .screenshot: return "Screenshot"
        case .quickNote: return "Quick Note"
        case .webElement: return "Web Element"
        }
    }

    public var displayName: String { L10n.lookup(exportDisplayName) }

    public var iconName: String {
        switch self {
        case .comment: return "text.quote"
        case .screenshot: return "camera.viewfinder"
        case .quickNote: return "note.text"
        case .webElement: return "globe"
        }
    }
}
