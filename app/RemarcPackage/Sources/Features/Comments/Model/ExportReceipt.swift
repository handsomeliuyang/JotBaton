import Foundation

public enum ExportHighlight: Hashable, Sendable {
    case reference, screenshotPrefix, attachmentPrefix, layout, numbering, commentPrefix, divider, dateFormat, metadataDivider
    case source, date, status, remarkID, type
}

public struct PreviewSegment: Sendable {
    package init(text: String, highlights: Set<ExportHighlight>) {
        self.text = text
        self.highlights = highlights
    }
    public let text: String
    public let highlights: Set<ExportHighlight>
}

public struct PreviewLine: Identifiable, Sendable {
    package init(id: Int, segments: [PreviewSegment]) {
        self.id = id
        self.segments = segments
    }
    public let id: Int
    public let segments: [PreviewSegment]
}

/// The exact versions of the comments successfully written by an export.
///
/// Clearing against this receipt prevents a later session switch, new comment,
/// edit, move, or status change from deleting state that was not actually part
/// of the exported snapshot.
public struct ExportReceipt: Equatable, Sendable {
    public struct Entry: Equatable, Sendable {
        public let id: UUID
        public let updatedAt: Date
    }

    public let sessionID: UUID
    public let entries: [Entry]

    public init(sessionID: UUID, comments: [Comment]) {
        self.sessionID = sessionID
        self.entries = comments.map { Entry(id: $0.id, updatedAt: $0.updatedAt) }
    }

    public var commentIDs: [UUID] {
        entries.map(\.id)
    }

    public var count: Int {
        entries.count
    }

    /// IDs that still represent the exact exported versions in the same
    /// session. This pure helper is shared by persistence and contract tests.
    public func clearableCommentIDs(in comments: [Comment]) -> [UUID] {
        var versions: [UUID: Date] = [:]
        for entry in entries {
            versions[entry.id] = entry.updatedAt
        }

        return comments.compactMap { comment in
            guard !comment.isDeleted,
                  comment.sessionID == sessionID,
                  versions[comment.id] == comment.updatedAt else {
                return nil
            }
            return comment.id
        }
    }
}
