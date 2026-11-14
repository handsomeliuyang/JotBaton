import Foundation

public struct AppState: Codable, Sendable, Equatable {
    public var sessions: [Session]
    public var comments: [Comment]
    public var activeSessionID: UUID?
    public var totalCommentsCreated: Int
    public var orphanedImages: [OrphanedImage]
    /// Document-level keys written by a newer app version.
    /// Carried through untouched so this build cannot delete them.
    public var unknownFields: [String: JSONValue]

    public init(
        sessions: [Session] = [],
        comments: [Comment] = [],
        activeSessionID: UUID? = nil,
        totalCommentsCreated: Int = 0,
        orphanedImages: [OrphanedImage] = [],
        unknownFields: [String: JSONValue] = [:]
    ) {
        self.sessions = sessions
        self.comments = comments
        self.activeSessionID = activeSessionID
        self.totalCommentsCreated = totalCommentsCreated
        self.orphanedImages = orphanedImages
        self.unknownFields = unknownFields
    }

    /// Creates an empty default state — no sessions until first comment
    public static func defaultState() -> AppState {
        return AppState(
            sessions: [],
            comments: [],
            activeSessionID: nil,
            totalCommentsCreated: 0,
            orphanedImages: []
        )
    }

    // MARK: - Backward-Compatible Codable

    private enum CodingKeys: String, CodingKey {
        case sessions, comments, activeSessionID, totalCommentsCreated, orphanedImages
        // Legacy keys for reading old data
        case stacks, activeStackID
    }

    /// Every key this build claims. Anything else, including the retired
    /// `transcriptions` archive, is preserved verbatim.
    private static let modelledKeys: Set<String> = [
        "sessions", "comments", "activeSessionID", "totalCommentsCreated", "orphanedImages",
        // Legacy names are modelled too: they are read, and deliberately not
        // written back, so they must not be resurrected as "unknown".
        "stacks", "activeStackID",
        // Bookkeeping of the retired manual iCloud snapshots: dropped on the next save.
        "_snapshotReceipt", "_snapshotContentStamp", "_snapshotUndo", "_snapshotDataUpdatedAt",
    ]

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        comments = try container.decode([Comment].self, forKey: .comments)
        totalCommentsCreated = try container.decodeIfPresent(Int.self, forKey: .totalCommentsCreated) ?? 0

        // Try new key first, fall back to legacy
        if let s = try container.decodeIfPresent([Session].self, forKey: .sessions) {
            sessions = s
        } else {
            sessions = try container.decodeIfPresent([Session].self, forKey: .stacks) ?? []
        }

        if let id = try container.decodeIfPresent(UUID.self, forKey: .activeSessionID) {
            activeSessionID = id
        } else {
            activeSessionID = try container.decodeIfPresent(UUID.self, forKey: .activeStackID)
        }

        orphanedImages = try container.decodeIfPresent([OrphanedImage].self, forKey: .orphanedImages) ?? []

        let dynamic = try decoder.container(keyedBy: DynamicCodingKey.self)
        unknownFields = dynamic.unknownFields(besides: Self.modelledKeys)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sessions, forKey: .sessions)
        try container.encode(comments, forKey: .comments)
        try container.encodeIfPresent(activeSessionID, forKey: .activeSessionID)
        try container.encode(totalCommentsCreated, forKey: .totalCommentsCreated)
        if !orphanedImages.isEmpty {
            try container.encode(orphanedImages, forKey: .orphanedImages)
        }

        var dynamic = encoder.container(keyedBy: DynamicCodingKey.self)
        try dynamic.encodeUnknownFields(unknownFields, skipping: Self.modelledKeys)
    }
}
