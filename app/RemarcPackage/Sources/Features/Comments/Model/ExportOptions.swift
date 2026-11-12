import CoreLocalization
import Foundation

public enum ClearAfterExportBehavior: String, CaseIterable, Sendable {
    case ask, keep, delete

    public var label: String {
        switch self {
        case .ask: L10n.tr("Always Ask")
        case .keep: L10n.tr("Always Keep")
        case .delete: L10n.tr("Always Delete")
        }
    }
}


public enum OutputFormat: String, CaseIterable, Sendable {
    case markdown
    case json

    public var label: String {
        switch self {
        case .markdown: return L10n.tr("Markdown")
        case .json: return L10n.tr("JSON")
        }
    }

    public var fileExtension: String {
        switch self {
        case .markdown: return "md"
        case .json: return "json"
        }
    }
}


public enum ReferenceStyle: String, CaseIterable, Sendable {
    case plain
    case blockquote
    case rePrefix
    case quoted

    public var label: String {
        switch self {
        case .plain: return L10n.tr("Plain text")
        case .blockquote: return L10n.tr("> Blockquote")
        case .rePrefix: return L10n.tr("Re: Prefix")
        case .quoted: return L10n.tr("\"Quoted\"")
        }
    }
}


public enum NumberingStyle: String, CaseIterable, Sendable {
    case numbered
    case bulleted
    case none

    public var label: String {
        switch self {
        case .numbered: return L10n.tr("Numbered")
        case .bulleted: return L10n.tr("Bulleted")
        case .none: return L10n.tr("None")
        }
    }
}


public enum DividerStyle: String, CaseIterable, Sendable {
    case horizontalRule
    case doubleLine
    case dotted
    case blankLine

    public var label: String {
        switch self {
        case .horizontalRule: return L10n.tr("--- Rule")
        case .doubleLine: return L10n.tr("=== Double")
        case .dotted: return L10n.tr("\u{00B7}\u{00B7}\u{00B7} Dotted")
        case .blankLine: return L10n.tr("Blank Line")
        }
    }
}


public enum ExportDateFormat: String, CaseIterable, Sendable {
    case short
    case medium
    case long
    case iso
    case european

    public var label: String {
        let formatter = DateFormatter()
        formatter.locale = L10n.locale
        switch self {
        case .short: formatter.dateFormat = "MMM d"
        case .medium: formatter.dateFormat = "MMM d, yyyy"
        case .long: formatter.dateFormat = "MMMM d, yyyy"
        case .iso: formatter.dateFormat = "yyyy-MM-dd"
        case .european: formatter.dateFormat = "dd/MM/yyyy"
        }
        return formatter.string(from: Date())
    }
}


public enum TimeFormat: String, CaseIterable, Sendable {
    case twelve
    case twentyFour

    public var label: String {
        switch self {
        case .twelve: return L10n.tr("12-hour")
        case .twentyFour: return L10n.tr("24-hour")
        }
    }

    public var use24Hour: Bool { self == .twentyFour }
}


public enum CommentPrefixStyle: String, CaseIterable, Sendable {
    case comment
    case note
    case dash
    case arrow
    case none

    public var label: String {
        switch self {
        case .comment: return L10n.tr("Comment:")
        case .note: return L10n.tr("Note:")
        case .dash: return L10n.tr("\u{2014} Dash")
        case .arrow: return L10n.tr("\u{2192} Arrow")
        case .none: return L10n.tr("None")
        }
    }
}


public enum MetadataDividerStyle: String, CaseIterable, Sendable {
    case pipe
    case dash
    case bullet
    case comma

    public var label: String {
        switch self {
        case .pipe: return L10n.tr("| Pipe")
        case .dash: return L10n.tr("\u{2014} Dash")
        case .bullet: return L10n.tr("\u{00B7} Dot")
        case .comma: return L10n.tr(", Comma")
        }
    }

    public var separator: String {
        switch self {
        case .pipe: return " | "
        case .dash: return " \u{2014} "
        case .bullet: return " \u{00B7} "
        case .comma: return ", "
        }
    }
}
