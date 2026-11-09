import Foundation

/// Status buckets offered by the comment list filter bar.
///
/// `handedOff` sits under "in progress": the comment has been delivered to an
/// agent session, so somebody is already working on it.
public enum CommentStatusFilter: String, CaseIterable, Sendable {
    case outstanding
    case open
    case inProgress
    case resolved

    public var title: String {
        switch self {
        case .outstanding: return "未完成"
        case .open: return "待处理"
        case .inProgress: return "进行中"
        case .resolved: return "已解决"
        }
    }

    public var help: String {
        switch self {
        case .outstanding: return "待处理、已转交和进行中的评论"
        case .open: return "还没有开始处理的评论"
        case .inProgress: return "已转交或正在开发中的评论"
        case .resolved: return "已解决的评论"
        }
    }

    public func includes(_ status: CommentStatus) -> Bool {
        switch self {
        case .outstanding: return status != .resolved
        case .open: return status == .open
        case .inProgress: return status == .inProgress || status == .handedOff
        case .resolved: return status == .resolved
        }
    }
}

/// Pure list logic behind the comment panel: search matching, status counts,
/// ordering and per-session grouping. Kept free of SwiftUI so it is testable.
public enum CommentListQuery {
    static let searchOptions: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]

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

    static func searchableFields(of comment: Comment, sessionName: String?) -> [String] {
        var fields = [comment.taskTitle, comment.commentText, comment.source, comment.id.uuidString]
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
