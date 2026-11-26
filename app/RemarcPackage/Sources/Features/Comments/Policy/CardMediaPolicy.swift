import Foundation

/// Selects the lead thumbnail and remaining image count for a main-list comment card.
public enum CardMediaPolicy {
    public struct LeadMedia: Equatable, Sendable {
        public let imagePath: String
        public let extraImageCount: Int

        public init(imagePath: String, extraImageCount: Int) {
            self.imagePath = imagePath
            self.extraImageCount = extraImageCount
        }
    }

    /// Returns the lead preview image path and the number of additional images
    /// behind it, or `nil` when the comment has neither a screenshot nor attachments.
    ///
    /// - Screenshot comments lead with the screenshot; every attachment counts as extra.
    /// - Other comments lead with `attachments.first`; remaining attachments count as extra.
    public static func leadImage(for comment: Comment) -> LeadMedia? {
        if case .screenshot(let imagePath) = comment.type {
            return LeadMedia(imagePath: imagePath, extraImageCount: comment.attachments.count)
        }
        guard let firstAttachment = comment.attachments.first else { return nil }
        return LeadMedia(imagePath: firstAttachment, extraImageCount: comment.attachments.count - 1)
    }
}
