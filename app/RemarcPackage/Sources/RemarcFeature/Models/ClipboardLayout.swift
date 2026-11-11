import Foundation

/// User-editable Markdown composition, stored in the current app channel's defaults.
public struct ClipboardLayout: Codable, Equatable, Sendable {
    public enum Field: String, Codable, CaseIterable, Sendable {
        case reference, comment, attachments, metadata

        public var label: String {
            switch self {
            case .reference: return L10n.tr("Reference / Screenshot")
            case .comment: return L10n.tr("Comment")
            case .attachments: return L10n.tr("Attachments")
            case .metadata: return L10n.tr("Metadata")
            }
        }
    }

    public enum FieldSpacing: String, Codable, CaseIterable, Sendable {
        case newLine, blankLine

        public var label: String {
            switch self {
            case .newLine: return L10n.tr("New line")
            case .blankLine: return L10n.tr("Blank Line")
            }
        }
    }

    public var referencePrefix = "Reference:"
    public var screenshotPrefix = "Screenshot:"
    public var attachmentPrefix = "Attachment:"
    public var commentPrefix = "Comment:"
    public var fieldOrder: [Field] = Field.allCases
    public var fieldSpacing: FieldSpacing = .newLine

    public init() {}

    /// Repair partial or duplicate orders so no content can be silently omitted.
    public var orderedFields: [Field] {
        var result: [Field] = []
        for field in fieldOrder + Field.allCases where !result.contains(field) {
            result.append(field)
        }
        return result
    }

    public mutating func move(_ field: Field, by offset: Int) {
        var order = orderedFields
        guard let index = order.firstIndex(of: field),
              order.indices.contains(index + offset) else { return }
        order.swapAt(index, index + offset)
        fieldOrder = order
    }

    /// Prefix fields are single-line labels; blank removes the label entirely.
    public static func prefixText(_ value: String) -> String {
        let label = value.components(separatedBy: .newlines)
            .joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return label.isEmpty ? "" : label + " "
    }

    static let defaultsKey = "clipboardLayout"

    static func load(from defaults: UserDefaults) -> ClipboardLayout {
        if let data = defaults.data(forKey: defaultsKey),
           let layout = try? JSONDecoder().decode(ClipboardLayout.self, from: data) {
            return layout
        }
        var layout = ClipboardLayout()
        // Preserve an explicitly chosen legacy comment label, including None.
        switch defaults.string(forKey: "commentPrefixStyle") {
        case "note": layout.commentPrefix = "Note:"
        case "dash": layout.commentPrefix = "—"
        case "arrow": layout.commentPrefix = "→"
        case "none": layout.commentPrefix = ""
        default: break
        }
        return layout
    }

    func save(to defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}
