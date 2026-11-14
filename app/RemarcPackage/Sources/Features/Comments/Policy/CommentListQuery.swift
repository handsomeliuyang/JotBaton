import CoreLocalization
import Foundation

/// Status buckets offered by the comment list filter bar. The chips toggle
/// independently; with none selected every retained status is shown, including
/// completions awaiting their configured move to History. Handed-off work is
/// separate from in-progress work because it cannot be started or batch completed.
public enum CommentStatusFilter: String, CaseIterable, Sendable {
    case open
    case handedOff
    case inProgress
    case deferred

    public var title: String {
        switch self {
        case .open: return L10n.tr("Open")
        case .handedOff: return L10n.tr("Handed Off")
        case .inProgress: return L10n.tr("In Progress")
        case .deferred: return L10n.tr("On Hold")
        }
    }

    public var help: String {
        switch self {
        case .open: return L10n.tr("Comments nobody has started on")
        case .handedOff: return L10n.tr("Comments already handed off and skipped when starting")
        case .inProgress: return L10n.tr("Comments currently in development")
        case .deferred: return L10n.tr("Comments set aside and skipped when starting")
        }
    }

    /// Phrase for empty states, e.g. "No in-progress comments".
    public var emptyStateTitle: String {
        switch self {
        case .open: return L10n.tr("No open comments")
        case .handedOff: return L10n.tr("No handed-off comments")
        case .inProgress: return L10n.tr("No in-progress comments")
        case .deferred: return L10n.tr("No comments on hold")
        }
    }

    public func includes(_ status: CommentStatus) -> Bool {
        switch self {
        case .open: return status == .open
        case .handedOff: return status == .handedOff
        case .inProgress: return status == .inProgress
        case .deferred: return status == .deferred
        }
    }

    /// Reads a selection persisted by `storageValue(of:)`, ignoring unknown entries.
    public static func selection(from storageValue: String) -> Set<CommentStatusFilter> {
        Set(storageValue.split(separator: ",").compactMap { CommentStatusFilter(rawValue: String($0)) })
    }

    public static func storageValue(of selection: Set<CommentStatusFilter>) -> String {
        allCases.filter { selection.contains($0) }.map(\.rawValue).joined(separator: ",")
    }
}

/// Pure list logic behind the comment panel: search matching, status counts,
/// ordering and per-session grouping. Kept free of SwiftUI so it is testable.
public enum CommentListQuery {
    package static let searchOptions: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]

    /// Whitespace-separated terms. Every term must match some field.
    public static func searchTerms(from query: String) -> [String] {
        query.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    public static func matches(_ comment: Comment, terms: [String], sessionName: String?) -> Bool {
        guard !terms.isEmpty else { return true }
        let fields = searchableFields(of: comment, sessionName: sessionName)
        return terms.allSatisfy { term in
            fields.contains { $0.range(of: term, options: searchOptions) != nil }
        }
    }

    package static func searchableFields(of comment: Comment, sessionName: String?) -> [String] {
        var fields = [comment.commentText, comment.source, comment.id.uuidString]
        if let reference = comment.type.displayText { fields.append(reference) }
        if let sessionName { fields.append(sessionName) }
        if let summary = comment.resolutionSummary { fields.append(summary) }
        if let web = comment.webContext {
            fields.append(contentsOf: [web.pageUrl, web.elementName, web.componentName, web.filePath].compactMap { $0 })
        }
        return fields
    }

    /// Ranges of `terms` inside `text`, for highlighting search hits.
    public static func matchRanges(of terms: [String], in text: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        for term in terms where !term.isEmpty {
            var searchStart = text.startIndex
            while searchStart < text.endIndex,
                  let found = text.range(of: term, options: searchOptions, range: searchStart..<text.endIndex) {
                ranges.append(found)
                searchStart = found.upperBound
            }
        }
        return ranges
    }

    /// Comments whose status falls in any selected bucket; an empty selection keeps all.
    public static func filtered(_ comments: [Comment], statuses: Set<CommentStatusFilter>) -> [Comment] {
        guard !statuses.isEmpty else { return comments }
        return comments.filter { comment in statuses.contains { $0.includes(comment.status) } }
    }

    /// Active work, then comments on hold, then resolved work; keep each part's order.
    public static func unresolvedFirst(_ comments: [Comment]) -> [Comment] {
        comments.filter { $0.status != .resolved && $0.status != .deferred }
            + comments.filter { $0.status == .deferred }
            + comments.filter { $0.status == .resolved }
    }

    public static func sorted(_ comments: [Comment], newestFirst: Bool) -> [Comment] {
        comments.sorted { newestFirst ? $0.createdAt > $1.createdAt : $0.createdAt < $1.createdAt }
    }

    public static func counts(of comments: [Comment]) -> [CommentStatusFilter: Int] {
        var counts: [CommentStatusFilter: Int] = [:]
        for comment in comments {
            for filter in CommentStatusFilter.allCases where filter.includes(comment.status) {
                counts[filter, default: 0] += 1
            }
        }
        return counts
    }

    /// Sidebar counts use the same status selection as the cards, across all sessions.
    /// An empty selection counts every retained status, including resolved comments.
    public static func countsBySession(of comments: [Comment], statuses: Set<CommentStatusFilter>) -> [UUID: Int] {
        let retained = comments.filter { !$0.isDeleted }
        return filtered(retained, statuses: statuses).reduce(into: [:]) { counts, comment in
            counts[comment.sessionID, default: 0] += 1
        }
    }

    /// Groups comments by session in the given session order, dropping empty groups.
    public static func grouped(_ comments: [Comment], sessions: [Session]) -> [CommentGroup] {
        let bySession = Dictionary(grouping: comments, by: \.sessionID)
        return sessions.compactMap { session in
            guard let members = bySession[session.id], !members.isEmpty else { return nil }
            return CommentGroup(session: session, comments: members)
        }
    }
}

public struct CommentGroup: Identifiable {
    public let session: Session
    public let comments: [Comment]
    public var id: UUID { session.id }
}
