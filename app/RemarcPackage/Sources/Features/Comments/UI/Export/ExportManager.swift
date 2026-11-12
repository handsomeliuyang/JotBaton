import CorePlatform
import FeatureCapture
import FeatureComments
import FeatureSettings
import AppKit
import UniformTypeIdentifiers

@MainActor
protocol TextClipboardDestination {
    @discardableResult func clearContents() -> Int
    func setString(_ string: String, forType: NSPasteboard.PasteboardType) -> Bool
}

extension NSPasteboard: TextClipboardDestination {}

@MainActor
public final class ExportManager {
    public static let shared = ExportManager()
    private init() {}

    // MARK: - Formatting Helpers

    /// Keep each filesystem path a single Markdown destination. URL encoding
    /// preserves literal percent signs, delimiters, and newlines in folder
    /// names; angle brackets also protect parentheses from Markdown parsing.
    private func markdownImage(_ storedPath: String, label: String) -> String {
        let destination = resolveImagePath(storedPath).path(percentEncoded: true)
        return "![\(label)](<\(destination)>)"
    }

    /// Format a comment's reference text according to the chosen style.
    /// Returns nil for quick notes (no reference to show).
    public func formatReference(_ comment: Comment, style: ReferenceStyle) -> String? {
        switch comment.type {
        case .comment(let text):
            let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { return nil }
            switch style {
            case .plain: return cleaned
            case .blockquote:
                return cleaned.components(separatedBy: "\n").map { "> \($0)" }.joined(separator: "\n")
            case .rePrefix:
                let oneLine = cleaned.replacingOccurrences(of: "\n", with: " ")
                return "Re: \(oneLine)"
            case .quoted:
                let oneLine = cleaned.replacingOccurrences(of: "\n", with: " ")
                return "\"\(oneLine)\""
            }
        case .screenshot(let imagePath):
            return markdownImage(imagePath, label: "screenshot")
        case .quickNote:
            return nil
        case .critMode:
            return nil
        case .webElement(let name, let path):
            let parts = [name, path].compactMap { $0 }
            let label = parts.isEmpty ? "Web Element" : parts.joined(separator: " \u{00B7} ")
            switch style {
            case .plain: return label
            case .blockquote: return "> [\(label)]"
            case .rePrefix: return "Re: \(label)"
            case .quoted: return "\"\(label)\""
            }
        }
    }

    /// Format the comment prefix (e.g. "Comment: ", "Note: ", "— ").
    public func formatCommentPrefix(style: CommentPrefixStyle) -> String {
        switch style {
        case .comment: return "Comment: "
        case .note: return "Note: "
        case .dash: return "\u{2014} "
        case .arrow: return "\u{2192} "
        case .none: return ""
        }
    }

    /// Format the prefix for a comment at the given index.
    public func formatPrefix(index: Int, style: NumberingStyle) -> String {
        switch style {
        case .numbered: return "\(index + 1). "
        case .bulleted: return "- "
        case .none: return ""
        }
    }

    /// Format a date according to the chosen format.
    public func formatDate(_ date: Date, format: ExportDateFormat, includeTime: Bool = false, use24Hour: Bool = false, locale: Locale? = nil) -> String {
        let formatter = DateFormatter()
        if let locale { formatter.locale = locale }
        switch format {
        case .short:
            if includeTime {
                formatter.dateFormat = use24Hour ? "MMM d, HH:mm" : "MMM d, h:mm a"
            } else {
                formatter.dateFormat = "MMM d"
            }
        case .medium:
            if includeTime {
                formatter.dateFormat = use24Hour ? "MMM d, yyyy, HH:mm" : "MMM d, yyyy, h:mm a"
            } else {
                formatter.dateFormat = "MMM d, yyyy"
            }
        case .long:
            if includeTime {
                formatter.dateFormat = use24Hour ? "MMMM d, yyyy, HH:mm" : "MMMM d, yyyy, h:mm a"
            } else {
                formatter.dateFormat = "MMMM d, yyyy"
            }
        case .iso:
            // ISO always uses 24h regardless of time format setting
            formatter.dateFormat = includeTime ? "yyyy-MM-dd HH:mm" : "yyyy-MM-dd"
        case .european:
            if includeTime {
                formatter.dateFormat = use24Hour ? "dd/MM/yyyy, HH:mm" : "dd/MM/yyyy, h:mm a"
            } else {
                formatter.dateFormat = "dd/MM/yyyy"
            }
        }
        return formatter.string(from: date)
    }

    /// Build the metadata line (e.g. "a3f2b | VS Code | Feb 28 | Open").
    /// Returns nil if no metadata fields are enabled.
    public func formatMetadataLine(
        _ comment: Comment,
        includeRemarkID: Bool,
        includeSource: Bool,
        includeDate: Bool,
        includeStatus: Bool,
        includeType: Bool,
        dateFormat: ExportDateFormat,
        includeTime: Bool = false,
        use24Hour: Bool = false,
        metadataDivider: MetadataDividerStyle = .pipe
    ) -> String? {
        var parts: [String] = []
        if includeRemarkID {
            parts.append(comment.shortID)
        }
        if includeSource {
            parts.append(comment.source)
        }
        if includeDate {
            parts.append(formatDate(comment.createdAt, format: dateFormat, includeTime: includeTime, use24Hour: use24Hour))
        }
        if includeStatus {
            parts.append(comment.status.exportLabel)
        }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: metadataDivider.separator)
    }

    // MARK: - Markdown Export

    public func markdownForSession(_ session: Session, comments: [Comment], includeMetadata: Bool) -> String {
        let settings = SettingsManager.shared
        var result = markdownForComments(
            comments,
            referenceStyle: settings.referenceStyle,
            numberingStyle: settings.numberingStyle,
            commentPrefixStyle: settings.commentPrefixStyle,
            dividerStyle: settings.dividerStyle,
            dateFormat: settings.exportDateFormat,
            includeRemarkID: settings.includeRemarkID,
            includeSource: settings.includeSource,
            includeDate: settings.includeDate,
            includeStatus: settings.includeStatus,
            includeType: settings.includeType,
            includeTime: settings.includeTime,
            use24Hour: settings.timeFormat.use24Hour,
            metadataDivider: settings.metadataDividerStyle,
            layout: settings.clipboardLayout
        )
        if settings.includeAIHint && MCPManager.shared.isEnabled {
            result += "\n\n<!-- These remarks are from the '\(session.name)' session in Remarc. Use MCP tool remarc_list_comments with session_id to read and resolve them. -->"
        }
        return result
    }

    /// The preview and all Markdown exports share this renderer.
    public func markdownForComments(
        _ comments: [Comment],
        referenceStyle: ReferenceStyle,
        numberingStyle: NumberingStyle,
        commentPrefixStyle: CommentPrefixStyle = .none,
        dividerStyle: DividerStyle,
        dateFormat: ExportDateFormat,
        includeRemarkID: Bool,
        includeSource: Bool,
        includeDate: Bool,
        includeStatus: Bool,
        includeType: Bool,
        includeTime: Bool = false,
        use24Hour: Bool = false,
        metadataDivider: MetadataDividerStyle = .pipe,
        layout: ClipboardLayout? = nil
    ) -> String {
        formattedLines(
            comments,
            referenceStyle: referenceStyle,
            numberingStyle: numberingStyle,
            commentPrefixStyle: commentPrefixStyle,
            dividerStyle: dividerStyle,
            dateFormat: dateFormat,
            includeRemarkID: includeRemarkID,
            includeSource: includeSource,
            includeDate: includeDate,
            includeStatus: includeStatus,
            includeType: includeType,
            includeTime: includeTime,
            use24Hour: use24Hour,
            metadataDivider: metadataDivider,
            layout: layout
        ).map { $0.segments.map(\.text).joined() }.joined(separator: "\n")
    }

    func formattedLines(
        _ comments: [Comment],
        referenceStyle: ReferenceStyle,
        numberingStyle: NumberingStyle,
        commentPrefixStyle: CommentPrefixStyle = .none,
        dividerStyle: DividerStyle,
        dateFormat: ExportDateFormat,
        includeRemarkID: Bool,
        includeSource: Bool,
        includeDate: Bool,
        includeStatus: Bool,
        includeType: Bool,
        includeTime: Bool = false,
        use24Hour: Bool = false,
        metadataDivider: MetadataDividerStyle = .pipe,
        layout: ClipboardLayout? = nil
    ) -> [PreviewLine] {
        var output: [[PreviewSegment]] = []
        let commentPrefix = layout.map { ClipboardLayout.prefixText($0.commentPrefix) }
            ?? formatCommentPrefix(style: commentPrefixStyle)

        func textLines(_ text: String, highlights: Set<ExportHighlight> = []) -> [[PreviewSegment]] {
            text.components(separatedBy: "\n").map { [PreviewSegment(text: $0, highlights: highlights)] }
        }

        func labeledLines(_ text: String, prefix: String, highlight: ExportHighlight) -> [[PreviewSegment]] {
            var result = textLines(text)
            if !prefix.isEmpty {
                result[0].insert(PreviewSegment(text: prefix, highlights: [highlight, .layout]), at: 0)
            }
            return result
        }

        for (index, comment) in comments.enumerated() {
            var fields: [ClipboardLayout.Field: [[PreviewSegment]]] = [:]
            if let reference = formatReference(comment, style: referenceStyle) {
                let label: String
                let highlight: ExportHighlight
                if case .screenshot = comment.type {
                    label = layout.map { ClipboardLayout.prefixText($0.screenshotPrefix) } ?? ""
                    highlight = .screenshotPrefix
                } else {
                    label = layout.map { ClipboardLayout.prefixText($0.referencePrefix) } ?? ""
                    highlight = .reference
                }
                if referenceStyle == .blockquote, highlight == .reference {
                    // Keep Markdown quote markers at the start of each line.
                    var referenceLines = textLines(reference)
                    if !label.isEmpty, let first = referenceLines.first?.first?.text, first.hasPrefix("> ") {
                        referenceLines[0] = [
                            PreviewSegment(text: "> ", highlights: [.reference]),
                            PreviewSegment(text: label, highlights: [.reference, .layout]),
                            PreviewSegment(text: String(first.dropFirst(2)), highlights: [])
                        ]
                    }
                    fields[.reference] = referenceLines
                } else {
                    fields[.reference] = labeledLines(reference, prefix: label, highlight: highlight)
                }
            }
            if let commentText = comment.meaningfulCommentText {
                fields[.comment] = labeledLines(commentText, prefix: commentPrefix, highlight: .commentPrefix)
            }
            fields[.attachments] = comment.attachments.flatMap { attachment in
                labeledLines(markdownImage(attachment, label: "attachment"),
                             prefix: layout.map { ClipboardLayout.prefixText($0.attachmentPrefix) } ?? "",
                             highlight: .attachmentPrefix)
            }

            var metadataLines: [[PreviewSegment]] = []
            func appendContext(_ text: String) {
                metadataLines += textLines(text)
            }
            if includeType {
                metadataLines += textLines("Type: \(comment.type.exportDisplayName)", highlights: [.type])
            }
            // Web context
            if let wc = comment.webContext, let summary = wc.displaySummary {
                appendContext("`\(summary)`")
                if let url = wc.pageUrl {
                    appendContext("`URL: \(url)`")
                }
                if let chain = wc.reactComponents, !chain.isEmpty {
                    appendContext("`Via: \(chain)`")
                }
                if let elementPath = wc.elementPath {
                    appendContext("`Element: \(wc.elementName ?? "unknown") @ \(elementPath)`")
                } else if let elementName = wc.elementName {
                    appendContext("`Element: \(elementName)`")
                }
                if let selectedText = wc.selectedText {
                    appendContext("`Selected text: \(selectedText)`")
                }
                if let selector = wc.selector {
                    appendContext("`\(selector)`")
                }
                if let cssClasses = wc.cssClasses, !cssClasses.isEmpty {
                    appendContext("`Classes: \(cssClasses)`")
                }
                if let styles = wc.computedStyles, !styles.isEmpty {
                    appendContext("`Styles: \(styles)`")
                }
                if let a11y = wc.accessibility, !a11y.isEmpty {
                    appendContext("`A11y: \(a11y)`")
                }
                if let nearby = wc.nearbyText, !nearby.isEmpty {
                    appendContext("`Nearby: \(nearby)`")
                }
            }

            // Region elements
            if let elements = comment.regionElements, elements.count > 1 {
                appendContext("Region elements (\(elements.count)):")
                for el in elements.prefix(5) {
                    let label = el.displaySummary ?? el.elementName ?? el.selector ?? "unknown"
                    appendContext("  - `\(label)`")
                }
                if elements.count > 5 {
                    appendContext("  - ... and \(elements.count - 5) more")
                }
            }
            var metadataSegments: [PreviewSegment] = []
            func metadata(_ text: String, highlights: Set<ExportHighlight>) {
                if !metadataSegments.isEmpty {
                    metadataSegments.append(PreviewSegment(text: metadataDivider.separator, highlights: [.metadataDivider]))
                }
                metadataSegments.append(PreviewSegment(text: text, highlights: highlights))
            }
            if includeRemarkID { metadata(comment.shortID, highlights: [.remarkID]) }
            if includeSource { metadata(comment.source, highlights: [.source]) }
            if includeDate {
                metadata(formatDate(comment.createdAt, format: dateFormat, includeTime: includeTime, use24Hour: use24Hour),
                         highlights: [.date, .dateFormat])
            }
            if includeStatus { metadata(comment.status.exportLabel, highlights: [.status]) }
            if !metadataSegments.isEmpty { metadataLines.append(metadataSegments) }
            fields[.metadata] = metadataLines

            var record: [[PreviewSegment]] = []
            for field in layout?.orderedFields ?? ClipboardLayout.Field.allCases {
                guard let block = fields[field], !block.isEmpty else { continue }
                if !record.isEmpty && layout?.fieldSpacing == .blankLine {
                    record.append([PreviewSegment(text: "", highlights: [.layout])])
                }
                record += block
            }
            // Keep legacy payloadless records visible even with all metadata disabled.
            if record.isEmpty { record = textLines("[\(comment.type.exportDisplayName)]") }
            let number = formatPrefix(index: index, style: numberingStyle)
            if !number.isEmpty {
                record[0].insert(PreviewSegment(text: number, highlights: [.numbering]), at: 0)
            }
            output += record
            if index < comments.count - 1 {
                let divider: String
                switch dividerStyle {
                case .horizontalRule: divider = "---"
                case .doubleLine: divider = "==="
                case .dotted: divider = "···"
                case .blankLine: divider = ""
                }
                output += textLines(divider, highlights: [.divider])
            }
        }
        return output.enumerated().map { PreviewLine(id: $0.offset, segments: $0.element) }
    }

    // MARK: - JSON Export

    public func jsonForSession(_ session: Session, comments: [Comment], includeMetadata: Bool) -> String {
        struct ExportComment: Encodable {
            let number: Int
            let selectedText: String?
            let imagePath: String?
            let componentName: String?
            let filePath: String?
            let comment: String
            let type: String
            let source: String
            let timestamp: String
            let attachments: [String]?
            let webContext: WebContext?
            let regionElements: [WebContext]?
        }

        struct ExportWrapper: Encodable {
            let session: String?
            let exported: String?
            let comments: [ExportComment]
        }

        let formatter = ISO8601DateFormatter()
        let exportComments = comments.enumerated().map { index, comment in
            let webElementReference: (componentName: String?, filePath: String?) = switch comment.type {
            case .webElement(let componentName, let filePath):
                (componentName, filePath)
            default:
                (nil, nil)
            }
            return ExportComment(
                number: index + 1,
                selectedText: comment.selectedText,
                imagePath: comment.type.imagePath.map { resolveImagePath($0).path },
                componentName: webElementReference.componentName,
                filePath: webElementReference.filePath,
                comment: Comment.normalizedCommentText(comment.commentText),
                type: comment.type.identifier,
                source: comment.source,
                timestamp: formatter.string(from: comment.createdAt),
                attachments: comment.attachments.isEmpty ? nil : comment.attachments.map { resolveImagePath($0).path },
                webContext: comment.webContext,
                regionElements: comment.regionElements
            )
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        if includeMetadata {
            let wrapper = ExportWrapper(
                session: session.name,
                exported: formatter.string(from: Date()),
                comments: exportComments
            )
            if let data = try? encoder.encode(wrapper) {
                return String(data: data, encoding: .utf8) ?? "[]"
            }
        } else {
            if let data = try? encoder.encode(exportComments) {
                return String(data: data, encoding: .utf8) ?? "[]"
            }
        }

        return "[]"
    }

    // MARK: - Single Comment Export

    public func markdownForComment(_ comment: Comment) -> String {
        let settings = SettingsManager.shared
        return markdownForComments(
            [comment],
            referenceStyle: settings.referenceStyle,
            numberingStyle: .none,  // Single comment: no numbering
            commentPrefixStyle: settings.commentPrefixStyle,
            dividerStyle: .blankLine,
            dateFormat: settings.exportDateFormat,
            includeRemarkID: settings.includeRemarkID,
            includeSource: settings.includeSource,
            includeDate: settings.includeDate,
            includeStatus: settings.includeStatus,
            includeType: settings.includeType,
            includeTime: settings.includeTime,
            use24Hour: settings.timeFormat.use24Hour,
            metadataDivider: settings.metadataDividerStyle,
            layout: settings.clipboardLayout
        )
    }

    // MARK: - Preview

    private(set) lazy var sampleComments: [Comment] = [
            Comment(
                type: .comment(text: "let maxRetries = 42 // default"),
                commentText: "Seems arbitrary — where does this come from?",
                source: "Xcode",
                appBundleID: nil,
                createdAt: Date(),
                sessionID: UUID(),
                status: .open
            ),
            Comment(
                type: .screenshot(imagePath: "images/screenshot.png"),
                commentText: "So it goes. Clean up observers before exit.",
                source: "Xcode",
                appBundleID: nil,
                createdAt: Date().addingTimeInterval(-3600),
                sessionID: UUID(),
                status: .open
            ),
            Comment(
                type: .comment(text: "--color-ice-nine: rgba(0, 255, 206, 1)"),
                commentText: "This token cascades and freezes everything.",
                source: "Pages",
                appBundleID: nil,
                createdAt: Date().addingTimeInterval(-86400),
                sessionID: UUID(),
                status: .resolved
            ),
            Comment(
                type: .quickNote,
                commentText: "Most useful advice in the whole guide.",
                source: "Slack",
                appBundleID: nil,
                createdAt: Date().addingTimeInterval(-172800),
                sessionID: UUID(),
                status: .open,
                attachments: ["images/attachment.png"]
            ),
            Comment(
                type: .critMode,
                commentText: "Don't panic. Rollback script is in the wiki.",
                source: "Figma",
                appBundleID: nil,
                createdAt: Date().addingTimeInterval(-259200),
                sessionID: UUID(),
                status: .open
            ),
            Comment(
                type: .comment(text: "All tests were green as of last Tuesday"),
                commentText: "Everything was beautiful until the merge.",
                source: "Slack",
                appBundleID: nil,
                createdAt: Date().addingTimeInterval(-345600),
                sessionID: UUID(),
                status: .resolved
            ),
    ]

    /// Uses the same segments as copying, including field order and multiline content.
    public func previewLines(
        referenceStyle: ReferenceStyle,
        numberingStyle: NumberingStyle,
        commentPrefixStyle: CommentPrefixStyle = .none,
        dividerStyle: DividerStyle,
        dateFormat: ExportDateFormat,
        includeRemarkID: Bool,
        includeSource: Bool,
        includeDate: Bool,
        includeStatus: Bool,
        includeType: Bool,
        includeTime: Bool = false,
        use24Hour: Bool = false,
        metadataDivider: MetadataDividerStyle = .pipe,
        includeAIHint: Bool = false,
        layout: ClipboardLayout? = nil
    ) -> [PreviewLine] {
        var lines = formattedLines(
            sampleComments,
            referenceStyle: referenceStyle,
            numberingStyle: numberingStyle,
            commentPrefixStyle: commentPrefixStyle,
            dividerStyle: dividerStyle,
            dateFormat: dateFormat,
            includeRemarkID: includeRemarkID,
            includeSource: includeSource,
            includeDate: includeDate,
            includeStatus: includeStatus,
            includeType: includeType,
            includeTime: includeTime,
            use24Hour: use24Hour,
            metadataDivider: metadataDivider,
            layout: layout
        )
        if includeAIHint && MCPManager.shared.isEnabled {
            lines.append(PreviewLine(id: lines.count, segments: [PreviewSegment(text: "", highlights: [])]))
            lines.append(PreviewLine(id: lines.count, segments: [PreviewSegment(text: "<!-- These remarks are from the 'Session' session in Remarc. Use MCP tool remarc_list_comments with session_id to read and resolve them. -->", highlights: [.aiHint])]))
        }
        return lines
    }

    /// Generate sample markdown for the settings preview panel.
    public func previewMarkdown(
        referenceStyle: ReferenceStyle,
        numberingStyle: NumberingStyle,
        commentPrefixStyle: CommentPrefixStyle = .none,
        dividerStyle: DividerStyle,
        dateFormat: ExportDateFormat,
        includeRemarkID: Bool,
        includeSource: Bool,
        includeDate: Bool,
        includeStatus: Bool,
        includeType: Bool,
        includeTime: Bool = false,
        use24Hour: Bool = false,
        metadataDivider: MetadataDividerStyle = .pipe,
        layout: ClipboardLayout? = nil
    ) -> String {
        previewLines(
            referenceStyle: referenceStyle,
            numberingStyle: numberingStyle,
            commentPrefixStyle: commentPrefixStyle,
            dividerStyle: dividerStyle,
            dateFormat: dateFormat,
            includeRemarkID: includeRemarkID,
            includeSource: includeSource,
            includeDate: includeDate,
            includeStatus: includeStatus,
            includeType: includeType,
            includeTime: includeTime,
            use24Hour: use24Hour,
            metadataDivider: metadataDivider,
            layout: layout
        ).map { $0.segments.map(\.text).joined() }.joined(separator: "\n")
    }

    // MARK: - Clipboard Actions

    private func exportSnapshot(for session: Session, comments: [Comment]) -> [Comment] {
        comments.filter { !$0.isDeleted && $0.sessionID == session.id }
    }

    @discardableResult
    public func copySessionToClipboard(
        _ session: Session,
        comments: [Comment],
        format: OutputFormat
    ) -> ExportReceipt? {
        copySessionToClipboard(session, comments: comments, format: format, to: NSPasteboard.general)
    }

    @discardableResult
    func copySessionToClipboard(
        _ session: Session,
        comments: [Comment],
        format: OutputFormat,
        to pasteboard: any TextClipboardDestination
    ) -> ExportReceipt? {
        let snapshot = exportSnapshot(for: session, comments: comments)
        let content: String
        let includeMetadata = SettingsManager.shared.includeMetadataInExport

        switch format {
        case .markdown:
            content = markdownForSession(session, comments: snapshot, includeMetadata: includeMetadata)
        case .json:
            content = jsonForSession(session, comments: snapshot, includeMetadata: includeMetadata)
        }

        pasteboard.clearContents()
        guard pasteboard.setString(content, forType: .string) else {
            debugLog("ExportManager: Clipboard write failed")
            return nil
        }
        debugLog("ExportManager: Copied \(snapshot.count) comments as \(format.label)")
        return ExportReceipt(sessionID: session.id, comments: snapshot)
    }

    @discardableResult
    public func copyCommentToClipboard(_ comment: Comment) -> ExportReceipt? {
        copyCommentToClipboard(comment, to: NSPasteboard.general)
    }

    @discardableResult
    func copyCommentToClipboard(_ comment: Comment, to pasteboard: any TextClipboardDestination) -> ExportReceipt? {
        let content = markdownForComment(comment)
        pasteboard.clearContents()
        guard pasteboard.setString(content, forType: .string) else {
            debugLog("ExportManager: Clipboard write failed for single comment")
            return nil
        }
        debugLog("ExportManager: Copied single comment")
        return ExportReceipt(sessionID: comment.sessionID, comments: [comment])
    }

    public func copyCommentAndStartDevelopment(_ comment: Comment) -> Bool {
        copyCommentAndStartDevelopment(
            comment,
            copy: { self.copyCommentToClipboard($0) != nil },
            startDevelopment: { AppServices.shared.comments.setCommentStatus($0, to: .inProgress) }
        )
    }

    public func copySessionAndStartDevelopment(_ session: Session, comments: [Comment]) -> ExportReceipt? {
        copySessionAndStartDevelopment(
            session,
            comments: comments,
            copy: { self.copySessionToClipboard(session, comments: $0, format: .markdown) },
            startDevelopment: { ids in
                for id in ids {
                    AppServices.shared.comments.setCommentStatus(id, to: .inProgress)
                }
            }
        )
    }

    /// Copy the same session snapshot as Copy All, with pending comments already
    /// describing their intended status. Completed comments stay completed, and
    /// no persistent status changes happen unless the clipboard write succeeds.
    func copySessionAndStartDevelopment(
        _ session: Session,
        comments: [Comment],
        copy: ([Comment]) -> ExportReceipt?,
        startDevelopment: ([UUID]) -> Void
    ) -> ExportReceipt? {
        let comments = exportSnapshot(for: session, comments: comments)
        guard !comments.isEmpty else { return nil }
        let pendingIDs = comments.filter { $0.status == .open || $0.status == .handedOff }.map(\.id)
        let pending = Set(pendingIDs)
        let snapshot = comments.map { comment in
            var comment = comment
            if pending.contains(comment.id) {
                comment.status = .inProgress
                comment.resolutionSummary = nil
                comment.resolvedBy = nil
                comment.resolvedAt = nil
            }
            return comment
        }
        guard let receipt = copy(snapshot) else { return nil }
        if !pendingIDs.isEmpty { startDevelopment(pendingIDs) }
        return receipt
    }

    /// Keep clipboard failure from changing status, and export the intended status.
    func copyCommentAndStartDevelopment(
        _ comment: Comment,
        copy: (Comment) -> Bool,
        startDevelopment: (UUID) -> Void
    ) -> Bool {
        var snapshot = comment
        snapshot.status = .inProgress
        snapshot.resolutionSummary = nil
        snapshot.resolvedBy = nil
        snapshot.resolvedAt = nil
        guard copy(snapshot) else { return false }
        startDevelopment(comment.id)
        return true
    }

    // MARK: - File Save

    public func saveSessionToFile(
        _ session: Session,
        comments: [Comment],
        format: OutputFormat,
        completion: @escaping @MainActor (ExportReceipt?) -> Void = { _ in }
    ) {
        let snapshot = exportSnapshot(for: session, comments: comments)
        let receipt = ExportReceipt(sessionID: session.id, comments: snapshot)
        let content: String
        let fileExtension: String

        switch format {
        case .markdown:
            content = markdownForSession(session, comments: snapshot, includeMetadata: true)
            fileExtension = "md"
        case .json:
            content = jsonForSession(session, comments: snapshot, includeMetadata: true)
            fileExtension = "json"
        }

        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(session.name).\(fileExtension)"
        panel.allowedContentTypes = fileExtension == "md"
            ? [UTType(filenameExtension: "md") ?? .plainText]
            : [.json]
        panel.canCreateDirectories = true

        panel.begin { response in
            if response == .OK, let url = panel.url {
                do {
                    try content.write(to: url, atomically: true, encoding: .utf8)
                    debugLog("ExportManager: Saved to \(url.path)")
                    completion(receipt)
                } catch {
                    debugLog("ExportManager: Save failed - \(error.localizedDescription)")
                    completion(nil)
                }
            } else {
                completion(nil)
            }
        }
    }
}
