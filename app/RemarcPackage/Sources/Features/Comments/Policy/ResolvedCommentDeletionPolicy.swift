import Foundation

package enum ResolvedCommentDeletionPolicy {
    package static func expiredIDs(in comments: [Comment], interval: TimeInterval,
                           protectedUntil: [UUID: Date] = [:], now: Date) -> Set<UUID> {
        Set(comments.compactMap { comment in
            guard !comment.isDeleted, comment.status == .resolved,
                  !(protectedUntil[comment.id].map { $0 > now } ?? false),
                  now.timeIntervalSince(comment.resolvedAt ?? comment.updatedAt) >= interval else { return nil }
            return comment.id
        })
    }
}
